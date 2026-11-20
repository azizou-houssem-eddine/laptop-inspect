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
