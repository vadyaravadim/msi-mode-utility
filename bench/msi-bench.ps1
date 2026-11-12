<#
.SYNOPSIS
    MSI-mode micro-benchmark: interrupt mode per device, per-driver ISR/DPC times, and how long
    interrupts stall a CPU core. The trace and the probe use built-in Windows tools; -Load also needs PresentMon and the load.

.DESCRIPTION
    Run it once per state you want to compare (stock / after msi-mode-utility / a device forced
    back to line-based) with the same load running each time (a game, a browser scene, audio):

      1. Interrupt mode table. For every present PCI device with an "Interrupt Management" key:
         the MSISupported registry value (on / off / default = value absent, the driver decides)
         and the IRQs Windows actually assigned. A negative IRQ is a message-signaled vector, a
         small positive number is a legacy line, and the table names the devices sharing it.
         Same rule Device Manager and msinfo32 use.

      2. Kernel trace (needs admin, skipped otherwise). The built-in NT Kernel Logger records
         every ISR and DPC for -Seconds seconds on the performance-counter clock; tracerpt decodes
         it and the script attributes each one to its driver. Per driver: ISR count (also per CPU),
         DPC count, max / p99 / mean durations in microseconds and the interrupt vectors seen. ETW logs two ISR event types: "isrMessage"
         is a driver that connected a message-based routine (always MSI), "isrPlain" is everything
         else. KMDF drivers (Wdf01000.sys: USB xHCI, GPIO) log as plain even in MSI mode, so the
         interrupt mode table above is the ground truth of the mode, not this split.

      3. Stall probe. While the trace runs, one time-critical thread per CPU (-Cpu, a list,
         default CPU 0) spins reading the high-resolution clock and records every gap above
         -GapThresholdUs (default 2 us). Every interrupt, DPC or hypervisor intercept that lands on
         that core shows up as a gap. Per CPU: total stalled time (us and % of the window), a
         histogram (gap counts and summed us per bucket), p50 / p99 / p99.9 / max, and a timeline
         of the gaps of 1 ms or more in msi-bench-<phase>-stalls.csv. The probe allocates no memory
         inside the window, and each probe records the .NET garbage collections that ran during it
         (gcCollections): a collection pauses every probe thread, so a -Load run with one is rejected.

      4. -Device <driver.sys>[,...] (needs admin): a 5 s pre-trace finds the CPU that takes most of
         each driver's ISRs, and the probe is pinned there as well. The picks and the CPU the main
         trace shows for the same driver are saved under cpuPick. The GPU's ISRs are logged as
         dxgkrnl.sys, not as the vendor driver.

      5. -Load <name> -PresentMon <path> (needs admin): waits for the load recipe in loads\<name>.json
         (process and start marker), waits its load pause, then captures frame times with PresentMon
         for the recipe's capture time while the kernel trace and the probes run in the same window.
         On a load with a fixed route the -Device pre-trace runs inside the load pause, so the window
         stays on the route. -Seconds is not allowed with -Load: the recipe sets the window. The
         result adds load, loadWindow (seconds from the load start to the start of the window and to
         the end of the captured frames), presentMon, frames and rejected, and the bench throws after
         saving the JSON when the run is rejected (capped frame rate, lost frames, frames that stop
         short of the capture window, a window that ends past a fixed route, a garbage collection
         inside the window, or a video config that differs from the recipe).

      6. -Background tone,usb-read -UsbReadFile <path> (needs admin, with -Load): plays a 440 Hz tone
         at -40 dBFS on the default output and reads <path> in a loop with the file cache bypassed,
         from the load pause until the trace stops. The result adds background with the playback
         device and the read rate; a read error rejects the run.

      7. -ProcessCpu (with -Load): also records the CPU time each process used inside the capture
         window, with its name and PID, so a runner can reject a run on a background burst. Off by
         default, so a result holds no process list.

    Results print to the console and are saved as msi-bench-<phase>.json in -OutDir (default: next
    to this script). These are the tools behind the
    numbers in the RigPolice article: https://rigpolice.com/system/articles/enable-msi-mode/

.EXAMPLE
    .\msi-bench.ps1 -Phase stock -Seconds 30
    # ...enable MSI mode with msi-mode-utility, reboot, start the same load...
    .\msi-bench.ps1 -Phase msi -Seconds 30

.EXAMPLE
    .\msi-bench.ps1 -Phase stock -Seconds 30 -Device dxgkrnl.sys,HDAudBus.sys -Cpu 0

.EXAMPLE
    .\msi-bench.ps1 -Phase stock -Load superposition -PresentMon .\PresentMon-2.6.0-x64.exe -Device dxgkrnl.sys,HDAudBus.sys,Wdf01000.sys
