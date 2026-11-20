function Get-SystemIdentity {
    $cs   = Invoke-SafeCim -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    $csp  = Invoke-SafeCim -ClassName 'Win32_ComputerSystemProduct' | Select-Object -First 1
    $bios = Invoke-SafeCim -ClassName 'Win32_BIOS' | Select-Object -First 1
    $bb   = Invoke-SafeCim -ClassName 'Win32_BaseBoard' | Select-Object -First 1
    $enc  = Invoke-SafeCim -ClassName 'Win32_SystemEnclosure' | Select-Object -First 1
    $os   = Invoke-SafeCim -ClassName 'Win32_OperatingSystem' | Select-Object -First 1

    $chassisTypes = @()
    if ($enc -and $enc.ChassisTypes) { $chassisTypes = @($enc.ChassisTypes | ForEach-Object { [int]$_ }) }
    $laptopCodes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = $false
    foreach ($c in $chassisTypes) {
        if ($laptopCodes -contains $c) { $isLaptop = $true; break }
    }
    if (-not $isLaptop -and $cs -and $cs.PCSystemType -eq 2) { $isLaptop = $true }

    $chassisLabel = if ($isLaptop) { 'Laptop / Portable' } elseif ($chassisTypes.Count -gt 0) { "Chassis ($($chassisTypes -join ','))" } else { 'Unknown' }

    $biosDate = ''
    if ($bios -and $bios.ReleaseDate) {
        try { $biosDate = ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } catch { $biosDate = [string]$bios.ReleaseDate }
    }
    $osInstall = ''
    $uptimeHours = $null
    if ($os) {
        if ($os.InstallDate) {
            try { $osInstall = ([datetime]$os.InstallDate).ToString('yyyy-MM-dd') } catch { $osInstall = [string]$os.InstallDate }
        }
        if ($os.LastBootUpTime) {
            try { $uptimeHours = [Math]::Round(((Get-Date) - ([datetime]$os.LastBootUpTime)).TotalHours, 1) } catch {}
        }
    }

    return [PSCustomObject]@{
        Manufacturer    = if ($cs) { [string]$cs.Manufacturer } else { 'Unknown' }
        Model           = if ($cs) { [string]$cs.Model } else { 'Unknown' }
        SystemSku       = if ($cs) { [string]$cs.SystemSKUNumber } else { '' }
        ProductVersion  = if ($csp) { [string]$csp.Version } else { '' }
        Uuid            = if ($csp) { [string]$csp.UUID } else { '' }
        SerialNumber    = if ($bios -and -not [string]::IsNullOrWhiteSpace($bios.SerialNumber)) { [string]$bios.SerialNumber } elseif ($csp) { [string]$csp.IdentifyingNumber } else { 'Unknown' }
        BiosVendor      = if ($bios) { [string]$bios.Manufacturer } else { '' }
        BiosVersion     = if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' }
        BiosDate        = $biosDate
        BaseBoard       = if ($bb) { ("{0} {1}" -f $bb.Manufacturer, $bb.Product).Trim() } else { '' }
        ChassisType     = $chassisLabel
        IsLaptop        = $isLaptop
        OsCaption       = if ($os) { [string]$os.Caption } else { 'Windows' }
        OsVersion       = if ($os) { [string]$os.Version } else { '' }
        OsBuild         = if ($os) { [string]$os.BuildNumber } else { '' }
        OsArchitecture  = if ($os) { [string]$os.OSArchitecture } else { '' }
        OsInstallDate   = $osInstall
        UptimeHours     = $uptimeHours
        ComputerName    = $env:COMPUTERNAME
    }
}

function Get-CpuTempCelsius {
    try {
        $zones = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature'
        $valid = @()
        foreach ($z in $zones) {
            if ($z.CurrentTemperature) {
                $c = ($z.CurrentTemperature / 10.0) - 273.15
                if ($c -ge 20.0 -and $c -le 120.0) { $valid += $c }
            }
        }
        if ($valid.Count -gt 0) {
            return [Math]::Round(($valid | Measure-Object -Maximum).Maximum, 1)
        }
    } catch {}

    try {
        $perfZones = Invoke-SafeCim -ClassName 'Win32_PerfFormattedData_Counters_ThermalZoneInformation'
        $valid2 = @()
        foreach ($pz in $perfZones) {
            if ($pz.Temperature -and $pz.Temperature -gt 200) {
                $c = $pz.Temperature - 273.15
                if ($c -ge 20.0 -and $c -le 120.0) { $valid2 += $c }
            }
        }
        if ($valid2.Count -gt 0) {
            return [Math]::Round(($valid2 | Measure-Object -Maximum).Maximum, 1)
        }
    } catch {}

    return $null
}

