function Find-NvidiaSmiPath {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
        (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            return $c
        }
    }
    try {
        $cmd = Get-Command -Name 'nvidia-smi.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    } catch {}
    return ''
}

function ConvertFrom-QwMemorySizeValue {
    param($RawVal)
    if ($null -eq $RawVal) { return 0L }
    if ($RawVal -is [byte[]]) {
        if ($RawVal.Length -ge 8) {
            return [int64][BitConverter]::ToUInt64($RawVal, 0)
        } elseif ($RawVal.Length -ge 4) {
            return [int64][BitConverter]::ToUInt32($RawVal, 0)
        }
        return 0L
    }
    try {
        return [int64]$RawVal
    } catch {
        return 0L
    }
}

function Get-AccurateGpuVramMap {
    $map = @{}
    $base = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path -LiteralPath $base)) { return $map }
    try {
        $subKeys = Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
        foreach ($sk in $subKeys) {
            $desc = Get-SafeRegValue -Path $sk.PSPath -Name 'DriverDesc' -Default ''
            $qw   = Get-SafeRegValue -Path $sk.PSPath -Name 'HardwareInformation.qwMemorySize' -Default $null
            $memB = ConvertFrom-QwMemorySizeValue -RawVal $qw
            if ($memB -le 0) {
                $ms = Get-SafeRegValue -Path $sk.PSPath -Name 'HardwareInformation.MemorySize' -Default $null
                $memB = ConvertFrom-QwMemorySizeValue -RawVal $ms
            }
            if (-not [string]::IsNullOrWhiteSpace($desc) -and $memB -gt 0) {
                $key = $desc.Trim().ToLower()
                if (-not $map.ContainsKey($key) -or $memB -gt $map[$key]) {
                    $map[$key] = $memB
                }
            }
        }
    } catch {}
    return $map
}

function Get-GpuDiagnostics {
    param([string]$NvidiaSmiPath = '')

    if ([string]::IsNullOrWhiteSpace($NvidiaSmiPath)) {
        $NvidiaSmiPath = Find-NvidiaSmiPath
    }

    $vramMap = Get-AccurateGpuVramMap
    $vcs = @(Invoke-SafeCim -ClassName 'Win32_VideoController')
    $gpus = @()
    $hasError = $false

    foreach ($vc in $vcs) {
        $name = ([string]$vc.Name).Trim()
        $key = $name.ToLower()
        $vramBytes = 0L
        if ($vramMap.ContainsKey($key)) {
            $vramBytes = [int64]$vramMap[$key]
        } elseif ($vc.AdapterRAM -and [int64]$vc.AdapterRAM -gt 0) {
            $vramBytes = [int64]([uint32]$vc.AdapterRAM)
        }
        $vramMB = if ($vramBytes -gt 0) { [int][Math]::Round($vramBytes / 1MB) } else { 0 }
        $vramGB = if ($vramBytes -gt 0) { [Math]::Round($vramBytes / 1GB, 2) } else { 0 }

        $errCode = [int]$vc.ConfigManagerErrorCode
        if ($errCode -ne 0) { $hasError = $true }

        $isDiscrete = ($name -match 'NVIDIA|GeForce|Quadro|RTX|GTX|Radeon RX|Radeon Pro|Arc A\d{3}|Arc B\d{3}')
        $drvDate = ''
        if ($vc.DriverDate) {
            try { $drvDate = ([datetime]$vc.DriverDate).ToString('yyyy-MM-dd') } catch { $drvDate = [string]$vc.DriverDate }
        }

        $gpus += [PSCustomObject]@{
            Name              = $name
            Vendor            = [string]$vc.AdapterCompatibility
            Type              = if ($isDiscrete) { 'Discrete GPU' } else { 'Integrated GPU' }
            VramMB            = $vramMB
            VramGB            = $vramGB
            DriverVersion     = [string]$vc.DriverVersion
            DriverDate        = $drvDate
            ErrorCode         = $errCode
            Status            = [string]$vc.Status
            Resolution        = if ($vc.CurrentHorizontalResolution -gt 0) { ("{0}x{1}" -f $vc.CurrentHorizontalResolution, $vc.CurrentVerticalResolution) } else { '' }
            RefreshRateHz     = [int]$vc.CurrentRefreshRate
            PnPDeviceID       = [string]$vc.PNPDeviceID
        }
    }

    $nvidiaTelemetry = @()
    if (-not [string]::IsNullOrWhiteSpace($NvidiaSmiPath) -and (Test-Path -LiteralPath $NvidiaSmiPath)) {
        try {
            $lines = & $NvidiaSmiPath --query-gpu=name,vbios_version,memory.total,memory.used,temperature.gpu,power.draw,power.limit,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits 2>$null
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line -split ',\s*'
                if ($parts.Count -ge 9) {
                    $nvidiaTelemetry += [PSCustomObject]@{
                        Name          = $parts[0].Trim()
                        VbiosVersion  = $parts[1].Trim()
                        MemoryTotalMB = $parts[2].Trim()
                        MemoryUsedMB  = $parts[3].Trim()
                        TempC         = $parts[4].Trim()
                        PowerDrawW    = $parts[5].Trim()
                        PowerLimitW   = $parts[6].Trim()
                        PcieGen       = $parts[7].Trim()
                        PcieWidth     = $parts[8].Trim()
                    }
                }
            }
        } catch {}
    }

    $gpuStatus = if ($hasError) { 'FAIL' } elseif ($gpus.Count -gt 0) { 'PASS' } else { 'UNAVAILABLE' }

    return [PSCustomObject]@{
        Status          = $gpuStatus
        HasError        = $hasError
        Gpus            = @($gpus)
        NvidiaSmiPath   = $NvidiaSmiPath
        NvidiaTelemetry = @($nvidiaTelemetry)
    }
}