#>
param(
    [Parameter(Mandatory)][string]$Phase,
    [int]$Seconds = 30,
    [string]$OutDir = $PSScriptRoot,
    [string[]]$Cpu,
    [string[]]$Device,
    [double]$GapThresholdUs = 2,
    [string]$Load,
    [string]$PresentMon,
    [ValidateSet('tone', 'usb-read')][string[]]$Background,
    [string]$UsbReadFile,
    [switch]$ProcessCpu,
    [switch]$SkipTrace
)
$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::InvariantCulture
. (Join-Path $PSScriptRoot 'bench-env.ps1')
$traceSession = 'NT Kernel Logger'
$traceClock = 'perf'
$preTraceSeconds = 5
$defaultProbeCpu = 0
$histogramEdgesUs = @(5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100000)
$roundDigits = 1
$gcKeyPrefix = 'gen'
$toneFrequencyHz = 440
$toneDbfs = -40
$toneSampleRate = 48000
$toneSeconds = 1
$usbReadBlockBytes = 64KB
$usbReadStopTimeoutMs = 10000
$usbReadMinBytes = 1GB
$mebibyteBytes = 1MB
$processCpuMinSeconds = 0.05
$fileTimeTicksPerSecond = 10000000
$pnpParentMaxDepth = 8
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$msiBenchSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class StallProbe {
    public const double TimelineMinUs = 1000.0;
    const double MicrosecondsPerSecond = 1e6;
    const double MicrosecondsPerMillisecond = 1000.0;
    const int TimeCriticalPriority = 15;
    const int ShortGapSlack = 2;
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool SetThreadPriority(IntPtr thread, int priority);
    [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr thread, UIntPtr mask);

    readonly int cpu, seconds;
    readonly double thresholdUs, usPerTick;
    readonly int[] shortGapCounts;
    readonly double[] timelineOffsetsMs, timelineGapsUs;
    readonly int[] gcBefore, gcAfter;
    int timelineCount;
    Thread worker;
    long spanTicks;

    public StallProbe(int cpu, int seconds, double thresholdUs) {
        this.cpu = cpu; this.seconds = seconds; this.thresholdUs = thresholdUs;
        usPerTick = MicrosecondsPerSecond / Stopwatch.Frequency;
        shortGapCounts = new int[(int)Math.Ceiling(TimelineMinUs / usPerTick) + ShortGapSlack];
        int capacity = (int)Math.Floor(seconds * MicrosecondsPerSecond / TimelineMinUs) + 1;
        timelineOffsetsMs = new double[capacity];
        timelineGapsUs = new double[capacity];
        for (int i = 0; i < shortGapCounts.Length; i++) shortGapCounts[i] = 0;
        for (int i = 0; i < capacity; i++) { timelineOffsetsMs[i] = 0.0; timelineGapsUs[i] = 0.0; }
        gcBefore = new int[GC.MaxGeneration + 1];
        gcAfter = new int[GC.MaxGeneration + 1];
    }
    public int TimelineCapacity { get { return timelineGapsUs.Length; } }
    public double[] TimelineOffsetsMs { get { return Trim(timelineOffsetsMs); } }
    public double[] TimelineGapsUs { get { return Trim(timelineGapsUs); } }
    public int[] GcCollections {
        get {
            int[] delta = new int[gcAfter.Length];
            for (int g = 0; g < delta.Length; g++) delta[g] = gcAfter[g] - gcBefore[g];
            return delta;
        }
    }

    double[] Trim(double[] source) {
        double[] copy = new double[timelineCount];
        Array.Copy(source, copy, timelineCount);
        return copy;
    }

    public void Record(long ticks, long offsetTicks) {
        double gap = ticks * usPerTick;
        if (gap >= TimelineMinUs) {
            timelineOffsetsMs[timelineCount] = offsetTicks * usPerTick / MicrosecondsPerMillisecond;
            timelineGapsUs[timelineCount] = gap;
            timelineCount++;
        } else {
            shortGapCounts[ticks]++;
        }
    }

    public void Start() {
        worker = new Thread(() => {
            SetThreadAffinityMask(GetCurrentThread(), (UIntPtr)(1UL << cpu));
            SetThreadPriority(GetCurrentThread(), TimeCriticalPriority);
            for (int g = 0; g < gcBefore.Length; g++) gcBefore[g] = GC.CollectionCount(g);
            long start = Stopwatch.GetTimestamp(), end = start + seconds * Stopwatch.Frequency;
            long prev = start;
            while (prev < end) {
                long now = Stopwatch.GetTimestamp();
                long d = now - prev;
                if (d * usPerTick > thresholdUs) Record(d, prev - start);
                prev = now;
            }
            for (int g = 0; g < gcAfter.Length; g++) gcAfter[g] = GC.CollectionCount(g);
            spanTicks = prev - start;
        });
        worker.Start();
    }
    public void Join() {
        worker.Join();
    }
    public double[] Gaps() {
        int total = timelineCount;
        for (int t = 0; t < shortGapCounts.Length; t++) total += shortGapCounts[t];
        double[] result = new double[total];
        int n = 0;
        for (int t = 0; t < shortGapCounts.Length; t++) {
            double gap = t * usPerTick;
            for (int c = 0; c < shortGapCounts[t]; c++) result[n++] = gap;
        }
        Array.Copy(timelineGapsUs, 0, result, n, timelineCount);
        return result;
    }
    public double[] Stop(out double spanSeconds) {
        Join();
        spanSeconds = (double)spanTicks / Stopwatch.Frequency;
        return Gaps();
    }
}

public class DriverStat {
    public string Module; public int IsrLine, IsrMsi, DpcCount;
    public Dictionary<int, int> Vectors = new Dictionary<int, int>();
    public Dictionary<int, int> IsrPerCpu = new Dictionary<int, int>();
    public List<double> IsrUs = new List<double>(), DpcUs = new List<double>();
}

public class KernelTraceData {
    public Dictionary<string, DriverStat> Stats = new Dictionary<string, DriverStat>();
    public long IsrLine, IsrMsi, Dpc, Dropped;
    public Dictionary<int, long> IsrPlainPerCpu = new Dictionary<int, long>();
    public Dictionary<int, long> IsrMessagePerCpu = new Dictionary<int, long>();
    public int ClockType;
}

public static class KernelCsv {
    const int ColType = 1, ColCpu = 11, ColClock = 16, ColInitial = 19, ColRoutine = 20, ColVector = 22;
    const int ColImageBase = 19, ColImageSize = 20, ColImagePid = 21, ColHeaderClock = 37;
    const double MaxRoutineUs = 1e6;
    const byte KindIsr = 0, KindIsrMsi = 1, KindDpc = 2;
    struct Img { public ulong Base, Size; public string Name; }
    struct Evt { public int Cpu, Vector; public byte Kind; public ulong Routine; public long Clock, Initial; }

    static string[] Split(string line) {
        var parts = line.Split(',');
        for (int i = 0; i < parts.Length; i++) parts[i] = parts[i].Trim();
        return parts;
    }
    static ulong Hex(string s) { return ulong.Parse(s.Substring(2), NumberStyles.HexNumber); }

    public static KernelTraceData Parse(string path) {
        var data = new KernelTraceData();
        var images = new List<Img>();
        var events = new List<Evt>();
        foreach (var line in File.ReadLines(path)) {
            var t = line.TrimStart();
            if (t.StartsWith("PerfInfo,")) {
                var p = Split(line);
                string type = p[ColType];
                if (type == "ISR" || type == "ISR-MSI" || type.EndsWith("DPC")) {
                    var e = new Evt();
                    e.Kind = type == "ISR" ? KindIsr : (type == "ISR-MSI" ? KindIsrMsi : KindDpc);
                    e.Cpu = int.Parse(p[ColCpu]);
                    e.Clock = long.Parse(p[ColClock]);
                    e.Initial = long.Parse(p[ColInitial]);
                    e.Routine = Hex(p[ColRoutine]);
                    if (e.Kind != KindDpc) e.Vector = int.Parse(p[ColVector]);
                    events.Add(e);
                }
            } else if (t.StartsWith("Image,")) {
                var p = Split(line);
                if (p.Length <= ColImagePid || p[ColImagePid] != "0") continue;
                string name = p[p.Length - 1].Trim('"');
                int slash = name.LastIndexOf('\\');
                images.Add(new Img { Base = Hex(p[ColImageBase]), Size = Hex(p[ColImageSize]), Name = slash >= 0 ? name.Substring(slash + 1) : name });
            } else if (t.StartsWith("EventTrace,")) {
                var p = Split(line);
                if (p[ColType] == "Header" && p.Length > ColHeaderClock && p[ColHeaderClock].StartsWith("0x")) data.ClockType = (int)Hex(p[ColHeaderClock]);
            }
        }
        images.Sort((a, b) => a.Base.CompareTo(b.Base));
        var bases = new ulong[images.Count];
        for (int i = 0; i < images.Count; i++) bases[i] = images[i].Base;

        foreach (var e in events) {
            int idx = Array.BinarySearch(bases, e.Routine);
            if (idx < 0) idx = ~idx - 1;
            string module = (idx >= 0 && e.Routine < images[idx].Base + images[idx].Size) ? images[idx].Name : "unknown";
            DriverStat s;
            if (!data.Stats.TryGetValue(module, out s)) { s = new DriverStat { Module = module }; data.Stats[module] = s; }
            double us = (e.Clock - e.Initial) / 10.0;
            if (us < 0 || us > MaxRoutineUs) { data.Dropped++; continue; }
            if (e.Kind != KindDpc) {
                var perCpu = e.Kind == KindIsr ? data.IsrPlainPerCpu : data.IsrMessagePerCpu;
                if (e.Kind == KindIsr) { s.IsrLine++; data.IsrLine++; } else { s.IsrMsi++; data.IsrMsi++; }
                long c; perCpu.TryGetValue(e.Cpu, out c); perCpu[e.Cpu] = c + 1;
                int n; s.IsrPerCpu.TryGetValue(e.Cpu, out n); s.IsrPerCpu[e.Cpu] = n + 1;
                int vc; s.Vectors.TryGetValue(e.Vector, out vc); s.Vectors[e.Vector] = vc + 1;
                s.IsrUs.Add(us);
            } else {
                s.DpcCount++; data.Dpc++;
                s.DpcUs.Add(us);
            }
        }
        return data;
    }
}