function Get-NvidiaTempQuick {
    param([string]$NvidiaSmiPath)
    if ([string]::IsNullOrWhiteSpace($NvidiaSmiPath) -or -not (Test-Path -LiteralPath $NvidiaSmiPath)) {
        return $null
    }
    try {
        $out = & $NvidiaSmiPath --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null
        if ($out -and $out[0] -match '^\s*(\d+(\.\d+)?)') {
            return [double]$matches[1]
        }
    } catch {}
    return $null
}

function Get-BatteryLiveSample {
    $online = $null
    $voltMv = $null
    try {
        $bs = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStatus' | Select-Object -First 1
        if ($bs) {
            $online = [bool]$bs.PowerOnline
            if ($bs.Voltage -gt 0) { $voltMv = [int]$bs.Voltage }
        }
    } catch {}
    if ($null -eq $online) {
        $wb = Invoke-SafeCim -ClassName 'Win32_Battery' | Select-Object -First 1
        if ($wb) {
            $online = ($wb.BatteryStatus -eq 2 -or $wb.BatteryStatus -eq 6 -or $wb.BatteryStatus -eq 7 -or $wb.BatteryStatus -eq 8 -or $wb.BatteryStatus -eq 9)
            if ($wb.DesignVoltage -gt 0) { $voltMv = [int]$wb.DesignVoltage }
        }
    }
    return [PSCustomObject]@{
        PowerOnline = $online
        VoltageMv   = $voltMv
    }
}

