function Get-BatteryDiagnostics {
    param(
        [array]$LoadSamples = @(),
        [bool]$IsLaptop = $true
    )

    $batteries = @()
    $xmlPath = Join-Path $env:TEMP ("li_bat_{0}.xml" -f $PID)

    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $pInfo.Arguments = "/batteryreport /xml /output `"$xmlPath`""
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pInfo)
        $proc.WaitForExit(5000) | Out-Null

        if (Test-Path -LiteralPath $xmlPath) {
            [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
            $xmlBats = @($xml.BatteryReport.Batteries.Battery)
            foreach ($xb in $xmlBats) {
                if ($null -eq $xb) { continue }
                $design = if ($xb.DesignCapacity -match '^\d+$') { [int64]$xb.DesignCapacity } else { 0L }
                $full   = if ($xb.FullChargeCapacity -match '^\d+$') { [int64]$xb.FullChargeCapacity } else { 0L }
                $cycles = if ($xb.CycleCount -match '^\d+$') { [int]$xb.CycleCount } else { $null }

                $healthPct = if ($design -gt 0 -and $full -gt 0) {
                    [Math]::Round([Math]::Min(100.0, ($full / [double]$design) * 100.0), 1)
                } else { $null }
                $wearPct = if ($null -ne $healthPct) { [Math]::Round(100.0 - $healthPct, 1) } else { $null }

                $batteries += [PSCustomObject]@{
                    Id                 = [string]$xb.Id
                    Manufacturer       = [string]$xb.Manufacturer
                    SerialNumber       = [string]$xb.SerialNumber
                    Chemistry          = [string]$xb.Chemistry
                    DesignCapacityMWh  = $design
                    FullChargeMWh      = $full
                    CycleCount         = $cycles
                    HealthPercent      = $healthPct
                    WearPercent        = $wearPct
                }
            }
        }
    } catch {
        # Fallback to WMI below
    } finally {
        if (Test-Path -LiteralPath $xmlPath) {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }

    # WMI fallback or enrichment for CycleCount / StaticData / Live Status
    $wmiStatic = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStaticData')
    $wmiFull   = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity')
    $wmiCycles = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryCycleCount')
    $wmiStatus = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStatus')
    $win32Bat  = @(Invoke-SafeCim -ClassName 'Win32_Battery')

    if ($batteries.Count -eq 0 -and ($wmiStatic.Count -gt 0 -or $win32Bat.Count -gt 0)) {
        $count = [Math]::Max($wmiStatic.Count, $win32Bat.Count)
        for ($i = 0; $i -lt $count; $i++) {
            $st = if ($i -lt $wmiStatic.Count) { $wmiStatic[$i] } else { $null }
            $fc = if ($i -lt $wmiFull.Count) { $wmiFull[$i] } else { $null }
            $cc = if ($i -lt $wmiCycles.Count) { $wmiCycles[$i] } else { $null }
            $wb = if ($i -lt $win32Bat.Count) { $win32Bat[$i] } else { $null }

            $design = if ($st -and $st.DesignedCapacity -gt 0) { [int64]$st.DesignedCapacity } elseif ($wb -and $wb.DesignCapacity -gt 0) { [int64]$wb.DesignCapacity } else { 0L }
            $full   = if ($fc -and $fc.FullChargedCapacity -gt 0) { [int64]$fc.FullChargedCapacity } elseif ($wb -and $wb.FullChargeCapacity -gt 0) { [int64]$wb.FullChargeCapacity } else { 0L }
            $cycles = if ($cc -and $null -ne $cc.CycleCount) { [int]$cc.CycleCount } else { $null }

            $healthPct = if ($design -gt 0 -and $full -gt 0) {
                [Math]::Round([Math]::Min(100.0, ($full / [double]$design) * 100.0), 1)
            } else { $null }
            $wearPct = if ($null -ne $healthPct) { [Math]::Round(100.0 - $healthPct, 1) } else { $null }

            $batteries += [PSCustomObject]@{
                Id                 = if ($wb) { [string]$wb.DeviceID } else { "BAT$i" }
                Manufacturer       = if ($st) { [string]$st.ManufactureName } else { '' }
                SerialNumber       = if ($st) { [string]$st.SerialNumber } else { '' }
                Chemistry          = if ($st) { [string]$st.Chemistry } else { '' }
                DesignCapacityMWh  = $design
                FullChargeMWh      = $full
                CycleCount         = $cycles
                HealthPercent      = $healthPct
                WearPercent        = $wearPct
            }
        }
    } elseif ($batteries.Count -gt 0 -and $wmiCycles.Count -gt 0) {
        for ($i = 0; $i -lt $batteries.Count; $i++) {
            if (($null -eq $batteries[$i].CycleCount -or $batteries[$i].CycleCount -eq 0) -and $i -lt $wmiCycles.Count -and $wmiCycles[$i].CycleCount -gt 0) {
                $batteries[$i].CycleCount = [int]$wmiCycles[$i].CycleCount
            }
        }
    }

    # Live state
    $wb0 = $win32Bat | Select-Object -First 1
    $ws0 = $wmiStatus | Select-Object -First 1

    $chargePct = if ($wb0) { [int]$wb0.EstimatedChargeRemaining } else { $null }
    $acOnline = if ($ws0) { [bool]$ws0.PowerOnline } elseif ($wb0) { ($wb0.BatteryStatus -in @(2, 6, 7, 8, 9)) } else { $null }
    $charging = if ($ws0) { [bool]$ws0.Charging } else { $false }
    $discharging = if ($ws0) { [bool]$ws0.Discharging } else { $false }
    $voltageMv = if ($ws0 -and $ws0.Voltage -gt 0) { [int]$ws0.Voltage } elseif ($wb0 -and $wb0.DesignVoltage -gt 0) { [int]$wb0.DesignVoltage } else { $null }
    $chargeRateMw = if ($ws0 -and $ws0.Charging) { [int]$ws0.ChargeRate } elseif ($ws0 -and $ws0.Discharging) { -[int]$ws0.DischargeRate } else { 0 }

    # Analyze load stability from CPU stress samples
    $acFlickerDetected = $false
    $voltageDroopDetected = $false
    $voltageDroopPct = 0.0
    if ($LoadSamples -and $LoadSamples.Count -ge 2) {
        $onlineVals = @($LoadSamples | Where-Object { $null -ne $_.PowerOnline } | Select-Object -ExpandProperty PowerOnline)
        if ($onlineVals.Count -ge 2) {
            $firstOn = $onlineVals[0]
            foreach ($ov in $onlineVals) {
                if ($ov -ne $firstOn) { $acFlickerDetected = $true; break }
            }
        }
        $volts = @($LoadSamples | Where-Object { $null -ne $_.VoltageMv -and $_.VoltageMv -gt 0 } | Select-Object -ExpandProperty VoltageMv)
        if ($volts.Count -ge 2) {
            $maxV = ($volts | Measure-Object -Maximum).Maximum
            $minV = ($volts | Measure-Object -Minimum).Minimum
            if ($maxV -gt 0) {
                $voltageDroopPct = [Math]::Round((($maxV - $minV) / [double]$maxV) * 100.0, 1)
                if ($voltageDroopPct -gt 12.0) { $voltageDroopDetected = $true }
            }
        }
    }

    # Combined health
    $validHealths = @($batteries | Where-Object { $null -ne $_.HealthPercent } | Select-Object -ExpandProperty HealthPercent)
    $overallHealth = if ($validHealths.Count -gt 0) {
        [Math]::Round(($validHealths | Measure-Object -Average).Average, 1)
    } else { $null }
    $maxCycles = $null
    $cycleVals = @($batteries | Where-Object { $null -ne $_.CycleCount } | Select-Object -ExpandProperty CycleCount)
    if ($cycleVals.Count -gt 0) { $maxCycles = ($cycleVals | Measure-Object -Maximum).Maximum }

    $condition = if ($batteries.Count -eq 0) {
        if ($IsLaptop) { 'Missing' } else { 'N/A (Desktop)' }
    } elseif ($null -eq $overallHealth) {
        'Unknown'
    } elseif ($overallHealth -ge 85) {
        'Excellent'
    } elseif ($overallHealth -ge 75) {
        'Good'
    } elseif ($overallHealth -ge 60) {
        'Fair'
    } else {
        'Poor'
    }

    $batStatus = if ($batteries.Count -eq 0) {
        if ($IsLaptop) { 'FAIL' } else { 'UNAVAILABLE' }
    } elseif ($acFlickerDetected -or $voltageDroopDetected -or ($null -ne $overallHealth -and $overallHealth -lt 75)) {
        'WARN'
    } elseif ($null -eq $overallHealth) {
        'UNAVAILABLE'
    } else {
        'PASS'
    }

    return [PSCustomObject]@{
        Status               = $batStatus
        BatteryCount         = $batteries.Count
        Condition            = $condition
        OverallHealthPercent = $overallHealth
        MaxCycleCount        = $maxCycles
        CurrentChargePercent = $chargePct
        AcOnline             = $acOnline
        Charging             = $charging
        Discharging          = $discharging
        VoltageMv            = $voltageMv
        ChargeRateMw         = $chargeRateMw
        AcFlickerDetected    = $acFlickerDetected
        VoltageDroopDetected = $voltageDroopDetected
        VoltageDroopPct      = $voltageDroopPct
        Batteries            = @($batteries)
    }
}

function Get-BatteryCheckpointPath {
    return (Join-Path $env:TEMP 'li_bat_drain_latest.json')
}

function Clear-BatteryCheckpoint {
    $p = Get-BatteryCheckpointPath
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

function Get-UnfinishedBatteryCheckpoint {
    $p = Get-BatteryCheckpointPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        if ($obj -and $obj.State -eq 'Running' -and [int]$obj.Pid -ne $PID) {
            return $obj
        }
    } catch {}
    return $null
}

function Set-BatteryTestKeepAwake {
    param([bool]$Enable = $true)
    try {
        if (-not ('LaptopInspectNativePower' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LaptopInspectNativePower {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
'@ -ErrorAction Stop
        }
        $flags = if ($Enable) { [uint32]'0x80000003' } else { [uint32]'0x80000000' }
        [void][LaptopInspectNativePower]::SetThreadExecutionState($flags)
    } catch {}
}

function Get-BatteryDischargeSample {
    param([double]$ElapsedSec = 0.0)

    $wb = Invoke-SafeCim -ClassName 'Win32_Battery' | Select-Object -First 1
    $bs = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStatus' | Select-Object -First 1

    $pct = if ($wb -and $null -ne $wb.EstimatedChargeRemaining) { [int]$wb.EstimatedChargeRemaining } else { $null }
    $online = if ($bs) { [bool]$bs.PowerOnline } elseif ($wb) { ($wb.BatteryStatus -in @(2, 6, 7, 8, 9)) } else { $null }
    $remMwh = if ($bs -and $null -ne $bs.RemainingCapacity -and $bs.RemainingCapacity -gt 0) { [int64]$bs.RemainingCapacity } else { $null }
    $disMw = if ($bs -and $bs.Discharging -and $bs.DischargeRate -gt 0) { [int]$bs.DischargeRate } else { 0 }
    $voltMv = if ($bs -and $bs.Voltage -gt 0) { [int]$bs.Voltage } elseif ($wb -and $wb.DesignVoltage -gt 0) { [int]$wb.DesignVoltage } else { $null }

    $tempC = $null
    if (Get-Command -Name 'Get-CpuTempCelsius' -ErrorAction SilentlyContinue) {
        $tempC = Get-CpuTempCelsius
    }

    return [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString('HH:mm:ss')
        ElapsedSec   = [Math]::Round($ElapsedSec, 1)
        ChargePct    = $pct
        PowerOnline  = $online
        RemainingMWh = $remMwh
        DischargeMw  = $disMw
        VoltageMv    = $voltMv
        TempC        = $tempC
    }
}

function Measure-BatteryDrainSummary {
    param(
        [array]$Samples = @(),
        [double]$TotalCapacityMWh = 0,
        [string]$LoadMode = 'everyday',
        [string]$StopReason = 'Completed'
    )

    $arr = @($Samples | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) {
        return [PSCustomObject]@{
            Status                        = 'UNAVAILABLE'
            StopReason                    = $StopReason
            LoadMode                      = $LoadMode
            SampleCount                   = 0
            ElapsedSeconds                = 0
            ElapsedMinutes                = 0
            StartPct                      = $null
            EndPct                        = $null
            DropPct                       = 0
            StartMWh                      = $null
            EndMWh                        = $null
            EnergyUsedMWh                 = 0
            AvgDischargeWatts             = $null
            PeakDischargeWatts            = $null
            StartVoltageMv                = $null
            MinVoltageMv                  = $null
            VoltageSagPct                 = 0.0
            SuddenDropDetected            = $false
            SuddenDropDetail              = ''
            EstimatedRuntimeFrom100Minutes = $null
        }
    }

    $first = $arr[0]
    $last  = $arr[$arr.Count - 1]
    $elapsedSec = [Math]::Max(0.0, ([double]$last.ElapsedSec - [double]$first.ElapsedSec))
    $elapsedMin = [Math]::Round($elapsedSec / 60.0, 2)

    $startPct = $first.ChargePct
    $endPct   = $last.ChargePct
    $dropPct  = if ($null -ne $startPct -and $null -ne $endPct) { [Math]::Max(0, [int]$startPct - [int]$endPct) } else { 0 }

    $startMwh = $first.RemainingMWh
    $endMwh   = $last.RemainingMWh
    $usedMwh  = if ($null -ne $startMwh -and $null -ne $endMwh) { [Math]::Max(0, [int64]$startMwh - [int64]$endMwh) } else { 0 }

    $posRates = @($arr | Where-Object { $null -ne $_.DischargeMw -and $_.DischargeMw -gt 0 } | Select-Object -ExpandProperty DischargeMw)
    $avgWatts = $null
    $peakWatts = $null
    if ($posRates.Count -gt 0) {
        $avgMw = ($posRates | Measure-Object -Average).Average
        $maxMw = ($posRates | Measure-Object -Maximum).Maximum
        $avgWatts  = [Math]::Round($avgMw / 1000.0, 2)
        $peakWatts = [Math]::Round($maxMw / 1000.0, 2)
    } elseif ($usedMwh -gt 0 -and $elapsedSec -ge 10) {
        $avgWatts = [Math]::Round(($usedMwh / ($elapsedSec / 3600.0)) / 1000.0, 2)
        $peakWatts = $avgWatts
    }

    $volts = @($arr | Where-Object { $null -ne $_.VoltageMv -and $_.VoltageMv -gt 0 } | Select-Object -ExpandProperty VoltageMv)
    $startVolt = $first.VoltageMv
    $minVolt = if ($volts.Count -gt 0) { ($volts | Measure-Object -Minimum).Minimum } else { $null }
    $maxVolt = if ($volts.Count -gt 0) { ($volts | Measure-Object -Maximum).Maximum } else { $null }
    $sagPct = 0.0
    if ($null -ne $maxVolt -and $null -ne $minVolt -and $maxVolt -gt 0) {
        $sagPct = [Math]::Round((($maxVolt - $minVolt) / [double]$maxVolt) * 100.0, 1)
    }

    $suddenDrop = $false
    $suddenDetail = ''
    for ($i = 1; $i -lt $arr.Count; $i++) {
        $p = $arr[$i - 1]
        $c = $arr[$i]
        if ($null -ne $p.ChargePct -and $null -ne $c.ChargePct) {
            $dt = [double]$c.ElapsedSec - [double]$p.ElapsedSec
            $dp = [int]$p.ChargePct - [int]$c.ChargePct
            if ($dt -le 30.0 -and $dp -ge 5) {
                $suddenDrop = $true
                $suddenDetail = ("{0}% -> {1}% in {2}s" -f $p.ChargePct, $c.ChargePct, [int][Math]::Round($dt))
                break
            }
        }
    }

    $estFullMin = $null
    if ($TotalCapacityMWh -gt 0 -and $null -ne $avgWatts -and $avgWatts -gt 0.5) {
        $estFullMin = [int][Math]::Round(($TotalCapacityMWh / ($avgWatts * 1000.0)) * 60.0)
    } elseif ($dropPct -ge 1 -and $elapsedMin -gt 0) {
        $estFullMin = [int][Math]::Round(($elapsedMin / [double]$dropPct) * 100.0)
    }

    $status = if ($suddenDrop) {
        'FAIL'
    } elseif ($sagPct -gt 15.0 -or ($LoadMode -in @('everyday', 'light') -and $null -ne $estFullMin -and $estFullMin -lt 90)) {
        'WARN'
    } elseif ($StopReason -match '^Aborted') {
        'WARN'
    } else {
        'PASS'
    }

    return [PSCustomObject]@{
        Status                         = $status
        StopReason                     = $StopReason
        LoadMode                       = $LoadMode
        SampleCount                    = $arr.Count
        ElapsedSeconds                 = [int][Math]::Round($elapsedSec)
        ElapsedMinutes                 = $elapsedMin
        StartPct                       = $startPct
        EndPct                         = $endPct
        DropPct                        = $dropPct
        StartMWh                       = $startMwh
        EndMWh                         = $endMwh
        EnergyUsedMWh                  = $usedMwh
        AvgDischargeWatts              = $avgWatts
        PeakDischargeWatts             = $peakWatts
        StartVoltageMv                 = $startVolt
        MinVoltageMv                   = $minVolt
        VoltageSagPct                  = $sagPct
        SuddenDropDetected             = $suddenDrop
        SuddenDropDetail               = $suddenDetail
        EstimatedRuntimeFrom100Minutes = $estFullMin
    }
}

function Invoke-EverydayTickWorkload {
    param(
        [byte[]]$WorkBuffer,
        [int]$TickIndex = 0,
        [string]$IoTempPath = ''
    )

    # 1. Touch 32MB memory working set across 4KB pages
    if ($WorkBuffer -and $WorkBuffer.Length -ge 4096) {
        $val = [byte](($TickIndex * 17) -band 0xFF)
        for ($off = 0; $off -lt $WorkBuffer.Length; $off += 4096) {
            $WorkBuffer[$off] = $val
        }
    }

    # 2. ~180ms burst of SHA-256 + floating point + JSON work (simulates browser/office bursts)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $b = [System.Text.Encoding]::ASCII.GetBytes("EverydayBurst-$TickIndex")
        for ($i = 0; $i -lt 450; $i++) { $b = $sha.ComputeHash($b) }
        $acc = 0.0
        for ($k = 1; $k -le 4000; $k++) {
            $acc += [Math]::Sqrt($k * 1.13) * [Math]::Sin($k * 0.021)
        }
        $obj = @{ idx = $TickIndex; sum = [Math]::Round($acc, 3); items = @(1..30) } | ConvertTo-Json -Compress
        $null = $obj | ConvertFrom-Json
    } finally {
        $sha.Dispose()
    }

    # 3. Every 4th tick (~20s), write & read 4MB temp file to simulate browser/app disk cache I/O
    if (-not [string]::IsNullOrWhiteSpace($IoTempPath) -and (($TickIndex % 4) -eq 0)) {
        try {
            $ioBlock = New-Object byte[] (4MB)
            $ioBlock[0] = [byte]($TickIndex -band 0xFF)
            [System.IO.File]::WriteAllBytes($IoTempPath, $ioBlock)
            $null = [System.IO.File]::ReadAllBytes($IoTempPath)
        } catch {}
    }
}

function Invoke-TimedBatteryDrainTest {
    param(
        [int]$Minutes = 15,
        [int]$CutoffPct = 10,
        [ValidateSet('everyday', 'light', 'heavy')][string]$LoadMode = 'everyday',
        [int]$WaitForUnplugSeconds = 60,
        [hashtable]$ProgressState = $null,
        [switch]$ConsoleLive,
        [double]$TotalCapacityMWh = 0
    )

    if ($Minutes -lt -1) { $Minutes = -1 }
    if ($Minutes -eq 0) { $Minutes = 15 }
    if ($Minutes -gt 240) { $Minutes = 240 }
    if ($CutoffPct -lt 5) { $CutoffPct = 5 }
    if ($CutoffPct -gt 50) { $CutoffPct = 50 }

    $bats = @(Invoke-SafeCim -ClassName 'Win32_Battery')
    if ($bats.Count -eq 0) {
        $emptySum = Measure-BatteryDrainSummary -Samples @() -LoadMode $LoadMode -StopReason 'No battery detected'
        if ($ProgressState) {
            $ProgressState.Running = $false
            $ProgressState.State = 'Unavailable'
            $ProgressState.Error = 'No battery detected on this system.'
            $ProgressState.Summary = $emptySum
        }
        return $emptySum
    }

    if ($TotalCapacityMWh -le 0) {
        $wmiFull = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity' | Select-Object -First 1
        if ($wmiFull -and $wmiFull.FullChargedCapacity -gt 0) {
            $TotalCapacityMWh = [double]$wmiFull.FullChargedCapacity
        }
    }

    $chkPath = Get-BatteryCheckpointPath
    $ioTempPath = Join-Path $env:TEMP ("li_everyday_io_{0}.tmp" -f $PID)
    $workBuf = $null
    $heavyPool = $null
    $heavyHandles = @()
    $heavyCtrl = [hashtable]::Synchronized(@{ Stop = $false })

    $samples = New-Object System.Collections.ArrayList
    $stopReason = 'Completed'
    $startedAtStr = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    if ($ProgressState) {
        $ProgressState.Running = $true
        $ProgressState.State = 'WaitingForUnplug'
        $ProgressState.WaitingForUnplug = $true
        $ProgressState.LoadMode = $LoadMode
        $ProgressState.TargetMinutes = $Minutes
        $ProgressState.CutoffPct = $CutoffPct
        $ProgressState.ElapsedSeconds = 0
        $ProgressState.RemainingSeconds = if ($Minutes -gt 0) { $Minutes * 60 } else { -1 }
        $ProgressState.CancelRequested = $false
        $ProgressState.Error = ''
        $ProgressState.Summary = $null
        $ProgressState.Samples.Clear()
    }

    try {
        Set-BatteryTestKeepAwake -Enable $true

        # Step 1: Wait until charger is unplugged
        $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
        $initSample = Get-BatteryDischargeSample -ElapsedSec 0
        while ($initSample.PowerOnline -eq $true) {
            if ($ProgressState -and $ProgressState.CancelRequested) {
                $stopReason = 'Canceled while waiting for charger unplug'
                break
            }
            if ($ConsoleLive) {
                try {
                    if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                        $rk = [Console]::ReadKey($true)
                        if ($rk.Key -eq [ConsoleKey]::Q -or $rk.Key -eq [ConsoleKey]::Escape) {
                            $stopReason = 'Canceled by user'
                            break
                        }
                    }
                } catch {}
                $remWait = [Math]::Max(0, $WaitForUnplugSeconds - [int]$waitSw.Elapsed.TotalSeconds)
                Write-Host ("`r  [WAIT] Charger is plugged in ({0}%). Unplug AC adapter to start timer ({1}s, Q=Cancel)... " -f $initSample.ChargePct, $remWait) -NoNewline -ForegroundColor Yellow
            }
            if ($waitSw.Elapsed.TotalSeconds -ge $WaitForUnplugSeconds) {
                $stopReason = 'Aborted: Charger remained plugged in'
                break
            }
            Start-Sleep -Milliseconds 1000
            $initSample = Get-BatteryDischargeSample -ElapsedSec 0
        }
        if ($ConsoleLive -and $waitSw.Elapsed.TotalSeconds -gt 0.2) { Write-Host '' }

        if ($stopReason -ne 'Completed') {
            $abortedSum = Measure-BatteryDrainSummary -Samples @($initSample) -TotalCapacityMWh $TotalCapacityMWh -LoadMode $LoadMode -StopReason $stopReason
            if ($ProgressState) {
                $ProgressState.Running = $false
                $ProgressState.WaitingForUnplug = $false
                $ProgressState.State = 'Aborted'
                $ProgressState.Summary = $abortedSum
            }
            return $abortedSum
        }

        if ($ProgressState) {
            $ProgressState.WaitingForUnplug = $false
            $ProgressState.State = 'Running'
        }

        # Step 2: Start selected workload
        if ($LoadMode -eq 'everyday') {
            $workBuf = New-Object byte[] (32MB)
        } elseif ($LoadMode -eq 'heavy') {
            $threads = [Math]::Max(1, [Environment]::ProcessorCount)
            $heavyPool = [RunspaceFactory]::CreateRunspacePool(1, $threads)
            $heavyPool.Open()
            $heavyWorker = {
                param($Ctrl)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $seed = [System.Text.Encoding]::ASCII.GetBytes('HeavyBatteryDrain')
                try {
                    while (-not $Ctrl.Stop) {
                        $b = $seed
                        for ($i = 0; $i -lt 250; $i++) { $b = $sha.ComputeHash($b) }
                        Start-Sleep -Milliseconds 80
                    }
                } finally {
                    $sha.Dispose()
                }
            }
            for ($t = 0; $t -lt $threads; $t++) {
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $heavyPool
                [void]$ps.AddScript($heavyWorker).AddArgument($heavyCtrl)
                $heavyHandles += [PSCustomObject]@{ Ps = $ps; Async = $ps.BeginInvoke() }
            }
        }

        # Step 3: Timed sampling loop
        $drainSw = [System.Diagnostics.Stopwatch]::StartNew()
        $targetSec = if ($Minutes -gt 0) { $Minutes * 60.0 } else { [double]::MaxValue }
        $nextSampleSec = 0.0
        $nextCheckpointSec = 15.0
        $tickIdx = 0

        while ($true) {
            $elapsed = $drainSw.Elapsed.TotalSeconds
            if ($ProgressState -and $ProgressState.CancelRequested) {
                $stopReason = 'Stopped Early by User'
                break
            }
            if ($ConsoleLive) {
                try {
                    if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                        $rk = [Console]::ReadKey($true)
                        if ($rk.Key -eq [ConsoleKey]::Q -or $rk.Key -eq [ConsoleKey]::Escape) {
                            $stopReason = 'Stopped Early by User'
                            break
                        }
                    }
                } catch {}
            }

            if ($elapsed -ge $nextSampleSec) {
                $samp = Get-BatteryDischargeSample -ElapsedSec $elapsed
                [void]$samples.Add($samp)
                if ($ProgressState) {
                    $ProgressState.CurrentSample = $samp
                    [void]$ProgressState.Samples.Add($samp)
                }

                if ($samp.PowerOnline -eq $true -and $samples.Count -gt 1) {
                    $stopReason = 'Aborted: Charger Reconnected'
                    break
                }
                if ($null -ne $samp.ChargePct -and $samp.ChargePct -le $CutoffPct) {
                    $stopReason = ("Completed: Safety Cutoff Reached ({0}%)" -f $CutoffPct)
                    break
                }
                $nextSampleSec = $elapsed + 5.0
            }

            $remSec = if ($Minutes -gt 0) { [Math]::Max(0, [int][Math]::Ceiling($targetSec - $elapsed)) } else { -1 }
            if ($ProgressState) {
                $ProgressState.ElapsedSeconds = [int][Math]::Floor($elapsed)
                $ProgressState.RemainingSeconds = $remSec
                if ($samples.Count -ge 2) {
                    $ProgressState.Summary = Measure-BatteryDrainSummary -Samples $samples.ToArray() -TotalCapacityMWh $TotalCapacityMWh -LoadMode $LoadMode -StopReason 'Running'
                }
            }

            if ($ConsoleLive) {
                $curS = $samples[$samples.Count - 1]
                $wNow = if ($curS.DischargeMw -gt 0) { [Math]::Round($curS.DischargeMw / 1000.0, 1) } else { 0.0 }
                $vNow = if ($curS.VoltageMv) { "$($curS.VoltageMv)mV" } else { 'N/A' }
                $timerTxt = if ($Minutes -gt 0) {
                    $tsRem = [TimeSpan]::FromSeconds($remSec)
                    "Left: $($tsRem.ToString('mm\:ss'))"
                } else {
                    $tsEl = [TimeSpan]::FromSeconds([int]$elapsed)
                    "Elapsed: $($tsEl.ToString('hh\:mm\:ss'))"
                }
                Write-Host ("`r  [{0}] {1} | Bat: {2}% | Draw: {3}W | {4} | [Q]=Stop   " -f $LoadMode.ToUpperInvariant(), $timerTxt, $curS.ChargePct, $wNow, $vNow) -NoNewline -ForegroundColor Cyan
            }

            if ($Minutes -gt 0 -and $elapsed -ge $targetSec) {
                $stopReason = ("Completed ({0} min timer)" -f $Minutes)
                break
            }

            if ($elapsed -ge $nextCheckpointSec -and $samples.Count -gt 0) {
                try {
                    $lastS = $samples[$samples.Count - 1]
                    $chkObj = @{
                        Pid            = $PID
                        State          = 'Running'
                        StartedAt      = $startedAtStr
                        LastUpdated    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        LoadMode       = $LoadMode
                        ElapsedSeconds = [int][Math]::Floor($elapsed)
                        LastChargePct  = $lastS.ChargePct
                        LastVoltageMv  = $lastS.VoltageMv
                        Samples        = @($samples.ToArray())
                    } | ConvertTo-Json -Depth 6 -Compress
                    [System.IO.File]::WriteAllText($chkPath, $chkObj, [System.Text.Encoding]::ASCII)
                } catch {}
                $nextCheckpointSec = $elapsed + 15.0
            }

            $tickIdx++
            if ($LoadMode -eq 'everyday') {
                Invoke-EverydayTickWorkload -WorkBuffer $workBuf -TickIndex $tickIdx -IoTempPath $ioTempPath
                Start-Sleep -Milliseconds 900
            } else {
                Start-Sleep -Milliseconds 1000
            }
        }
        if ($ConsoleLive) { Write-Host '' }

        $finalSummary = Measure-BatteryDrainSummary -Samples $samples.ToArray() -TotalCapacityMWh $TotalCapacityMWh -LoadMode $LoadMode -StopReason $stopReason
        if ($ProgressState) {
            $ProgressState.Running = $false
            $ProgressState.State = if ($stopReason -match '^Aborted|^Canceled|^Stopped') { 'Stopped' } else { 'Completed' }
            $ProgressState.Summary = $finalSummary
        }
        Clear-BatteryCheckpoint
        return $finalSummary
    } finally {
        $heavyCtrl.Stop = $true
        foreach ($hh in $heavyHandles) {
            try { [void]$hh.Async.AsyncWaitHandle.WaitOne(2000); $hh.Ps.EndInvoke($hh.Async) | Out-Null } catch {}
            try { $hh.Ps.Dispose() } catch {}
        }
        if ($heavyPool) {
            try { $heavyPool.Close(); $heavyPool.Dispose() } catch {}
        }
        $workBuf = $null
        if (Test-Path -LiteralPath $ioTempPath) {
            Remove-Item -LiteralPath $ioTempPath -Force -ErrorAction SilentlyContinue
        }
        Set-BatteryTestKeepAwake -Enable $false
        [GC]::Collect()
    }
}
