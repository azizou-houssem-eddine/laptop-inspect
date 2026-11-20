function Get-RamDiagnostics {
    param([switch]$SkipStress)

    $arrays = @(Invoke-SafeCim -ClassName 'Win32_PhysicalMemoryArray' | Where-Object { $_.Use -eq 3 -or $null -eq $_.Use })
    $totalSlots = 0
    foreach ($a in $arrays) {
        if ($a.MemoryDevices -gt 0) { $totalSlots += [int]$a.MemoryDevices }
    }

    $dimmsRaw = @(Invoke-SafeCim -ClassName 'Win32_PhysicalMemory')
    $usedSlots = $dimmsRaw.Count
    if ($totalSlots -lt $usedSlots) { $totalSlots = $usedSlots }
    $freeSlots = [Math]::Max(0, $totalSlots - $usedSlots)

    $dimms = @()
    $totalBytes = 0L
    $solderedDetected = $false

    foreach ($d in $dimmsRaw) {
        $capB = [int64]$d.Capacity
        $totalBytes += $capB
        $capGB = [Math]::Round($capB / 1GB, 2)

        $mCode = [int]$d.SMBIOSMemoryType
        if ($mCode -eq 0) { $mCode = [int]$d.MemoryType }
        $memType = switch ($mCode) {
            20 { 'DDR' }
            21 { 'DDR2' }
            24 { 'DDR3' }
            26 { 'DDR4' }
            27 { 'LPDDR' }
            28 { 'LPDDR2' }
            29 { 'LPDDR3' }
            30 { 'LPDDR4' }
            34 { 'DDR5' }
            35 { 'LPDDR5' }
            default { "Type-$mCode" }
        }

        $ffCode = [int]$d.FormFactor
        $ffName = switch ($ffCode) {
            8  { 'DIMM' }
            12 { 'SODIMM' }
            6  { 'Proprietary / Chip' }
            0  { 'Unknown / Soldered' }
            default { "FormFactor-$ffCode" }
        }

        if ($memType -match '^LPDDR' -or $ffCode -eq 6) {
            $solderedDetected = $true
        }

        $dimms += [PSCustomObject]@{
            DeviceLocator     = [string]$d.DeviceLocator
            BankLabel         = [string]$d.BankLabel
            CapacityGB        = $capGB
            SpeedMTs          = [int]$d.Speed
            ConfiguredClockMTs = [int]$d.ConfiguredClockSpeed
            MemoryType        = $memType
            FormFactor        = $ffName
            Manufacturer      = ([string]$d.Manufacturer).Trim()
            PartNumber        = ([string]$d.PartNumber).Trim()
        }
    }

    if ($usedSlots -gt 0 -and $freeSlots -eq 0 -and ($dimms | Where-Object { $_.FormFactor -match 'Unknown|Soldered|Chip' })) {
        $solderedDetected = $true
    }

    $totalGB = [Math]::Round($totalBytes / 1GB, 2)
    $upgradeable = ($freeSlots -gt 0) -or (-not $solderedDetected -and $usedSlots -gt 0)

    # Free memory check & 128MB verified pattern test
    $os = Invoke-SafeCim -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    $freeMemMB = if ($os -and $os.FreePhysicalMemory) { [int][Math]::Round($os.FreePhysicalMemory / 1024.0) } else { 0 }

    $memTestStatus = 'UNAVAILABLE'
    $memTestDetail = 'Skipped'
    $memTestPassed = $true

    if ($SkipStress) {
        $memTestStatus = 'UNAVAILABLE'
        $memTestDetail = 'Skipped (-Quick / -SkipStress)'
    } elseif ($freeMemMB -lt 512) {
        $memTestStatus = 'UNAVAILABLE'
        $memTestDetail = ("Skipped (Only {0} MB free RAM; need 512 MB)" -f $freeMemMB)
    } else {
        $buf = $null
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $chunkSize = 1MB
            $chunks = 128
            $totalAlloc = $chunkSize * $chunks
            $buf = New-Object byte[] $totalAlloc

            $pattern = New-Object byte[] $chunkSize
            for ($i = 0; $i -lt $chunkSize; $i++) {
                $pattern[$i] = if (($i % 2) -eq 0) { [byte]0xAA } else { [byte](($i * 31) -band 0xFF) }
            }
            $expectedDigest = [BitConverter]::ToString($sha.ComputeHash($pattern))

            for ($c = 0; $c -lt $chunks; $c++) {
                [System.Buffer]::BlockCopy($pattern, 0, $buf, ($c * $chunkSize), $chunkSize)
            }

            $allMatch = $true
            for ($c = 0; $c -lt $chunks; $c++) {
                $actual = [BitConverter]::ToString($sha.ComputeHash($buf, ($c * $chunkSize), $chunkSize))
                if ($actual -ne $expectedDigest) {
                    $allMatch = $false
                    break
                }
            }

            if ($allMatch) {
                $memTestPassed = $true
                $memTestStatus = 'PASS'
                $memTestDetail = 'Verified 128 MB allocation pattern + SHA-256 readback (user-space scope)'
            } else {
                $memTestPassed = $false
                $memTestStatus = 'FAIL'
                $memTestDetail = 'Pattern verification mismatch in 128 MB allocation!'
            }
        } catch {
            $memTestStatus = 'UNAVAILABLE'
            $memTestDetail = ("Allocation error: {0}" -f $_.Exception.Message)
        } finally {
            if ($sha) { $sha.Dispose() }
            $buf = $null
            [GC]::Collect()
        }
    }

    return [PSCustomObject]@{
        TotalGB          = $totalGB
        FreeMB           = $freeMemMB
        TotalSlots       = $totalSlots
        UsedSlots        = $usedSlots
        FreeSlots        = $freeSlots
        SolderedDetected = $solderedDetected
        Upgradeable      = $upgradeable
        Dimms            = @($dimms)
        PatternTest      = [PSCustomObject]@{
            Status = $memTestStatus
            Passed = $memTestPassed
            Detail = $memTestDetail
        }
    }
}