function Get-CpuAndThermalTest {
    param(
        [int]$StressSeconds = 10,
        [string]$NvidiaSmiPath = ''
    )

    $procs = @(Invoke-SafeCim -ClassName 'Win32_Processor')
    $p0 = $procs | Select-Object -First 1
    $totalCores = 0
    $totalLogical = 0
    foreach ($p in $procs) {
        $totalCores += [int]$p.NumberOfCores
        $totalLogical += [int]$p.NumberOfLogicalProcessors
    }
    if ($totalLogical -le 0) { $totalLogical = [Environment]::ProcessorCount }

    $idleTemp = Get-CpuTempCelsius
    $loadSamples = @()

    $verificationPassed = $true
    $intOpsPerSec = 0
    $fpOpsPerSec = 0
    $peakTemp = $idleTemp
    $peakGpuTemp = Get-NvidiaTempQuick -NvidiaSmiPath $NvidiaSmiPath
    $avgClockPct = $null
    $thermalStatus = if ($null -eq $idleTemp) { 'UNAVAILABLE' } else { 'PASS' }
    $throttlingSuspected = $false
    $stressSkipped = ($StressSeconds -le 0)

    if (-not $stressSkipped) {
        # Precompute exact verification digests on main thread
        $seedBytes = [System.Text.Encoding]::ASCII.GetBytes('LaptopInspect-Verify-Seed-2026')
        $shaInit = [System.Security.Cryptography.SHA256]::Create()
        $buf = $seedBytes
        for ($r = 0; $r -lt 200; $r++) { $buf = $shaInit.ComputeHash($buf) }
        $expectedHash = [BitConverter]::ToString($buf)
        $shaInit.Dispose()

        $expectedFp = 0.0
        for ($k = 1; $k -le 1500; $k++) {
            $expectedFp += [Math]::Sqrt($k * 1.37) * [Math]::Sin($k * 0.017) + [Math]::Cos($k * 0.013)
        }

        $workerScript = {
            param($DurationSec, $ExpHash, $ExpFp)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $seed = [System.Text.Encoding]::ASCII.GetBytes('LaptopInspect-Verify-Seed-2026')
            $intBlocks = 0L
            $fpBlocks = 0L
            $ok = $true
            try {
                while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
                    $b = $seed
                    for ($r = 0; $r -lt 200; $r++) { $b = $sha.ComputeHash($b) }
                    if ([BitConverter]::ToString($b) -ne $ExpHash) { $ok = $false; break }
                    $intBlocks++

                    $fp = 0.0
                    for ($k = 1; $k -le 1500; $k++) {
                        $fp += [Math]::Sqrt($k * 1.37) * [Math]::Sin($k * 0.017) + [Math]::Cos($k * 0.013)
                    }
                    if ([Math]::Abs($fp - $ExpFp) -gt 1e-6) { $ok = $false; break }
                    $fpBlocks++
                }
            } finally {
                $sha.Dispose()
                $sw.Stop()
            }
            return [PSCustomObject]@{
                Ok        = $ok
                IntOps    = ($intBlocks * 200)
                FpOps     = ($fpBlocks * 1500)
                ElapsedMs = $sw.Elapsed.TotalMilliseconds
            }
        }

        $pool = [RunspaceFactory]::CreateRunspacePool(1, $totalLogical)
        $pool.Open()
        $handles = @()
        try {
            for ($w = 0; $w -lt $totalLogical; $w++) {
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($workerScript).AddArgument($StressSeconds).AddArgument($expectedHash).AddArgument($expectedFp)
                $async = $ps.BeginInvoke()
                $handles += [PSCustomObject]@{ Ps = $ps; Async = $async }
            }

            $clockSamples = @()
            $monitorSw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($monitorSw.Elapsed.TotalSeconds -lt ($StressSeconds + 0.3)) {
                $allDone = $true
                foreach ($h in $handles) {
                    if (-not $h.Async.IsCompleted) { $allDone = $false; break }
                }
                if ($allDone) { break }

                $tNow = Get-CpuTempCelsius
                if ($null -ne $tNow) {
                    if ($null -eq $peakTemp -or $tNow -gt $peakTemp) { $peakTemp = $tNow }
                }
                $gNow = Get-NvidiaTempQuick -NvidiaSmiPath $NvidiaSmiPath
                if ($null -ne $gNow) {
                    if ($null -eq $peakGpuTemp -or $gNow -gt $peakGpuTemp) { $peakGpuTemp = $gNow }
                }
                try {
                    $cPerf = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue
                    if ($cPerf -gt 0) { $clockSamples += [Math]::Round($cPerf, 1) }
                } catch {}

                $batNow = Get-BatteryLiveSample
                $loadSamples += [PSCustomObject]@{
                    Second      = [Math]::Round($monitorSw.Elapsed.TotalSeconds, 1)
                    TempC       = $tNow
                    GpuTempC    = $gNow
                    PowerOnline = $batNow.PowerOnline
                    VoltageMv   = $batNow.VoltageMv
                }

                Start-Sleep -Milliseconds 1000
            }
            $monitorSw.Stop()

            $totalInt = 0L
            $totalFp = 0L
            foreach ($h in $handles) {
                try {
                    $res = $h.Ps.EndInvoke($h.Async)
                    foreach ($r in $res) {
                        if (-not $r.Ok) { $verificationPassed = $false }
                        $totalInt += [long]$r.IntOps
                        $totalFp  += [long]$r.FpOps
                    }
                } catch {
                    # Ignore worker collection issue
                } finally {
                    $h.Ps.Dispose()
                }
            }

            $intOpsPerSec = [int][Math]::Round($totalInt / [double]$StressSeconds)
            $fpOpsPerSec  = [int][Math]::Round($totalFp / [double]$StressSeconds)
            if ($clockSamples.Count -gt 0) {
                $avgClockPct = [Math]::Round(($clockSamples | Measure-Object -Average).Average, 1)
            }
            if ($null -ne $peakTemp -and $peakTemp -ge 92.0) {
                $throttlingSuspected = $true
                $thermalStatus = 'WARN'
            } elseif ($null -ne $peakTemp) {
                $thermalStatus = 'PASS'
            } else {
                $thermalStatus = 'UNAVAILABLE'
            }
        } finally {
            $pool.Close()
            $pool.Dispose()
        }
    }

    return [PSCustomObject]@{
        CpuName              = if ($p0) { ([string]$p0.Name).Trim() } else { 'Unknown CPU' }
        Manufacturer         = if ($p0) { [string]$p0.Manufacturer } else { '' }
        Socket               = if ($p0) { [string]$p0.SocketDesignation } else { '' }
        PhysicalCores        = $totalCores
        LogicalProcessors    = $totalLogical
        MaxClockMHz          = if ($p0) { [int]$p0.MaxClockSpeed } else { 0 }
        L2CacheKB            = if ($p0) { [int]$p0.L2CacheSize } else { 0 }
        L3CacheKB            = if ($p0) { [int]$p0.L3CacheSize } else { 0 }
        VirtualizationReady  = if ($p0) { [bool]$p0.VirtualizationFirmwareEnabled } else { $false }
        StressSkipped        = $stressSkipped
        StressSeconds        = $StressSeconds
        VerificationPassed   = $verificationPassed
        IntOpsPerSec         = $intOpsPerSec
        FpOpsPerSec          = $fpOpsPerSec
        IdleTempC            = $idleTemp
        PeakTempC            = $peakTemp
        PeakGpuTempC         = $peakGpuTemp
        AvgClockPerfPct      = $avgClockPct
        ThermalStatus        = $thermalStatus
        ThrottlingSuspected  = $throttlingSuspected
        LoadSamples          = @($loadSamples)
    }
}