public static class ToneWave {
    const int HeaderBytes = 44;
    const int FormatChunkBytes = 16;
    const short PcmFormat = 1;
    const short MonoChannels = 1;
    const short BitsPerSample = 16;
    const short BytesPerSample = 2;

    public static byte[] Build(int frequencyHz, double dbfs, int sampleRate, int seconds) {
        int count = sampleRate * seconds;
        int dataBytes = count * BytesPerSample;
        double amplitude = short.MaxValue * Math.Pow(10.0, dbfs / 20.0);
        byte[] wave = new byte[HeaderBytes + dataBytes];
        using (MemoryStream stream = new MemoryStream(wave))
        using (BinaryWriter writer = new BinaryWriter(stream)) {
            writer.Write(Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(wave.Length - 8);
            writer.Write(Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(Encoding.ASCII.GetBytes("fmt "));
            writer.Write(FormatChunkBytes);
            writer.Write(PcmFormat);
            writer.Write(MonoChannels);
            writer.Write(sampleRate);
            writer.Write(sampleRate * BytesPerSample);
            writer.Write(BytesPerSample);
            writer.Write(BitsPerSample);
            writer.Write(Encoding.ASCII.GetBytes("data"));
            writer.Write(dataBytes);
            for (int i = 0; i < count; i++) {
                double phase = 2.0 * Math.PI * frequencyHz * i / sampleRate;
                writer.Write((short)Math.Round(amplitude * Math.Sin(phase)));
            }
        }
        return wave;
    }
}

public sealed class UsbReadStats {
    public long BytesRead;
    public long Wraps;
    public double Seconds;
    public string Error;
}

public sealed class UsbReader {
    const uint GenericRead = 0x80000000;
    const uint ShareReadWrite = 3;
    const uint OpenExisting = 3;
    const uint NoBuffering = 0x20000000;
    const uint MemCommitReserve = 0x3000;
    const uint MemRelease = 0x8000;
    const uint PageReadWrite = 4;
    const uint FileBegin = 0;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ReadFile(IntPtr file, IntPtr buffer, uint toRead, out uint read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SetFilePointerEx(IntPtr file, long distance, IntPtr newPosition, uint method);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAlloc(IntPtr address, UIntPtr size, uint type, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool VirtualFree(IntPtr address, UIntPtr size, uint type);

    readonly string path;
    readonly uint blockBytes;
    readonly Stopwatch watch = new Stopwatch();
    IntPtr handle = IntPtr.Zero;
    IntPtr buffer = IntPtr.Zero;
    Thread thread;
    volatile bool stopRequested;
    volatile string error;
    long bytesRead;
    long wraps;

    public UsbReader(string path, int blockBytes) {
        if (blockBytes <= 0) throw new ArgumentException("blockBytes must be positive");
        this.path = path;
        this.blockBytes = (uint)blockBytes;
    }

    public long BytesRead {
        get { return Interlocked.Read(ref bytesRead); }
    }

    static string Describe(string what, int code) {
        return what + ": " + new Win32Exception(code).Message;
    }

    public void Start() {
        if (thread != null) throw new InvalidOperationException("the reader is already started");
        handle = CreateFileW(path, GenericRead, ShareReadWrite, IntPtr.Zero, OpenExisting, NoBuffering, IntPtr.Zero);
        if (handle == new IntPtr(-1)) {
            int code = Marshal.GetLastWin32Error();
            handle = IntPtr.Zero;
            throw new IOException("cannot open " + path + ": " + new Win32Exception(code).Message);
        }
        buffer = VirtualAlloc(IntPtr.Zero, new UIntPtr(blockBytes), MemCommitReserve, PageReadWrite);
        if (buffer == IntPtr.Zero) {
            int code = Marshal.GetLastWin32Error();
            CloseHandle(handle);
            handle = IntPtr.Zero;
            throw new IOException(Describe("cannot allocate the read buffer", code));
        }
        watch.Start();
        thread = new Thread(Run);
        thread.IsBackground = true;
        thread.Name = "msi-bench-usb-read";
        thread.Start();
    }

    void Run() {
        try {
            bool progressSinceWrap = false;
            while (!stopRequested) {
                uint read;
                if (!ReadFile(handle, buffer, blockBytes, out read, IntPtr.Zero)) {
                    error = Describe("ReadFile failed", Marshal.GetLastWin32Error());
                    break;
                }
                if (read == 0) {
                    if (!progressSinceWrap) {
                        error = "the file is empty";
                        break;
                    }
                    if (!SetFilePointerEx(handle, 0, IntPtr.Zero, FileBegin)) {
                        error = Describe("SetFilePointerEx failed", Marshal.GetLastWin32Error());
                        break;
                    }
                    Interlocked.Increment(ref wraps);
                    progressSinceWrap = false;
                    continue;
                }
                progressSinceWrap = true;
                Interlocked.Add(ref bytesRead, read);
            }
        } catch (Exception ex) {
            error = ex.Message;
        } finally {
            watch.Stop();
            CloseHandle(handle);
            VirtualFree(buffer, UIntPtr.Zero, MemRelease);
        }
    }

    public UsbReadStats Stop(int timeoutMilliseconds) {
        stopRequested = true;
        if (thread != null && !thread.Join(timeoutMilliseconds) && error == null) {
            error = "the reader thread did not stop within " + timeoutMilliseconds + " ms";
        }
        UsbReadStats stats = new UsbReadStats();
        stats.BytesRead = Interlocked.Read(ref bytesRead);
        stats.Wraps = Interlocked.Read(ref wraps);
        stats.Seconds = watch.Elapsed.TotalSeconds;
        stats.Error = error;
        return stats;
    }
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid iid, int context, IntPtr parameters, [MarshalAs(UnmanagedType.IUnknown)] out object result);
    int OpenPropertyStore(int access, out IntPtr store);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
}

public static class SystemTimes {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(out long idle, out long kernel, out long user);

    public static long[] Read() {
        long idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new long[] { idle, kernel, user };
    }
}

public static class PlaybackEndpoint {
    const int Render = 0;
    const int Console = 0;
    const string EnumeratorClsid = "BCDE0395-E52F-467C-8E3D-C4579291692E";

    public static string DefaultId() {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid(EnumeratorClsid)));
        IMMDevice device;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(Render, Console, out device));
        string id;
        Marshal.ThrowExceptionForHR(device.GetId(out id));
        return id;
    }
}
'@