function Find-SmartctlPath {
    try {
        $cmd = Get-Command -Name 'smartctl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    } catch {}
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot 'smartctl.exe'
        if (Test-Path -LiteralPath $local) { return $local }
    }
    return ''
}

function Get-StorageDiagnostics {
    param([switch]$SkipBench)

    $disks = @()
    $internalUnhealthy = $false
    $internalErrors = $false
    $highWearDetected = $false

    try {
        $physDisks = @(Get-PhysicalDisk -ErrorAction Stop)
        foreach ($pd in $physDisks) {
            $rel = $null
            try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}

            $bus = [string]$pd.BusType
            $isExternal = ($bus -eq 'USB' -or $bus -eq 'SD')
            $health = [string]$pd.HealthStatus
            $wear = if ($rel -and $null -ne $rel.Wear) { [int]$rel.Wear } else { $null }
            $tempC = if ($rel -and $null -ne $rel.Temperature -and $rel.Temperature -gt 0 -and $rel.Temperature -lt 120) { [int]$rel.Temperature } else { $null }
            $poh = if ($rel -and $null -ne $rel.PowerOnHours) { [int]$rel.PowerOnHours } else { $null }
            $readErr = if ($rel -and $null -ne $rel.ReadErrorsUncorrected) { [int64]$rel.ReadErrorsUncorrected } else { $null }
            $writeErr = if ($rel -and $null -ne $rel.WriteErrorsUncorrected) { [int64]$rel.WriteErrorsUncorrected } else { $null }

            if (-not $isExternal) {
                if ($health -ne 'Healthy') { $internalUnhealthy = $true }
                if (($null -ne $readErr -and $readErr -gt 0) -or ($null -ne $writeErr -and $writeErr -gt 0)) { $internalErrors = $true }
                if ($null -ne $wear -and $wear -ge 70) { $highWearDetected = $true }
            }

            $disks += [PSCustomObject]@{
                FriendlyName           = [string]$pd.FriendlyName
                SerialNumber           = ([string]$pd.SerialNumber).Trim()
                MediaType              = [string]$pd.MediaType
                BusType                = $bus
                IsExternal             = $isExternal
                SizeGB                 = [Math]::Round([double]$pd.Size / 1GB, 1)
                HealthStatus           = $health
                OperationalStatus      = [string]$pd.OperationalStatus
                WearPercent            = $wear
                TemperatureC           = $tempC
                PowerOnHours           = $poh
                ReadErrorsUncorrected  = $readErr
                WriteErrorsUncorrected = $writeErr
            }
        }
    } catch {
        # Fallback to Win32_DiskDrive
        $wDisks = @(Invoke-SafeCim -ClassName 'Win32_DiskDrive')
        foreach ($wd in $wDisks) {
            $isExt = ([string]$wd.InterfaceType -eq 'USB')
            $st = [string]$wd.Status
            if (-not $isExt -and $st -ne 'OK') { $internalUnhealthy = $true }
            $disks += [PSCustomObject]@{
                FriendlyName           = [string]$wd.Model
                SerialNumber           = ([string]$wd.SerialNumber).Trim()
                MediaType              = [string]$wd.MediaType
                BusType                = [string]$wd.InterfaceType
                IsExternal             = $isExt
                SizeGB                 = [Math]::Round([double]$wd.Size / 1GB, 1)
                HealthStatus           = if ($st -eq 'OK') { 'Healthy' } else { $st }
                OperationalStatus      = $st
                WearPercent            = $null
                TemperatureC           = $null
                PowerOnHours           = $null
                ReadErrorsUncorrected  = $null
                WriteErrorsUncorrected = $null
            }
        }
    }

    # Optional smartctl enrichment if installed on host
    $smartctlPath = Find-SmartctlPath
    $smartctlAvailable = (-not [string]::IsNullOrWhiteSpace($smartctlPath))
    $smartctlRaw = @()
    if ($smartctlAvailable) {
        try {
            $scanJson = & $smartctlPath --scan -j 2>$null | Out-String | ConvertFrom-Json
            if ($scanJson -and $scanJson.devices) {
                foreach ($dev in $scanJson.devices) {
                    $dJson = & $smartctlPath -H -A -j $dev.name 2>$null | Out-String | ConvertFrom-Json
                    if ($dJson) {
                        $smartctlRaw += [PSCustomObject]@{
                            Device = [string]$dev.name
                            Model  = [string]$dJson.model_name
                            Passed = if ($dJson.smart_status) { [bool]$dJson.smart_status.passed } else { $null }
                            TempC  = if ($dJson.temperature) { $dJson.temperature.current } else { $null }
                        }
                    }
                }
            }
        } catch {}
    }

    $volumes = @()
    try {
        $vols = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and $_.Size -gt 0 })
        foreach ($v in $vols) {
            $volumes += [PSCustomObject]@{
                DriveLetter = [string]$v.DriveLetter
                Label       = [string]$v.FileSystemLabel
                FileSystem  = [string]$v.FileSystem
                DriveType   = [string]$v.DriveType
                SizeGB      = [Math]::Round([double]$v.Size / 1GB, 1)
                FreeGB      = [Math]::Round([double]$v.SizeRemaining / 1GB, 1)
            }
        }
    } catch {}

    # 64MB sequential read/write benchmark on TEMP drive
    $benchStatus = 'UNAVAILABLE'
    $seqWriteMBs = $null
    $seqReadMBs = $null
    $benchNote = 'Skipped'

    if (-not $SkipBench) {
        $tempRoot = [System.IO.Path]::GetPathRoot($env:TEMP)
        $driveLetter = if ($tempRoot) { $tempRoot.Substring(0, 1) } else { 'C' }
        $sysVol = $volumes | Where-Object { $_.DriveLetter -eq $driveLetter } | Select-Object -First 1
        if ($sysVol -and $sysVol.FreeGB -lt 0.5) {
            $benchNote = 'Skipped (< 500 MB free space)'
        } else {
            $tmpFile = Join-Path $env:TEMP ("li_diskbench_{0}.tmp" -f $PID)
            try {
                $mbCount = 64
                $block = New-Object byte[] (1MB)
                (New-Object Random 42).NextBytes($block)

                $swW = [System.Diagnostics.Stopwatch]::StartNew()
                $fsW = New-Object System.IO.FileStream($tmpFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB, [System.IO.FileOptions]::WriteThrough)
                try {
                    for ($i = 0; $i -lt $mbCount; $i++) { $fsW.Write($block, 0, $block.Length) }
                    $fsW.Flush()
                } finally {
                    $fsW.Close()
                    $fsW.Dispose()
                }
                $swW.Stop()
                if ($swW.Elapsed.TotalSeconds -gt 0) {
                    $seqWriteMBs = [Math]::Round($mbCount / $swW.Elapsed.TotalSeconds, 1)
                }

                $swR = [System.Diagnostics.Stopwatch]::StartNew()
                $fsR = New-Object System.IO.FileStream($tmpFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None, 1MB)
                try {
                    $rBuf = New-Object byte[] (1MB)
                    while ($fsR.Read($rBuf, 0, $rBuf.Length) -gt 0) {}
                } finally {
                    $fsR.Close()
                    $fsR.Dispose()
                }
                $swR.Stop()
                if ($swR.Elapsed.TotalSeconds -gt 0) {
                    $seqReadMBs = [Math]::Round($mbCount / $swR.Elapsed.TotalSeconds, 1)
                }

                $benchStatus = 'PASS'
                $benchNote = ("64 MB sequential test on {0}: (WriteThrough)" -f $driveLetter)
            } catch {
                $benchStatus = 'UNAVAILABLE'
                $benchNote = ("Benchmark error: {0}" -f $_.Exception.Message)
            } finally {
                if (Test-Path -LiteralPath $tmpFile) {
                    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    $storageStatus = if ($internalUnhealthy -or $internalErrors) {
        'FAIL'
    } elseif ($highWearDetected) {
        'WARN'
    } elseif ($disks.Count -gt 0) {
        'PASS'
    } else {
        'UNAVAILABLE'
    }

    return [PSCustomObject]@{
        Status            = $storageStatus
        InternalUnhealthy = $internalUnhealthy
        InternalErrors    = $internalErrors
        HighWearDetected  = $highWearDetected
        SmartctlAvailable = $smartctlAvailable
        SmartctlData      = @($smartctlRaw)
        Disks             = @($disks)
        Volumes           = @($volumes)
        Benchmark         = [PSCustomObject]@{
            Status      = $benchStatus
            SeqWriteMBs = $seqWriteMBs
            SeqReadMBs  = $seqReadMBs
            Note        = $benchNote
        }
    }
}
