function Get-BuyerVerdict {
    param(
        [Parameter(Mandatory = $true)]$ReportData
    )

    $score = 100
    $deductions = @()
    $criticalFlags = @()
    $warnings = @()
    $advisories = @()

    $corp = $ReportData.CorporateLock
    $cpu  = $ReportData.Cpu
    $gpu  = $ReportData.Gpu
    $ram  = $ReportData.Ram
    $stor = $ReportData.Storage
    $bat  = $ReportData.Battery
    $per  = $ReportData.Peripherals
    $sys  = $ReportData.System

    # 1. Corporate Lock Rules
    if ($corp) {
        if ($corp.Autopilot -and $corp.Autopilot.Assigned) {
            $td = if ($corp.Autopilot.TenantDomain) { " ($($corp.Autopilot.TenantDomain))" } else { '' }
            $criticalFlags += "Windows Autopilot tenant assigned$td"
        }
        if ($corp.Dsreg -and ($corp.Dsreg.AzureAdJoined -or $corp.Dsreg.EnterpriseJoined -or $corp.Dsreg.DomainJoined)) {
            $tn = if ($corp.Dsreg.TenantName) { " ($($corp.Dsreg.TenantName))" } else { '' }
            $criticalFlags += "Corporate Entra ID / Active Directory joined$tn"
        }
        if ($corp.Mdm -and $corp.Mdm.Detected) {
            $criticalFlags += "Active Intune / MDM management enrollment detected"
        }
        if ($corp.Computrace -and ($corp.Computrace.OsEvidence.Count -gt 0 -or $corp.Computrace.BiosActive)) {
            $criticalFlags += "Absolute Persistence / Computrace active"
        }
        if ($corp.BiosSecurity -and $corp.BiosSecurity.PasswordSet) {
            $criticalFlags += "BIOS / UEFI Administrator or Supervisor password is SET"
        }
        if ($corp.RmmEdr -and $corp.RmmEdr.Detected) {
            $criticalFlags += ("Corporate RMM / EDR agent detected: {0}" -f ($corp.RmmEdr.Findings -join '; '))
        }

        if ($corp.ConfirmedCorporateLock) {
            $score -= 45
            $deductions += '-45: Confirmed Corporate Lock / Enterprise Ownership'
        }

        if ($corp.Dsreg -and $corp.Dsreg.WorkplaceJoined) {
            $score -= 10
            $warnings += 'Workplace / BYOD account linked (WorkplaceJoined=YES)'
            $deductions += '-10: WorkplaceJoined account present'
        }
        if ($corp.BitLocker -and $corp.BitLocker.Active) {
            $score -= 15
            $warnings += 'BitLocker drive encryption is ON (ensure recovery key or clean wipe before purchase)'
            $deductions += '-15: BitLocker Protection On'
        }
        if (-not $corp.IsAdminSession) {
            $advisories += 'Run was executed without Administrator privileges; some BIOS WMI, BitLocker, and SMART telemetry may be limited.'
        }
        if ($corp.BiosSecurity -and -not $corp.BiosSecurity.WmiChecked) {
            $advisories += 'Vendor BIOS WMI unavailable; verify BIOS/UEFI Setup manually at boot for Supervisor Password and Computrace.'
        }
        if ($corp.Autopilot -and -not $corp.Autopilot.Assigned) {
            $advisories += $corp.Autopilot.Advisory
        }
        if ($corp.Activation -and $corp.Activation.LicenseStatus -ne 'Licensed') {
            $score -= 10
            $warnings += ("Windows is not activated ({0})" -f $corp.Activation.LicenseStatus)
            $deductions += '-10: Windows unlicensed'
        } elseif ($corp.Activation -and $corp.Activation.Channel -eq 'VOLUME_KMSCLIENT') {
            $score -= 10
            $warnings += 'Windows uses Corporate Volume KMS licensing (will expire without corporate server)'
            $deductions += '-10: Volume KMS license'
        }
    }

    # 2. CPU Verification & Thermals
    if ($cpu) {
        if (-not $cpu.StressSkipped -and -not $cpu.VerificationPassed) {
            $score -= 40
            $criticalFlags += 'CPU verified calculation checksum FAILED under multi-core load'
            $deductions += '-40: CPU calculation failure'
        }
        if ($cpu.ThrottlingSuspected) {
            $score -= 15
            $warnings += ("High CPU load temperature ({0} C) / potential thermal throttling" -f $cpu.PeakTempC)
            $deductions += '-15: High CPU load temperature'
        } elseif ($cpu.ThermalStatus -eq 'UNAVAILABLE') {
            $advisories += 'ACPI CPU temperature sensor is not exposed on this board (UNAVAILABLE != PASS).'
        }
    }

    # 3. GPU Rules
    if ($gpu -and $gpu.HasError) {
        $errGpus = @($gpu.Gpus | Where-Object { $_.ErrorCode -ne 0 } | ForEach-Object { "$($_.Name) (Code $($_.ErrorCode))" })
        $score -= 40
        $criticalFlags += ("GPU hardware/driver error detected: {0}" -f ($errGpus -join ', '))
        $deductions += '-40: GPU error code'
    }

    # 4. RAM Rules
    if ($ram -and $ram.PatternTest -and $ram.PatternTest.Status -eq 'FAIL') {
        $score -= 40
        $criticalFlags += 'RAM 128 MB allocation pattern verification FAILED'
        $deductions += '-40: RAM pattern failure'
    }

    # 5. Storage Rules
    if ($stor) {
        if ($stor.InternalUnhealthy -or $stor.InternalErrors) {
            $score -= 35
            $criticalFlags += 'Internal storage SMART status Unhealthy or uncorrected read/write errors reported'
            $deductions += '-35: Unhealthy internal storage'
        } elseif ($stor.HighWearDetected) {
            $score -= 15
            $warnings += 'Internal SSD wear is >= 70%'
            $deductions += '-15: High SSD wear (>=70%)'
        }
    }

    # 6. Battery & Power Rules
    if ($bat) {
        $isLap = if ($sys) { [bool]$sys.IsLaptop } else { $true }
        if ($bat.BatteryCount -eq 0 -and $isLap) {
            $score -= 30
            $criticalFlags += 'Laptop chassis detected with 0 batteries installed or detected'
            $deductions += '-30: Missing laptop battery'
        } elseif ($bat.BatteryCount -gt 0) {
            $hp = $bat.OverallHealthPercent
            if ($null -ne $hp) {
                if ($hp -lt 50) {
                    $score -= 25
                    $warnings += ("Severe battery wear ({0}% health remaining)" -f $hp)
                    $deductions += '-25: Battery < 50% health'
                } elseif ($hp -lt 75) {
                    $score -= 15
                    $warnings += ("Moderate battery wear ({0}% health remaining)" -f $hp)
                    $deductions += '-15: Battery 50-74% health'
                } elseif ($hp -lt 85) {
                    $score -= 5
                    $deductions += '-5: Battery 75-84% health'
                }
            } else {
                $advisories += 'Battery capacity telemetry unavailable from ACPI/powercfg.'
            }
            if ($null -ne $bat.MaxCycleCount -and $bat.MaxCycleCount -gt 500) {
                $score -= 5
                $warnings += ("High battery cycle count ({0} cycles)" -f $bat.MaxCycleCount)
                $deductions += '-5: Battery > 500 cycles'
            }
            if ($bat.AcFlickerDetected -or $bat.VoltageDroopDetected) {
                $score -= 15
                $warnings += 'AC adapter power flicker or >12% voltage droop observed during stress load'
                $deductions += '-15: AC/power instability under load'
            }
        }
    }

    # 7. Device Manager Errors
    if ($per -and $per.DeviceErrors) {
        $actErrs = @($per.DeviceErrors | Where-Object { -not $_.IsDisabled })
        if ($actErrs.Count -gt 0) {
            $pen = [Math]::Min(15, $actErrs.Count * 5)
            $score -= $pen
            $names = ($actErrs | Select-Object -First 4 | ForEach-Object { "$($_.Name) [Code $($_.ErrorCode)]" }) -join ', '
            $warnings += ("Device Manager hardware/driver errors ({0}): {1}" -f $actErrs.Count, $names)
            $deductions += ("-{0}: Device Manager errors ({1})" -f $pen, $actErrs.Count)
        }
    }

    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    $verdict = if ($criticalFlags.Count -gt 0) {
        'DO NOT BUY'
    } elseif ($warnings.Count -gt 0 -or $score -lt 80) {
        'CAUTION'
    } else {
        'BUY'
    }

    $upgradeNotes = @()
    if ($ram) {
        if ($ram.FreeSlots -gt 0) {
            $upgradeNotes += ("{0} free RAM slot(s) available ({1} of {2} used)" -f $ram.FreeSlots, $ram.UsedSlots, $ram.TotalSlots)
        } elseif ($ram.SolderedDetected) {
            $upgradeNotes += 'RAM appears soldered / non-upgradeable (0 free slots, LPDDR/chip form factor)'
        } else {
            $upgradeNotes += ("All {0} RAM slots occupied (can upgrade by replacing existing DIMMs)" -f $ram.TotalSlots)
        }
    }
    if ($stor -and $stor.Disks) {
        $intDisks = @($stor.Disks | Where-Object { -not $_.IsExternal })
        foreach ($idisk in $intDisks) {
            $upgradeNotes += ("Internal drive: {0} ({1} GB, {2})" -f $idisk.FriendlyName, $idisk.SizeGB, $idisk.BusType)
        }
    }

    return [PSCustomObject]@{
        Verdict       = $verdict
        Score         = $score
        Deductions    = @($deductions)
        CriticalFlags = @($criticalFlags)
        Warnings      = @($warnings)
        Advisories    = @($advisories)
        UpgradeNotes  = @($upgradeNotes)
    }
}