function Get-DeviceIrq {
    $irqs = @{}
    Get-CimInstance Win32_PNPAllocatedResource | ForEach-Object {
        if ($_.Antecedent.CimClass.CimClassName -ne 'Win32_IRQResource') { return }
        $id = $_.Dependent.DeviceID
        $n = [int64]$_.Antecedent.IRQNumber
        if ($n -gt 2147483647) { $n -= 4294967296 }
        if (-not $irqs.ContainsKey($id)) { $irqs[$id] = New-Object System.Collections.Generic.List[int64] }
        $irqs[$id].Add($n)
    }
    $irqs
}

function Get-IrqMode {
    param([int64[]]$Irq)
    $known = @($Irq | Where-Object { $null -ne $_ })
    $neg = @($known | Where-Object { $_ -lt 0 })
    $pos = @($known | Where-Object { $_ -ge 0 })
    if ($neg.Count -gt 0 -and $pos.Count -eq 0) {
        $text = if ($neg.Count -eq 1) { 'message-signaled, 1 vector' } else { "message-signaled, $($neg.Count) vectors" }
        [pscustomobject]@{ kind = 'message'; text = $text }
    } elseif ($pos.Count -gt 0) {
        [pscustomobject]@{ kind = 'line'; text = "line IRQ $($pos -join ',')" }
    } else {
        [pscustomobject]@{ kind = 'none'; text = 'no IRQ assigned' }
    }
}

function Get-InterruptTable {
    $names = @{}
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\*' } | ForEach-Object { $names[$_.InstanceId] = $_ }

    $irqs = Get-DeviceIrq

    $lineOwners = @{}
    foreach ($id in $irqs.Keys) {
        foreach ($n in $irqs[$id]) {
            if ($n -ge 0) {
                if (-not $lineOwners.ContainsKey($n)) { $lineOwners[$n] = New-Object System.Collections.Generic.List[string] }
                $lineOwners[$n].Add($id)
            }
        }
    }

    foreach ($id in ($names.Keys | Sort-Object)) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters\Interrupt Management"
        if (-not (Test-Path $key)) { continue }
        $msi = (Get-ItemProperty "$key\MessageSignaledInterruptProperties" -Name MSISupported -ErrorAction SilentlyContinue).MSISupported
        $setting = if ($null -eq $msi) { 'default' } elseif ($msi -eq 1) { 'on' } else { 'off' }

        $vectors = @(if ($irqs.ContainsKey($id)) { $irqs[$id] })
        $pos = @($vectors | Where-Object { $_ -ge 0 })
        $mode = (Get-IrqMode -Irq $vectors).text

        $shared = @()
        foreach ($n in $pos) {
            foreach ($other in $lineOwners[$n]) {
                if ($other -ne $id -and $names.ContainsKey($other)) { $shared += $names[$other].FriendlyName }
            }
        }

        [pscustomobject]@{
            Device       = $names[$id].FriendlyName
            Class        = $names[$id].Class
            MSISupported = $setting
            Mode         = $mode
            SharedWith   = ($shared -join '; ')
        }
    }
}

function ConvertTo-ListArgument {
    param([string[]]$Value)
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($part in ($item -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
}

function Get-ClockName {
    param([int]$ClockType)
    switch ($ClockType) {
        1 { 'perf' }
        2 { 'system' }
        3 { 'cycle' }
        default { 'unknown' }
    }
}

function Read-KernelCsv {
    param([Parameter(Mandatory)][string]$Path)
    $data = [KernelCsv]::Parse($Path)
    $clock = Get-ClockName $data.ClockType
    if ($clock -ne $traceClock) {
        throw "The kernel trace clock is '$clock' (header code $($data.ClockType)), expected '$traceClock': ISR and DPC start times are 100 ns units only under the '$traceClock' clock."
    }
    $data
}

function Start-KernelTrace {
    param([Parameter(Mandatory)][string]$Etl)
    Remove-Item $Etl -ErrorAction SilentlyContinue
    $started = & { $ErrorActionPreference = 'Continue'; & logman start $traceSession -p 'Windows Kernel Trace' '(img,dpc,isr)' -o $Etl -ct $traceClock -ets 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot start the ETW session '$traceSession': $(($started | ForEach-Object { "$_" }) -join ' '). Another program holds that session. The bench never stops a session it did not start: close that program or reboot, then run the bench again."
    }
}

function Stop-KernelTrace {
    & logman stop $traceSession -ets | Out-Null
}

function Read-KernelTrace {
    param([Parameter(Mandatory)][string]$Etl)
    $csv = [System.IO.Path]::ChangeExtension($Etl, 'csv')
    try {
        & tracerpt $Etl -o $csv -of CSV -y | Out-Null
        Read-KernelCsv -Path $csv
    } finally {
        Remove-Item $Etl, $csv -ErrorAction SilentlyContinue
    }
}

function Get-TopIsrCpu {
    param([Parameter(Mandatory)]$Stat)
    $best = $null
    $bestCount = 0
    foreach ($entry in $Stat.IsrPerCpu.GetEnumerator()) {
        if ($entry.Value -gt $bestCount -or ($entry.Value -eq $bestCount -and $null -ne $best -and $entry.Key -lt $best)) {
            $best = $entry.Key
            $bestCount = $entry.Value
        }
    }
    $best
}

function Find-DriverStat {
    param([Parameter(Mandatory)]$Stats, [Parameter(Mandatory)][string]$Driver)
    foreach ($key in $Stats.Keys) {
        if ($key -ieq $Driver) { return $Stats[$key] }
    }
    $null
}

function Get-DeviceCpuPick {
    param([Parameter(Mandatory)]$Stats, [Parameter(Mandatory)][string[]]$Driver)
    foreach ($name in $Driver) {
        $stat = Find-DriverStat -Stats $Stats -Driver $name
        $cpu = if ($stat) { Get-TopIsrCpu $stat } else { $null }
        if ($null -eq $cpu) {
            $withIsr = @($Stats.Values | Where-Object { $_.IsrPerCpu.Count -gt 0 } | ForEach-Object { $_.Module } | Sort-Object)
            throw "No ISR from '$name' in the pre-trace. Drivers that had ISRs: $($withIsr -join ', ')."
        }
        [pscustomobject]@{
            driver   = $stat.Module
            cpu      = $cpu
            isrOnCpu = $stat.IsrPerCpu[$cpu]
            isrTotal = ($stat.IsrPerCpu.Values | Measure-Object -Sum).Sum
        }
    }
}

function Get-ProbePlan {
    param(
        [AllowEmptyCollection()][int[]]$Cpu,
        [AllowEmptyCollection()][object[]]$Pick,
        [Parameter(Mandatory)][int]$ProcessorCount,
        [Parameter(Mandatory)][int]$DefaultCpu
    )
    $cpus = @(@($Cpu) + @($Pick | ForEach-Object { $_.cpu }) | Sort-Object -Unique)
    if ($cpus.Count -eq 0) { $cpus = @($DefaultCpu) }
    foreach ($c in $cpus) {
        if ($c -lt 0 -or $c -ge $ProcessorCount) { throw "CPU $c does not exist: this machine has CPUs 0 to $($ProcessorCount - 1)." }
        [pscustomobject]@{
            cpu     = [int]$c
            devices = @($Pick | Where-Object { $_.cpu -eq $c } | ForEach-Object { $_.driver })
        }
    }
}

function Get-StallSummary {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Gaps,
        [Parameter(Mandatory)][double]$SpanSeconds,
        [Parameter(Mandatory)][double]$ThresholdUs
    )
    $sorted = [double[]]$Gaps.Clone()
    [Array]::Sort($sorted)
    $edges = @($ThresholdUs) + @($histogramEdgesUs | Where-Object { $_ -gt $ThresholdUs })
    $counts = New-Object 'int[]' $edges.Count
    $sums = New-Object 'double[]' $edges.Count
    $total = 0.0
    $bucket = 0
    foreach ($gap in $sorted) {
        while ($bucket + 1 -lt $edges.Count -and $gap -ge $edges[$bucket + 1]) { $bucket++ }
        $counts[$bucket]++
        $sums[$bucket] += $gap
        $total += $gap
    }
    $histogram = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $edges.Count; $i++) {
        $histogram.Add([pscustomobject]@{
            fromUs     = $edges[$i]
            toUs       = if ($i + 1 -lt $edges.Count) { $edges[$i + 1] } else { $null }
            gaps       = $counts[$i]
            stalledUs  = [math]::Round($sums[$i], $roundDigits)
        })
    }
    [pscustomobject]@{
        gapsPerSecond = [math]::Round($sorted.Count / $SpanSeconds, $roundDigits)
        gapP50Us      = Get-Percentile $sorted 0.50 $roundDigits
        gapP99Us      = Get-Percentile $sorted 0.99 $roundDigits
        gapP999Us     = Get-Percentile $sorted 0.999 $roundDigits
        gapMaxUs      = if ($sorted.Count) { [math]::Round($sorted[-1], $roundDigits) } else { 0 }
        stalledUs     = [math]::Round($total, $roundDigits)
        stalledPct    = [math]::Round(100 * ($total / 1e6) / $SpanSeconds, 2)
        histogram     = $histogram.ToArray()
    }
}

