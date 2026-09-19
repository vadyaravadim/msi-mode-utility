<#
.SYNOPSIS
    MSI-mode micro-benchmark: interrupt mode per device, per-driver ISR/DPC times, and how long
    interrupts stall a CPU core. Built-in Windows tools only, nothing to install.

.DESCRIPTION
    Run it once per state you want to compare (stock / after msi-mode-utility / a device forced
    back to line-based) with the same load running each time (a game, a browser scene, audio):

      1. Interrupt mode table. For every present PCI device with an "Interrupt Management" key:
         the MSISupported registry value (on / off / default = value absent, the driver decides)
         and the IRQs Windows actually assigned. A negative IRQ is a message-signaled vector, a
         small positive number is a legacy line, and the table names the devices sharing it.
         Same rule Device Manager and msinfo32 use.

      2. Kernel trace (needs admin, skipped otherwise). The built-in NT Kernel Logger records
         every ISR and DPC for -Seconds seconds; tracerpt decodes it and the script attributes
         each one to its driver. Per driver: ISR count, DPC count, max / p99 / mean durations in
         microseconds and the interrupt vectors seen, the same data LatencyMon shows on its
         Drivers tab. ETW logs two ISR event types: "isrMessage" is a driver that connected a
         message-based routine (always MSI), "isrPlain" is everything else. KMDF drivers
         (Wdf01000.sys: USB xHCI, GPIO) log as plain even in MSI mode, so the interrupt mode
         table above is the ground truth of the mode, not this split.

      3. Stall probe. While the trace runs, a time-critical thread pinned to one CPU (-Cpu,
         default 0) spins reading the high-resolution clock and records every gap above
         -GapThresholdUs. Every interrupt, DPC or hypervisor intercept that lands on that core
         shows up as a gap, so the tail (p99 / max) is what a game thread on that core would feel.

    Results print to the console and are saved as msi-bench-<phase>.json next to this script.
    Pair it with PresentMon for frame times. These are the tools behind the numbers in the
    RigPolice article: https://rigpolice.com/system/articles/enable-msi-mode/

.EXAMPLE
    .\msi-bench.ps1 -Phase stock -Seconds 30
    # ...enable MSI mode with msi-mode-utility, reboot, start the same load...
    .\msi-bench.ps1 -Phase msi -Seconds 30
#>
param(
    [Parameter(Mandatory)][string]$Phase,
    [int]$Seconds = 30,
    [int]$Cpu = 0,
    [double]$GapThresholdUs = 10,
    [switch]$SkipTrace
)
$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::InvariantCulture
$outDir = $PSScriptRoot
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class StallProbe {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool SetThreadPriority(IntPtr thread, int priority);
    [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr thread, UIntPtr mask);
    static List<double> gaps; static Thread worker; static long spanTicks;

    public static void Start(int seconds, int cpu, double thresholdUs) {
        gaps = new List<double>(1 << 16);
        worker = new Thread(() => {
            SetThreadAffinityMask(GetCurrentThread(), (UIntPtr)(1UL << cpu));
            SetThreadPriority(GetCurrentThread(), 15);
            double usPerTick = 1e6 / Stopwatch.Frequency;
            long start = Stopwatch.GetTimestamp(), end = start + seconds * Stopwatch.Frequency;
            long prev = start;
            while (prev < end) {
                long now = Stopwatch.GetTimestamp();
                double gap = (now - prev) * usPerTick;
                if (gap > thresholdUs) gaps.Add(gap);
                prev = now;
            }
            spanTicks = prev - start;
        });
        worker.Start();
    }
    public static double[] Stop(out double spanSeconds) {
        worker.Join();
        spanSeconds = (double)spanTicks / Stopwatch.Frequency;
        return gaps.ToArray();
    }
}

public class DriverStat {
    public string Module; public int IsrLine, IsrMsi, DpcCount;
    public Dictionary<int, int> Vectors = new Dictionary<int, int>();
    public List<double> IsrUs = new List<double>(), DpcUs = new List<double>();
}

public static class KernelCsv {
    // tracerpt CSV column layout: 0 Event Name, 1 Type, ..., 11 Processor, 16 Clock-Time, 19.. User Data.
    // PerfInfo ISR / ISR-MSI / DPC user data starts with InitialTime, Routine; Image rows with ImageBase, ImageSize
    // and end with the file name. Clock-Time and InitialTime share the trace clock (100 ns units).
    struct Img { public ulong Base, Size; public string Name; }

    static string[] Split(string line) {
        var parts = line.Split(',');
        for (int i = 0; i < parts.Length; i++) parts[i] = parts[i].Trim();
        return parts;
    }
    static ulong Hex(string s) { return ulong.Parse(s.Substring(2), NumberStyles.HexNumber); }

