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
         every ISR and DPC for -Seconds seconds on the performance-counter clock; tracerpt decodes
         it and the script attributes each one to its driver. Per driver: ISR count (also per CPU),
         DPC count, max / p99 / mean durations in microseconds and the interrupt vectors seen, the
         same data LatencyMon shows on its Drivers tab. ETW logs two ISR event types: "isrMessage"
         is a driver that connected a message-based routine (always MSI), "isrPlain" is everything
         else. KMDF drivers (Wdf01000.sys: USB xHCI, GPIO) log as plain even in MSI mode, so the
         interrupt mode table above is the ground truth of the mode, not this split.

      3. Stall probe. While the trace runs, one time-critical thread per CPU (-Cpu, a list,
         default CPU 0) spins reading the high-resolution clock and records every gap above
         -GapThresholdUs (default 2 us). Every interrupt, DPC or hypervisor intercept that lands on
         that core shows up as a gap. Per CPU: total stalled time (us and % of the window), a
         histogram (gap counts and summed us per bucket), p50 / p99 / p99.9 / max, and a timeline
         of the gaps of 1 ms or more in msi-bench-<phase>-stalls.csv.

      4. -Device <driver.sys>[,...] (needs admin): a 5 s pre-trace finds the CPU that takes most of
         each driver's ISRs, and the probe is pinned there as well. The picks and the CPU the main
         trace shows for the same driver are saved under cpuPick. The GPU's ISRs are logged as
         dxgkrnl.sys, not as the vendor driver.

      5. -Load <name> -PresentMon <path> (needs admin): waits for the load recipe in loads\<name>.json
         (process and start marker), pauses its load pause, then captures frame times with PresentMon
         for the recipe's capture time while the kernel trace and the probes run in the same window.
         -Seconds is not allowed with -Load: the recipe sets the window. The result adds load,
         presentMon, frames and rejected, and the bench throws after saving the JSON when the run is
         rejected (capped frame rate, lost frames, frames that stop short of the capture window or a
         video config that differs from the recipe).

    Results print to the console and are saved as msi-bench-<phase>.json in -OutDir (default: next
    to this script). Pair it with PresentMon for frame times. These are the tools behind the
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
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$msiBenchSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public class StallProbe {
    public const double TimelineMinUs = 1000.0;
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern bool SetThreadPriority(IntPtr thread, int priority);
    [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr thread, UIntPtr mask);

    readonly int cpu, seconds;
    readonly double thresholdUs;
    readonly List<double> gaps = new List<double>(1 << 16);
    readonly List<double> timelineOffsetsMs = new List<double>();
    readonly List<double> timelineGapsUs = new List<double>();
    Thread worker;
    long spanTicks;

    public StallProbe(int cpu, int seconds, double thresholdUs) {
        this.cpu = cpu; this.seconds = seconds; this.thresholdUs = thresholdUs;
    }
    public double[] TimelineOffsetsMs { get { return timelineOffsetsMs.ToArray(); } }
    public double[] TimelineGapsUs { get { return timelineGapsUs.ToArray(); } }

    public void Start() {
        worker = new Thread(() => {
            SetThreadAffinityMask(GetCurrentThread(), (UIntPtr)(1UL << cpu));
            SetThreadPriority(GetCurrentThread(), 15);
            double usPerTick = 1e6 / Stopwatch.Frequency;
            long start = Stopwatch.GetTimestamp(), end = start + seconds * Stopwatch.Frequency;
            long prev = start;
            while (prev < end) {
                long now = Stopwatch.GetTimestamp();
                double gap = (now - prev) * usPerTick;
                if (gap > thresholdUs) {
                    gaps.Add(gap);
                    if (gap >= TimelineMinUs) {
                        timelineOffsetsMs.Add((prev - start) * usPerTick / 1000.0);
                        timelineGapsUs.Add(gap);
                    }
                }
                prev = now;
            }
            spanTicks = prev - start;
        });
        worker.Start();
    }
    public double[] Stop(out double spanSeconds) {
        worker.Join();
        spanSeconds = (double)spanTicks / Stopwatch.Frequency;
        return gaps.ToArray();
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

function Assert-LoadArgument {
    param([string]$Load, [string]$PresentMon, [Parameter(Mandatory)][bool]$SecondsGiven)
    if ($Load -and -not $PresentMon) { throw '-Load needs -PresentMon <path to the pinned PresentMon exe>.' }
    if ($PresentMon -and -not $Load) { throw '-PresentMon needs -Load <name> (a file in bench\loads).' }
    if ($Load -and $SecondsGiven) { throw "-Seconds cannot be combined with -Load: the window is the recipe's capture time." }
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
    Assert-LoadArgument -Load $Load -PresentMon $PresentMon -SecondsGiven $PSBoundParameters.ContainsKey('Seconds')
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
    if ($recipe) {
        Write-Host "Load: $($recipe.title). Start it as bench\README.md says; this window waits."
        if ($recipe.consoleLine) { Write-Host "Console line: $($recipe.consoleLine)" }
        $loadProcess = Wait-LoadReady -Recipe $recipe
        $loadRecord = Get-LoadRecord -Recipe $recipe -Name $Load -Process $loadProcess
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
    $presentMonCsvName = "msi-bench-$Phase-presentmon.csv"
    if ($doTrace) { Start-KernelTrace -Etl $etl }
    $traceWatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($p in $probes) { $p.Start() }
        if ($recipe) {
            $capture = Invoke-PresentMonCapture -PresentMonPath $PresentMon -ProcessName $recipe.presentMonProcess -OutputFile (Join-Path $OutDir $presentMonCsvName) -Seconds $windowSeconds -ExpectedSha256 $recipe.presentMon.sha256
        }
        for ($i = 0; $i -lt $probes.Count; $i++) {
            $span = 0.0
            $gapSets[$i] = $probes[$i].Stop([ref]$span)
            $spans[$i] = $span
        }
    } finally {
        if ($doTrace) { Stop-KernelTrace }
        $traceSeconds = $traceWatch.Elapsed.TotalSeconds
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
        $drivers = foreach ($s in $data.Stats.Values) {
            $isrSorted = [double[]]($s.IsrUs | Sort-Object)
            $dpcSorted = [double[]]($s.DpcUs | Sort-Object)
            [pscustomobject]@{
                driver     = $s.Module
                isrPlain   = $s.IsrLine
                isrMessage = $s.IsrMsi
                isrPerCpu  = @($s.IsrPerCpu.GetEnumerator() | Sort-Object Key | ForEach-Object { [pscustomobject]@{ cpu = $_.Key; isr = $_.Value } })
                vectors    = (($s.Vectors.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key):$($_.Value)" }) -join " ")
                isrMaxUs   = if ($isrSorted.Count) { [math]::Round($isrSorted[-1], 1) } else { 0 }
                isrMeanUs  = if ($isrSorted.Count) { [math]::Round(($s.IsrUs | Measure-Object -Average).Average, 2) } else { 0 }
                dpcCount   = $s.DpcCount
                dpcMaxUs   = if ($dpcSorted.Count) { [math]::Round($dpcSorted[-1], 1) } else { 0 }
                dpcP99Us   = Get-Percentile $dpcSorted 0.99 1
                dpcMeanUs  = if ($dpcSorted.Count) { [math]::Round(($s.DpcUs | Measure-Object -Average).Average, 2) } else { 0 }
            }
        }
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
        $rejected = Get-GameRejection -Stats $stats -Capture $capture -Video $loadRecord.videoConfig -Recipe $recipe
        $files += $presentMonCsvName
        $result.load = $loadRecord
        $result.presentMon = [pscustomobject]@{ sha256 = $capture.presentMonSha256; overflowedPresents = $capture.overflowedPresents }
        $result.frames = $stats
        $result.rejected = $rejected
        Write-Host ("Frames: {0} at {1} fps avg, p50 {2} ms, 1% low {3} ms, {4} lost to present buffer overflow" -f $stats.frames, $stats.avgFps, $stats.p50Ms, $stats.low1PctMs, $capture.overflowedPresents)
    }
    $result.files = $files
    $result.metadata = $metadata
    Write-BenchResult -Object ([pscustomobject]$result) -Path (Join-Path $OutDir "msi-bench-$Phase.json")
    Write-Host "Saved msi-bench-$Phase.json"
    if ($rejected) { throw "Run rejected: $rejected. The result file is kept." }
}