function ConvertTo-GcRecord {
    param([Parameter(Mandatory)][int[]]$Count)
    $record = [ordered]@{}
    for ($g = 0; $g -lt $Count.Count; $g++) { $record["$gcKeyPrefix$g"] = $Count[$g] }
    $record
}

function Get-GcRejection {
    param([Parameter(Mandatory)][object[]]$Probe)
    $hit = @($Probe | Where-Object { (@($_.gcCollections.Values) | Measure-Object -Sum).Sum -gt 0 } | ForEach-Object {
        "CPU $($_.cpu) ($(@($_.gcCollections.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))"
    })
    if ($hit.Count) { "a garbage collection ran inside the window on $($hit -join ', ')" }
}

function Assert-LoadArgument {
    param([string]$Load, [string]$PresentMon, [Parameter(Mandatory)][bool]$SecondsGiven, [string[]]$Background, [string]$UsbReadFile, [switch]$ProcessCpu)
    if ($Load -and -not $PresentMon) { throw '-Load needs -PresentMon <path to the pinned PresentMon exe>.' }
    if ($PresentMon -and -not $Load) { throw '-PresentMon needs -Load <name> (a file in bench\loads).' }
    if ($Load -and $SecondsGiven) { throw "-Seconds cannot be combined with -Load: the window is the recipe's capture time." }
    if ($Background.Count -and -not $Load) { throw '-Background needs -Load <name>: the loads run from the load pause to the end of the capture.' }
    if ($ProcessCpu -and -not $Load) { throw '-ProcessCpu needs -Load <name>: the process list covers the load capture window.' }
    if ((@($Background) -contains 'usb-read') -and -not $UsbReadFile) { throw '-Background usb-read needs -UsbReadFile <path to the file to read>.' }
    if ($UsbReadFile -and (@($Background) -notcontains 'usb-read')) { throw '-UsbReadFile needs -Background usb-read.' }
}

function Assert-UsbReadFile {
    param([Parameter(Mandatory)][string]$Path, [long]$MinBytes = $usbReadMinBytes)
    if (-not (Test-Path -LiteralPath $Path)) { throw "the USB read file $Path is missing" }
    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -lt $MinBytes) { throw "the USB read file $Path is smaller than $MinBytes bytes ($length)" }
}

function Get-DefaultPlaybackEndpointId {
    [PlaybackEndpoint]::DefaultId()
}

function Get-ParentInstanceId {
    param([Parameter(Mandatory)][string]$InstanceId)
    (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
}

function Find-PciAncestor {
    param([Parameter(Mandatory)][string]$InstanceId)
    $current = $InstanceId
    for ($depth = 0; $depth -lt $pnpParentMaxDepth; $depth++) {
        $parent = Get-ParentInstanceId -InstanceId $current
        if (-not $parent) { return $null }
        if ($parent -like 'PCI\*') { return $parent }
        $current = $parent
    }
    $null
}

function Get-PlaybackDevice {
    $instanceId = "SWD\MMDEVAPI\$(Get-DefaultPlaybackEndpointId)"
    $device = Get-PnpDevice -InstanceId $instanceId -ErrorAction SilentlyContinue
    [pscustomobject]@{
        deviceName           = $device.FriendlyName
        controllerInstanceId = Find-PciAncestor -InstanceId $instanceId
    }
}

function Start-BenchTonePlayback {
    param([Parameter(Mandatory)][byte[]]$Wave)
    $player = New-Object System.Media.SoundPlayer -ArgumentList (New-Object System.IO.MemoryStream -ArgumentList (, $Wave))
    $player.Load()
    $player.PlayLooping()
    $player
}

function Stop-BenchTonePlayback {
    param([Parameter(Mandatory)]$Player)
    $Player.Stop()
    $Player.Dispose()
}

function New-BenchUsbReader {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$BlockBytes)
    New-Object UsbReader -ArgumentList $Path, $BlockBytes
}

function Start-BenchBackground {
    param([Parameter(Mandatory)][string[]]$Name, [string]$UsbReadFile)
    $handle = [pscustomobject]@{ Tone = $null; Device = $null; Reader = $null }
    try {
        if ($Name -contains 'tone') {
            $handle.Device = Get-PlaybackDevice
            $wave = [ToneWave]::Build($toneFrequencyHz, $toneDbfs, $toneSampleRate, $toneSeconds)
            $handle.Tone = Start-BenchTonePlayback -Wave $wave
        }
        if ($Name -contains 'usb-read') {
            $handle.Reader = New-BenchUsbReader -Path $UsbReadFile -BlockBytes $usbReadBlockBytes
            $handle.Reader.Start()
        }
    } catch {
        Stop-BenchBackground -Handle $handle | Out-Null
        throw
    }
    $handle
}