    public static Dictionary<string, DriverStat> Parse(string path, out long totalIsrLine, out long totalIsrMsi, out long totalDpc, out Dictionary<int, long> isrPerCpu, out Dictionary<int, long> msiPerCpu, out long dropped) {
        var images = new List<Img>();
        var events = new List<string[]>();
        foreach (var line in File.ReadLines(path)) {
            var t = line.TrimStart();
            if (t.StartsWith("PerfInfo,")) {
                var p = Split(line);
                if (p[1] == "ISR" || p[1] == "ISR-MSI" || p[1].EndsWith("DPC")) events.Add(p);
            } else if (t.StartsWith("Image,")) {
                var p = Split(line);
                if (p.Length < 22 || p[21] != "0") continue;
                string name = p[p.Length - 1].Trim('"');
                int slash = name.LastIndexOf('\\');
                images.Add(new Img { Base = Hex(p[19]), Size = Hex(p[20]), Name = slash >= 0 ? name.Substring(slash + 1) : name });
            }
        }
        images.Sort((a, b) => a.Base.CompareTo(b.Base));
        var bases = new ulong[images.Count];
        for (int i = 0; i < images.Count; i++) bases[i] = images[i].Base;

        var stats = new Dictionary<string, DriverStat>();
        totalIsrLine = totalIsrMsi = totalDpc = dropped = 0;
        isrPerCpu = new Dictionary<int, long>();
        msiPerCpu = new Dictionary<int, long>();
        foreach (var p in events) {
            ulong routine = Hex(p[20]);
            int idx = Array.BinarySearch(bases, routine);
            if (idx < 0) idx = ~idx - 1;
            string module = (idx >= 0 && routine < images[idx].Base + images[idx].Size) ? images[idx].Name : "unknown";
            DriverStat s;
            if (!stats.TryGetValue(module, out s)) { s = new DriverStat { Module = module }; stats[module] = s; }
            double us = (long.Parse(p[16]) - long.Parse(p[19])) / 10.0;
            // A routine that outlives a second is a decode artifact (an InitialTime from before the trace), not a DPC.
            if (us < 0 || us > 1e6) { dropped++; continue; }
            int cpu = int.Parse(p[11]);
            if (p[1] == "ISR" || p[1] == "ISR-MSI") {
                var perCpu = p[1] == "ISR" ? isrPerCpu : msiPerCpu;
                if (p[1] == "ISR") { s.IsrLine++; totalIsrLine++; } else { s.IsrMsi++; totalIsrMsi++; }
                long c; perCpu.TryGetValue(cpu, out c); perCpu[cpu] = c + 1;
                int vector = int.Parse(p[22]); int vc; s.Vectors.TryGetValue(vector, out vc); s.Vectors[vector] = vc + 1;
                s.IsrUs.Add(us);
            } else {
                s.DpcCount++; totalDpc++;
                s.DpcUs.Add(us);
            }
        }
        return stats;
    }
}
'@