function Stop-BenchBackground {
    param([Parameter(Mandatory)]$Handle)
    $stats = [ordered]@{}
    $read = if ($Handle.Reader) { $Handle.Reader.Stop($usbReadStopTimeoutMs) }
    if ($Handle.Tone) {
        Stop-BenchTonePlayback -Player $Handle.Tone
        $stats.tone = [ordered]@{
            frequencyHz          = $toneFrequencyHz
            dbfs                 = $toneDbfs
            sampleRate           = $toneSampleRate
            deviceName           = $Handle.Device.deviceName
            controllerInstanceId = $Handle.Device.controllerInstanceId
        }
    }
    if ($read) {
        $rate = if ($read.Seconds -gt 0) { $read.BytesRead / $mebibyteBytes / $read.Seconds } else { 0 }
        $stats.usbRead = [ordered]@{
            bytesRead    = $read.BytesRead
            wraps        = $read.Wraps
            seconds      = [math]::Round($read.Seconds, 1)
            mibPerSecond = [math]::Round($rate, 1)
            blockBytes   = $usbReadBlockBytes
            error        = $read.Error
        }
    }
    $stats
}

function Get-BackgroundRejection {
    param($Background)
    if ($Background -and $Background.Contains('usbRead') -and $Background.usbRead.error) { "the USB read failed: $($Background.usbRead.error)" }
}

function Get-RouteRejection {
    param([Parameter(Mandatory)]$Recipe, [Parameter(Mandatory)][double]$EndSeconds)
    if ($Recipe.workshop -and $EndSeconds -gt $Recipe.workshop.routeSeconds) { "the capture ended $EndSeconds s after the start line, past the $($Recipe.workshop.routeSeconds) s route" }
}

function New-LoadClock {
    [System.Diagnostics.Stopwatch]::StartNew()
}

function Start-LoadWithBackground {
    param([Parameter(Mandatory)]$Recipe, [string[]]$Background, [string]$UsbReadFile)
    $process = Wait-LoadStart -Recipe $Recipe
    $clock = New-LoadClock
    $handle = if ($Background.Count) { Start-BenchBackground -Name $Background -UsbReadFile $UsbReadFile }
    Write-Host "Load started. Waiting $($Recipe.timings.loadPauseSeconds) s, then capturing $($Recipe.timings.captureSeconds) s. Do not touch the PC."
    [pscustomobject]@{ Process = $process; Background = $handle; Clock = $clock }
}

function Wait-LoadPause {
    param([Parameter(Mandatory)]$Clock, [Parameter(Mandatory)][double]$Seconds)
    $remaining = $Seconds - $Clock.Elapsed.TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][math]::Round($remaining * (Get-BenchConfig).MsPerSecond)) }
}

function Get-ProcessCpuSnapshot {
    foreach ($process in Get-Process) {
        try { $seconds = $process.TotalProcessorTime.TotalSeconds } catch { continue }
        [pscustomobject]@{ id = $process.Id; name = $process.ProcessName; seconds = $seconds }
    }
}

function Get-ProcessCpuDelta {
    param(
        [AllowEmptyCollection()][object[]]$Before,
        [AllowEmptyCollection()][object[]]$After,
        [double]$MinSeconds = $processCpuMinSeconds
    )
    $start = @{}
    foreach ($process in $Before) { $start["$($process.id)|$($process.name)"] = $process.seconds }
    $rows = foreach ($process in $After) {
        $key = "$($process.id)|$($process.name)"
        $from = if ($start.ContainsKey($key)) { $start[$key] } else { 0 }
        $delta = $process.seconds - $from
        if ($delta -ge $MinSeconds) {
            [pscustomobject]@{ name = $process.name; pid = $process.id; cpuSeconds = [math]::Round($delta, 3) }
        }
    }
    @($rows | Sort-Object cpuSeconds -Descending)
}

function Get-SystemCpuSnapshot {
    $times = [SystemTimes]::Read()
    [pscustomobject]@{ idle = $times[0]; kernel = $times[1]; user = $times[2] }
}

function Get-SystemCpuDelta {
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [Parameter(Mandatory)][double]$WindowSeconds,
        [Parameter(Mandatory)][int]$LogicalCpus
    )
    $idle = $After.idle - $Before.idle
    $busy = ($After.kernel - $Before.kernel) - $idle + ($After.user - $Before.user)
    [ordered]@{
        windowSeconds = [math]::Round($WindowSeconds, 3)
        busySeconds   = [math]::Round($busy / $fileTimeTicksPerSecond, 3)
        idleSeconds   = [math]::Round($idle / $fileTimeTicksPerSecond, 3)
        logicalCpus   = $LogicalCpus
    }
}

function Add-ProcessCpuField {
    param([Parameter(Mandatory)]$Result, [switch]$ProcessCpu, $Before, $After)
    if ($ProcessCpu) { $Result.processCpu = @(Get-ProcessCpuDelta -Before $Before -After $After) }
}

function Stop-CaptureWindow {
    param([Parameter(Mandatory)][bool]$Trace, [Parameter(Mandatory)]$Watch, $Background, [switch]$ProcessCpu)
    if ($Trace) { Stop-KernelTrace }
    $seconds = $Watch.Elapsed.TotalSeconds
    $systemAfter = Get-SystemCpuSnapshot
    $cpuAfter = if ($ProcessCpu) { @(Get-ProcessCpuSnapshot) } else { @() }
    $stats = if ($Background) { Stop-BenchBackground -Handle $Background }
    [pscustomobject]@{ Seconds = $seconds; SystemCpuAfter = $systemAfter; ProcessCpuAfter = $cpuAfter; Background = $stats }
}

function Get-DriverRow {
    param([Parameter(Mandatory)]$Stat)
    $isrSorted = [double[]]($Stat.IsrUs | Sort-Object)
    $dpcSorted = [double[]]($Stat.DpcUs | Sort-Object)
    [pscustomobject]@{
        driver     = $Stat.Module
        isrPlain   = $Stat.IsrLine
        isrMessage = $Stat.IsrMsi
        isrPerCpu  = @($Stat.IsrPerCpu.GetEnumerator() | Sort-Object Key | ForEach-Object { [pscustomobject]@{ cpu = $_.Key; isr = $_.Value } })
        vectors    = (($Stat.Vectors.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key):$($_.Value)" }) -join " ")
        isrMaxUs   = if ($isrSorted.Count) { [math]::Round($isrSorted[-1], 1) } else { 0 }
        isrMeanUs  = if ($isrSorted.Count) { [math]::Round(($Stat.IsrUs | Measure-Object -Average).Average, 2) } else { 0 }
        isrTotalUs = [math]::Round([double]($Stat.IsrUs | Measure-Object -Sum).Sum, 1)
        dpcCount   = $Stat.DpcCount
        dpcMaxUs   = if ($dpcSorted.Count) { [math]::Round($dpcSorted[-1], 1) } else { 0 }
        dpcP99Us   = Get-Percentile $dpcSorted 0.99 1
        dpcMeanUs  = if ($dpcSorted.Count) { [math]::Round(($Stat.DpcUs | Measure-Object -Average).Average, 2) } else { 0 }
        dpcTotalUs = [math]::Round([double]($Stat.DpcUs | Measure-Object -Sum).Sum, 1)
    }
}

function Get-StallTimelineLine {
    param(
        [Parameter(Mandatory)][int]$Cpu,
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$OffsetsMs,
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$GapsUs
    )
    for ($i = 0; $i -lt $OffsetsMs.Count; $i++) {
        "$Cpu,$(Format-Invariant $OffsetsMs[$i]),$(Format-Invariant $GapsUs[$i])"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { throw "-OutDir '$OutDir' does not exist." }
    Assert-LoadArgument -Load $Load -PresentMon $PresentMon -SecondsGiven $PSBoundParameters.ContainsKey('Seconds') -Background $Background -UsbReadFile $UsbReadFile -ProcessCpu:$ProcessCpu
    if ($Background -contains 'usb-read') { Assert-UsbReadFile -Path $UsbReadFile }
    $recipe = if ($Load) { Get-LoadRecipe -Name $Load } else { $null }
    $windowSeconds = if ($recipe) { [int]$recipe.timings.captureSeconds } else { $Seconds }
    $cpuList = @(ConvertTo-ListArgument $Cpu | ForEach-Object { [int]$_ })
    $deviceList = @(ConvertTo-ListArgument $Device)
    $processorCount = [Environment]::ProcessorCount
    $null = @(Get-ProbePlan -Cpu $cpuList -Pick @() -ProcessorCount $processorCount -DefaultCpu $defaultProbeCpu)
    if ($deviceList.Count -and ($SkipTrace -or -not $isAdmin)) { throw '-Device needs the kernel trace: run elevated and without -SkipTrace.' }

    Add-Type -TypeDefinition $msiBenchSource
    Write-Host "Phase: $Phase"
    $metadata = Get-BenchMetadata -BenchScript $PSCommandPath -Load $Load -PresentMonVersion $recipe.presentMon.version
    $table = @(Get-InterruptTable)
    $table | Sort-Object Class, Device | Format-Table Device, MSISupported, Mode, SharedWith -AutoSize -Wrap | Out-String -Width 200 | Write-Host

    $doTrace = $isAdmin -and -not $SkipTrace
    if (-not $isAdmin) { Write-Host 'Not elevated: the kernel trace needs admin, running the stall probe only.' -ForegroundColor Yellow }

    $loadRecord = $null
    $backgroundHandle = $null
    $loadClock = $null
    $loadPause = 0
    $onRoute = $false
    try {
        if ($recipe) {
            Write-Host "Load: $($recipe.title). Start it as bench\README.md says; this window waits."
            if ($recipe.consoleLine) { Write-Host "Console line: $($recipe.consoleLine)" }
            $started = Start-LoadWithBackground -Recipe $recipe -Background $Background -UsbReadFile $UsbReadFile
            $backgroundHandle = $started.Background
            $loadClock = $started.Clock
            $loadPause = $recipe.timings.loadPauseSeconds
            $onRoute = [bool]($recipe.workshop -and $recipe.workshop.routeSeconds)
            if (-not $onRoute) { Start-Sleep -Seconds $loadPause }
            $loadRecord = Get-LoadRecord -Recipe $recipe -Name $Load -Process $started.Process
        }

        $picks = @()
        if ($deviceList.Count) {
            Write-Host "Pre-trace for $preTraceSeconds s to find the CPU of each -Device driver..."
            $preEtl = Join-Path $env:TEMP "msi-bench-$Phase-pick.etl"
            Start-KernelTrace -Etl $preEtl
            try { Start-Sleep -Seconds $preTraceSeconds } finally { Stop-KernelTrace }
            $preTrace = Read-KernelTrace -Etl $preEtl
            $picks = @(Get-DeviceCpuPick -Stats $preTrace.Stats -Driver $deviceList)
            $preTrace = $null
            foreach ($pick in $picks) { Write-Host ("{0}: CPU {1} ({2} of {3} ISRs)" -f $pick.driver, $pick.cpu, $pick.isrOnCpu, $pick.isrTotal) }
        }

        $plan = @(Get-ProbePlan -Cpu $cpuList -Pick $picks -ProcessorCount $processorCount -DefaultCpu $defaultProbeCpu)
        $probes = @($plan | ForEach-Object { New-Object StallProbe -ArgumentList $_.cpu, $windowSeconds, $GapThresholdUs })
        $etl = Join-Path $env:TEMP "msi-bench-$Phase.etl"

        Write-Host "Measuring for $windowSeconds s on CPU $(($plan | ForEach-Object { $_.cpu }) -join ','), keep your load running..."
        $spans = New-Object 'double[]' $probes.Count
        $gapSets = New-Object 'object[]' $probes.Count
        $traceSeconds = 0.0
        $capture = $null
        $loadWindowStart = $null
        $loadWindowEnd = $null
        $presentMonCsvName = "msi-bench-$Phase-presentmon.csv"
        $backgroundStats = $null
        if ($onRoute) { Wait-LoadPause -Clock $loadClock -Seconds $loadPause }
        $systemBefore = Get-SystemCpuSnapshot
        $cpuBefore = if ($ProcessCpu) { @(Get-ProcessCpuSnapshot) } else { @() }
        $cpuAfter = @()
        $systemAfter = $null
        if ($doTrace) { Start-KernelTrace -Etl $etl }
        $traceWatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($loadClock) { $loadWindowStart = $loadClock.Elapsed.TotalSeconds }
        try {
            foreach ($p in $probes) { $p.Start() }
            if ($recipe) {
                $capture = Invoke-PresentMonCapture -PresentMonPath $PresentMon -ProcessName $recipe.presentMonProcess -OutputFile (Join-Path $OutDir $presentMonCsvName) -Seconds $windowSeconds -ExpectedSha256 $recipe.presentMon.sha256
                $loadWindowEnd = $loadClock.Elapsed.TotalSeconds
            }
            foreach ($p in $probes) { $p.Join() }
            for ($i = 0; $i -lt $probes.Count; $i++) {
                $span = 0.0
                $gapSets[$i] = $probes[$i].Stop([ref]$span)
                $spans[$i] = $span
            }
        } finally {
            $window = Stop-CaptureWindow -Trace $doTrace -Watch $traceWatch -Background $backgroundHandle -ProcessCpu:$ProcessCpu
            $backgroundHandle = $null
            $cpuAfter = $window.ProcessCpuAfter
            $backgroundStats = $window.Background
            $traceSeconds = $window.Seconds
            $systemAfter = $window.SystemCpuAfter
        }
    } finally {
        if ($backgroundHandle) { Stop-BenchBackground -Handle $backgroundHandle | Out-Null }
    }

    $probeResults = New-Object System.Collections.Generic.List[object]
    $timelineLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $probes.Count; $i++) {
        $summary = Get-StallSummary -Gaps ([double[]]$gapSets[$i]) -SpanSeconds $spans[$i] -ThresholdUs $GapThresholdUs
        $probeResults.Add([pscustomobject]@{
            cpu            = $plan[$i].cpu
            devices        = @($plan[$i].devices)
            seconds        = [math]::Round($spans[$i], 1)
            gapThresholdUs = $GapThresholdUs
            gapsPerSecond  = $summary.gapsPerSecond
            gapP50Us       = $summary.gapP50Us
            gapP99Us       = $summary.gapP99Us
            gapP999Us      = $summary.gapP999Us
            gapMaxUs       = $summary.gapMaxUs
            stalledUs      = $summary.stalledUs
            stalledPct     = $summary.stalledPct
            histogram      = $summary.histogram
            gcCollections  = ConvertTo-GcRecord -Count $probes[$i].GcCollections
        })
        $timelineLines.AddRange([string[]]@(Get-StallTimelineLine -Cpu $plan[$i].cpu -OffsetsMs $probes[$i].TimelineOffsetsMs -GapsUs $probes[$i].TimelineGapsUs))
    }
    Write-Host 'Stall probe (gaps in a spinning time-critical thread):'
    $probeResults | Format-Table cpu, @{ n = 'devices'; e = { $_.devices -join ',' } }, seconds, gapsPerSecond, gapP50Us, gapP99Us, gapP999Us, gapMaxUs, stalledUs, stalledPct -AutoSize | Out-String -Width 200 | Write-Host
    $stallsName = "msi-bench-$Phase-stalls.csv"
    Write-CsvFile -Path (Join-Path $OutDir $stallsName) -Header 'cpu,offsetMs,gapUs' -Lines $timelineLines.ToArray()

    $trace = $null
    $cpuPick = $null
    if ($doTrace) {
        Write-Host 'Decoding the kernel trace...'
        $data = Read-KernelTrace -Etl $etl
        $drivers = foreach ($s in $data.Stats.Values) { Get-DriverRow -Stat $s }
        $drivers = @($drivers | Sort-Object dpcMaxUs -Descending)
        $trace = [pscustomobject]@{
            seconds          = [math]::Round($traceSeconds, 1)
            clockType        = Get-ClockName $data.ClockType
            isrPlain         = $data.IsrLine
            isrMessage       = $data.IsrMsi
            dpcCount         = $data.Dpc
            droppedEvents    = $data.Dropped
            isrPlainPerCpu   = @($data.IsrPlainPerCpu.GetEnumerator() | Sort-Object Key | ForEach-Object { [pscustomobject]@{ cpu = $_.Key; isr = $_.Value } })
            isrMessagePerCpu = @($data.IsrMessagePerCpu.GetEnumerator() | Sort-Object Key | ForEach-Object { [pscustomobject]@{ cpu = $_.Key; isr = $_.Value } })
            drivers          = $drivers
        }
        Write-Host ("Kernel trace: {0} plain ISRs, {1} message-based ISRs, {2} DPCs in {3} s ({4} undecodable events dropped)" -f $data.IsrLine, $data.IsrMsi, $data.Dpc, $trace.seconds, $data.Dropped)
        foreach ($pair in @(@('Plain ISRs land on', $data.IsrPlainPerCpu), @('Message-based ISRs land on', $data.IsrMessagePerCpu))) {
            if ($pair[1].Count) {
                Write-Host "$($pair[0]): " -NoNewline
                Write-Host (($pair[1].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { "CPU $($_.Key): $($_.Value)" }) -join ', ')
            }
        }
        $drivers | Select-Object -First 15 | Format-Table driver, isrPlain, isrMessage, isrMaxUs, isrMeanUs, dpcCount, dpcMaxUs, dpcP99Us, dpcMeanUs, vectors -AutoSize | Out-String -Width 200 | Write-Host
        if ($picks.Count) {
            $cpuPick = [pscustomobject]@{
                preTraceSeconds = $preTraceSeconds
                devices         = @($picks | ForEach-Object {
                    $mainStat = Find-DriverStat -Stats $data.Stats -Driver $_.driver
                    [pscustomobject]@{
                        driver       = $_.driver
                        cpu          = $_.cpu
                        isrOnCpu     = $_.isrOnCpu
                        isrTotal     = $_.isrTotal
                        mainTraceCpu = if ($mainStat) { Get-TopIsrCpu $mainStat } else { $null }
                    }
                })
            }
            $cpuPick.devices | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        }
    }

    $files = @($stallsName)
    $rejected = $null
    $result = [ordered]@{
        phase     = $Phase
        timestamp = (Get-Date).ToString('s')
        devices   = $table
        probes    = $probeResults.ToArray()
        cpuPick   = $cpuPick
        trace     = $trace
    }
    if ($recipe) {
        $stats = Import-Csv -Path $capture.csv | Get-FrameStats
        $loadWindow = [ordered]@{ startSeconds = [math]::Round($loadWindowStart, $roundDigits); endSeconds = [math]::Round($loadWindowEnd, $roundDigits) }
        $rejected = Join-Rejection -Reason @((Get-GameRejection -Stats $stats -Capture $capture -Video $loadRecord.videoConfig -Recipe $recipe), (Get-BackgroundRejection -Background $backgroundStats), (Get-RouteRejection -Recipe $recipe -EndSeconds $loadWindow.endSeconds), (Get-GcRejection -Probe $probeResults.ToArray()))
        $files += $presentMonCsvName
        $result.load = $loadRecord
        $result.loadWindow = $loadWindow
        $result.presentMon = [pscustomobject]@{ sha256 = $capture.presentMonSha256; overflowedPresents = $capture.overflowedPresents }
        $result.frames = $stats
        $result.systemCpu = Get-SystemCpuDelta -Before $systemBefore -After $systemAfter -WindowSeconds $traceSeconds -LogicalCpus $processorCount
        Add-ProcessCpuField -Result $result -ProcessCpu:$ProcessCpu -Before $cpuBefore -After $cpuAfter
        if ($backgroundStats) { $result.background = $backgroundStats }
        $result.rejected = $rejected
        Write-Host ("Frames: {0} at {1} fps avg, p50 {2} ms, 1% low {3} ms, {4} lost to present buffer overflow" -f $stats.frames, $stats.avgFps, $stats.p50Ms, $stats.low1PctMs, $capture.overflowedPresents)
    }
    $result.files = $files
    $result.metadata = $metadata
    Write-BenchResult -Object ([pscustomobject]$result) -Path (Join-Path $OutDir "msi-bench-$Phase.json")
    Write-Host "Saved msi-bench-$Phase.json"
    if ($rejected) { throw "Run rejected: $rejected. The result file is kept." }
}