function Get-InterruptTable {
    $names = @{}
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\*' } | ForEach-Object { $names[$_.InstanceId] = $_ }

    $irqs = @{}
    Get-CimInstance Win32_PNPAllocatedResource | ForEach-Object {
        if ($_.Antecedent.CimClass.CimClassName -ne 'Win32_IRQResource') { return }
        $id = $_.Dependent.DeviceID
        $n = [int64]$_.Antecedent.IRQNumber
        if ($n -gt 2147483647) { $n -= 4294967296 }
        if (-not $irqs.ContainsKey($id)) { $irqs[$id] = New-Object System.Collections.Generic.List[int64] }
        $irqs[$id].Add($n)
    }

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

        $vectors = if ($irqs.ContainsKey($id)) { $irqs[$id] } else { @() }
        $neg = @($vectors | Where-Object { $_ -lt 0 })
        $pos = @($vectors | Where-Object { $_ -ge 0 })
        $mode = if ($neg.Count -gt 0 -and $pos.Count -eq 0) {
            if ($neg.Count -eq 1) { 'message-signaled, 1 vector' } else { "message-signaled, $($neg.Count) vectors" }
        } elseif ($pos.Count -gt 0) {
            "line IRQ $($pos -join ',')"
        } else { 'no IRQ assigned' }

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

function Get-Percentile([double[]]$sorted, [double]$q) {
    if ($sorted.Count -eq 0) { return 0 }
    [math]::Round($sorted[[math]::Min($sorted.Count - 1, [int][math]::Floor($sorted.Count * $q))], 1)
}

Write-Host "Phase: $Phase"
$table = @(Get-InterruptTable)
$table | Sort-Object Class, Device | Format-Table Device, MSISupported, Mode, SharedWith -AutoSize -Wrap | Out-String -Width 200 | Write-Host

$trace = $null
$probe = $null
$doTrace = $isAdmin -and -not $SkipTrace
if (-not $isAdmin) { Write-Host 'Not elevated: the kernel trace needs admin, running the stall probe only.' -ForegroundColor Yellow }

$etl = Join-Path $env:TEMP "msi-bench-$Phase.etl"
$csv = Join-Path $env:TEMP "msi-bench-$Phase.csv"
if ($doTrace) {
    Remove-Item $etl, $csv -ErrorAction SilentlyContinue
    & logman stop 'NT Kernel Logger' -ets 2>&1 | Out-Null
    & logman start 'NT Kernel Logger' -p 'Windows Kernel Trace' '(img,dpc,isr)' -o $etl -ets | Out-Null
}
Write-Host "Measuring for $Seconds s on CPU $Cpu, keep your load running..."
[StallProbe]::Start($Seconds, $Cpu, $GapThresholdUs)
if ($doTrace) { Start-Sleep -Seconds $Seconds; & logman stop 'NT Kernel Logger' -ets | Out-Null }
$span = 0.0
$gaps = [StallProbe]::Stop([ref]$span)
$sortedGaps = [double[]]($gaps | Sort-Object)
$probe = [pscustomobject]@{
    cpu           = $Cpu
    seconds       = [math]::Round($span, 1)
    gapsPerSecond = [math]::Round($gaps.Count / $span, 1)
    gapP50Us      = Get-Percentile $sortedGaps 0.50
    gapP99Us      = Get-Percentile $sortedGaps 0.99
    gapP999Us     = Get-Percentile $sortedGaps 0.999
    gapMaxUs      = if ($gaps.Count) { [math]::Round($sortedGaps[-1], 1) } else { 0 }
    stalledPct    = [math]::Round(100 * (($gaps | Measure-Object -Sum).Sum / 1e6) / $span, 2)
}
Write-Host 'Stall probe (gaps in a spinning time-critical thread):'
$probe | Format-List | Out-String | Write-Host

if ($doTrace) {
    Write-Host 'Decoding the kernel trace...'
    & tracerpt $etl -o $csv -of CSV -y | Out-Null
    $isrLine = 0L; $isrMsi = 0L; $dpc = 0L; $perCpu = $null; $msiCpu = $null; $dropped = 0L
    $stats = [KernelCsv]::Parse($csv, [ref]$isrLine, [ref]$isrMsi, [ref]$dpc, [ref]$perCpu, [ref]$msiCpu, [ref]$dropped)
    $drivers = foreach ($s in $stats.Values) {
        $isrSorted = [double[]]($s.IsrUs | Sort-Object)
        $dpcSorted = [double[]]($s.DpcUs | Sort-Object)
        [pscustomobject]@{
            driver    = $s.Module
            isrPlain   = $s.IsrLine
            isrMessage = $s.IsrMsi
            vectors    = (($s.Vectors.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key):$($_.Value)" }) -join " ")
            isrMaxUs  = if ($isrSorted.Count) { [math]::Round($isrSorted[-1], 1) } else { 0 }
            isrMeanUs = if ($isrSorted.Count) { [math]::Round(($s.IsrUs | Measure-Object -Average).Average, 2) } else { 0 }
            dpcCount  = $s.DpcCount
            dpcMaxUs  = if ($dpcSorted.Count) { [math]::Round($dpcSorted[-1], 1) } else { 0 }
            dpcP99Us  = Get-Percentile $dpcSorted 0.99
            dpcMeanUs = if ($dpcSorted.Count) { [math]::Round(($s.DpcUs | Measure-Object -Average).Average, 2) } else { 0 }
        }
    }
    $drivers = @($drivers | Sort-Object dpcMaxUs -Descending)
    $trace = [pscustomobject]@{
        seconds      = $Seconds
        isrPlain     = $isrLine
        isrMessage   = $isrMsi
        dpcCount     = $dpc
        droppedEvents = $dropped
        isrPlainPerCpu = @($perCpu.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]@{ cpu = $_.Key; isr = $_.Value } })
        isrMessagePerCpu = @($msiCpu.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]@{ cpu = $_.Key; isr = $_.Value } })
        drivers      = $drivers
    }
    Write-Host ("Kernel trace: {0} plain ISRs, {1} message-based ISRs, {2} DPCs in {3} s ({4} undecodable events dropped)" -f $isrLine, $isrMsi, $dpc, $Seconds, $dropped)
    foreach ($pair in @(@('Plain ISRs land on', $perCpu), @('Message-based ISRs land on', $msiCpu))) {
        if ($pair[1].Count) {
            Write-Host "$($pair[0]): " -NoNewline
            Write-Host (($pair[1].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { "CPU $($_.Key): $($_.Value)" }) -join ', ')
        }
    }
    $drivers | Select-Object -First 15 | Format-Table driver, isrPlain, isrMessage, isrMaxUs, isrMeanUs, dpcCount, dpcMaxUs, dpcP99Us, dpcMeanUs, vectors -AutoSize | Out-String -Width 200 | Write-Host
    Remove-Item $etl, $csv -ErrorAction SilentlyContinue
}

[pscustomobject]@{
    phase     = $Phase
    timestamp = (Get-Date).ToString('s')
    devices   = $table
    probe     = $probe
    trace     = $trace
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir "msi-bench-$Phase.json")
Write-Host "Saved msi-bench-$Phase.json"
