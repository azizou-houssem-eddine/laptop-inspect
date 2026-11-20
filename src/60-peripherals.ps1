function Decode-EdidString {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $chars = @()
    foreach ($b in $Bytes) {
        $code = [int]$b
        if ($code -eq 0) { break }
        if ($code -ge 32 -and $code -le 126) {
            $chars += [char]$code
        }
    }
    return (($chars -join '').Trim())
}

function Decode-EdidManufacturer {
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $arr = @($Bytes)
    if ($arr.Count -ge 3) {
        $ascii = Decode-EdidString -Bytes $arr
        if ($ascii -match '^[A-Za-z0-9]{2,4}$') { return $ascii.ToUpper() }
    }
    if ($arr.Count -ge 2) {
        $b0 = [int]$arr[0]
        $b1 = [int]$arr[1]
        $val = ($b0 -shl 8) -bor $b1
        $c1 = [char]((($val -shr 10) -band 0x1F) + 64)
        $c2 = [char]((($val -shr 5) -band 0x1F) + 64)
        $c3 = [char](($val -band 0x1F) + 64)
        return ("$c1$c2$c3").ToUpper()
    }
    return ''
}

function Get-DeviceErrorDescription {
    param([int]$Code)
    switch ($Code) {
        1  { 'Device not configured correctly' }
        10 { 'Device cannot start' }
        12 { 'Not enough free resources' }
        14 { 'Restart required' }
        18 { 'Reinstall drivers' }
        22 { 'Device disabled' }
        24 { 'Device not present or working properly' }
        28 { 'Drivers not installed' }
        31 { 'Device not working properly' }
        43 { 'Device stopped / hardware or driver failure (Code 43)' }
        45 { 'Currently not connected' }
        default { "ConfigManager Error Code $Code" }
    }
}

function Get-ConnectedPortsSnapshot {
    $usbDevices = @()
    $monitors = @()
    $netLinks = @()
    $audioEndpoints = @()
    $acOnline = $null

    try {
        $usbRaw = Invoke-SafeCim -ClassName 'Win32_PnPEntity' | Where-Object {
            $_.PNPClass -in @('USB', 'DiskDrive', 'HIDClass', 'Camera', 'Ports') -and
            $_.Status -eq 'OK' -and
            $_.Name -notmatch 'Root Hub|Host Controller|Generic USB Hub|Composite Bus'
        } | Select-Object -First 40
        foreach ($u in $usbRaw) {
            $usbDevices += [PSCustomObject]@{
                Name     = [string]$u.Name
                Class    = [string]$u.PNPClass
                DeviceID = [string]$u.PNPDeviceID
            }
        }
    } catch {}

    try {
        $monIds = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'WmiMonitorID'
        foreach ($m in $monIds) {
            $mfg = Decode-EdidManufacturer -Bytes $m.ManufacturerName
            $mdl = Decode-EdidString -Bytes $m.UserFriendlyName
            if ([string]::IsNullOrWhiteSpace($mdl)) { $mdl = Decode-EdidString -Bytes $m.ProductCodeID }
            $monitors += ("{0} {1}".Trim() -f $mfg, $mdl)
        }
    } catch {}

    try {
        if (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) {
            $nas = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
            foreach ($n in $nas) {
                $netLinks += [PSCustomObject]@{
                    Name      = [string]$n.Name
                    Desc      = [string]$n.InterfaceDescription
                    LinkSpeed = [string]$n.LinkSpeed
                }
            }
        }
    } catch {}

    try {
        $aud = Invoke-SafeCim -ClassName 'Win32_SoundDevice' | Where-Object { $_.Status -eq 'OK' }
        foreach ($a in $aud) {
            $audioEndpoints += [string]$a.Name
        }
    } catch {}

    try {
        $bs = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStatus' | Select-Object -First 1
        if ($bs) { $acOnline = [bool]$bs.PowerOnline }
    } catch {}

    return [PSCustomObject]@{
        Timestamp      = (Get-Date).ToString('HH:mm:ss')
        AcOnline       = $acOnline
        Monitors       = @($monitors)
        NetLinks       = @($netLinks)
        AudioEndpoints = @($audioEndpoints)
        UsbDevices     = @($usbDevices)
    }
}

function Get-PeripheralsAndNetwork {
    # 1. Display Panels (EDID + Resolution + Touchscreen)
    $displays = @()
    $monIds = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'WmiMonitorID')
    $monParams = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'WmiMonitorBasicDisplayParams')
    $vcs = @(Invoke-SafeCim -ClassName 'Win32_VideoController' | Where-Object { $_.CurrentHorizontalResolution -gt 0 })
    $primaryRes = if ($vcs.Count -gt 0) { ("{0}x{1}" -f $vcs[0].CurrentHorizontalResolution, $vcs[0].CurrentVerticalResolution) } else { '' }
    $primaryHz = if ($vcs.Count -gt 0) { [int]$vcs[0].CurrentRefreshRate } else { 0 }

    for ($i = 0; $i -lt $monIds.Count; $i++) {
        $m = $monIds[$i]
        $p = if ($i -lt $monParams.Count) { $monParams[$i] } else { $null }
        $diagIn = $null
        if ($p -and $p.MaxHorizontalImageSize -gt 0 -and $p.MaxVerticalImageSize -gt 0) {
            $hCm = [double]$p.MaxHorizontalImageSize
            $vCm = [double]$p.MaxVerticalImageSize
            $diagIn = [Math]::Round([Math]::Sqrt(($hCm * $hCm) + ($vCm * $vCm)) / 2.54, 1)
        }
        $mfg = Decode-EdidManufacturer -Bytes $m.ManufacturerName
        $model = Decode-EdidString -Bytes $m.UserFriendlyName
        $prod = Decode-EdidString -Bytes $m.ProductCodeID
        $displays += [PSCustomObject]@{
            Manufacturer = $mfg
            Model        = if (-not [string]::IsNullOrWhiteSpace($model)) { $model } else { $prod }
            ProductCode  = $prod
            Year         = [int]$m.YearOfManufacture
            Week         = [int]$m.WeekOfManufacture
            DiagonalIn   = $diagIn
            Resolution   = $primaryRes
            RefreshRateHz = $primaryHz
        }
    }

    $touchDetected = $false
    $pnpAll = @(Invoke-SafeCim -ClassName 'Win32_PnPEntity')
    foreach ($p in $pnpAll) {
        if ($p.Name -match 'HID-compliant touch screen|Touch Screen|Touchscreen') {
            $touchDetected = $true
            break
        }
    }

    # 2. Network, Wi-Fi Generation & Local Gateway Ping
    $adapters = @()
    try {
        if (Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) {
            $netList = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            foreach ($na in $netList) {
                $adapters += [PSCustomObject]@{
                    Name        = [string]$na.Name
                    Description = [string]$na.InterfaceDescription
                    Status      = [string]$na.Status
                    LinkSpeed   = [string]$na.LinkSpeed
                    MacAddress  = [string]$na.MacAddress
                    MediaType   = [string]$na.MediaType
                }
            }
        }
    } catch {}

    $wifiGeneration = 'Unknown'
    $wifiSsid = ''
    $wifiSignalPct = $null
    $wifiRadio = ''
    try {
        $drvOut = & netsh.exe wlan show drivers 2>$null
        $drvText = ($drvOut -join "`n")
        if ($drvText -match '802\.11be') { $wifiGeneration = 'Wi-Fi 7 (802.11be)' }
        elseif ($drvText -match '802\.11ax') { $wifiGeneration = 'Wi-Fi 6 / 6E (802.11ax)' }
        elseif ($drvText -match '802\.11ac') { $wifiGeneration = 'Wi-Fi 5 (802.11ac)' }
        elseif ($drvText -match '802\.11n') { $wifiGeneration = 'Wi-Fi 4 (802.11n)' }

        $ifOut = & netsh.exe wlan show interfaces 2>$null
        foreach ($line in $ifOut) {
            if ($line -match '^\s*SSID\s*:\s*(.+)$') { $wifiSsid = $matches[1].Trim() }
            elseif ($line -match '^\s*Signal\s*:\s*(\d+)%') { $wifiSignalPct = [int]$matches[1] }
            elseif ($line -match '^\s*Radio type\s*:\s*(.+)$') { $wifiRadio = $matches[1].Trim() }
        }
    } catch {}

    # Local-gateway ping check (non-telemetry local LAN check)
    $gatewayIp = ''
    $gatewayReachable = $null
    $gatewayLatencyMs = $null
    try {
        if (Get-Command -Name 'Get-NetRoute' -ErrorAction SilentlyContinue) {
            $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
            if ($route -and $route.NextHop -and $route.NextHop -ne '0.0.0.0') {
                $gatewayIp = [string]$route.NextHop
            }
        }
        if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
            $nac = Invoke-SafeCim -ClassName 'Win32_NetworkAdapterConfiguration' -Filter 'IPEnabled = TRUE'
            foreach ($c in $nac) {
                if ($c.DefaultIPGateway -and $c.DefaultIPGateway.Count -gt 0) {
                    $gatewayIp = [string]$c.DefaultIPGateway[0]
                    break
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($gatewayIp)) {
            $pinger = New-Object System.Net.NetworkInformation.Ping
            try {
                $rep = $pinger.Send($gatewayIp, 800)
                if ($rep.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $gatewayReachable = $true
                    $gatewayLatencyMs = [int]$rep.RoundtripTime
                } else {
                    $gatewayReachable = $false
                }
            } finally {
                $pinger.Dispose()
            }
        }
    } catch {}

    # 3. Bluetooth, Cameras, Biometrics, Audio, Ports
    $bluetooth = @()
    $cameras = @()
    $biometrics = @()
    $portsSummary = @()
    $deviceErrors = @()

    foreach ($p in $pnpAll) {
        $cls = [string]$p.PNPClass
        $nm  = [string]$p.Name
        $st  = [string]$p.Status
        $err = [int]$p.ConfigManagerErrorCode

        if ($cls -eq 'Bluetooth' -and $nm -notmatch 'Enumerator|Transport|Protocol') {
            $bluetooth += [PSCustomObject]@{ Name = $nm; Status = $st }
        }
        if ($cls -in @('Camera', 'Image')) {
            $cameras += [PSCustomObject]@{ Name = $nm; Status = $st; IsIR = ($nm -match '\bIR\b|Infrared|Hello') }
        }
        if ($cls -eq 'Biometric') {
            $biometrics += [PSCustomObject]@{ Name = $nm; Status = $st }
        }
        if ($nm -match 'Thunderbolt|USB4|UCSI|UcmUcsi|xHCI|USB 3\.|Realtek USB|Card Reader|SmartCard|SD Host') {
            if ($portsSummary -notcontains $nm) { $portsSummary += $nm }
        }
        if ($err -ne 0 -and $err -ne 45) {
            $deviceErrors += [PSCustomObject]@{
                Name        = $nm
                Class       = $cls
                ErrorCode   = $err
                Description = Get-DeviceErrorDescription -Code $err
                IsDisabled  = ($err -eq 22)
            }
        }
    }

    $audioDevices = @()
    foreach ($sd in @(Invoke-SafeCim -ClassName 'Win32_SoundDevice')) {
        $audioDevices += [PSCustomObject]@{
            Name         = [string]$sd.Name
            Manufacturer = [string]$sd.Manufacturer
            Status       = [string]$sd.Status
        }
    }

    $hasActionableErrors = (@($deviceErrors | Where-Object { -not $_.IsDisabled }).Count -gt 0)

    return [PSCustomObject]@{
        Display = [PSCustomObject]@{
            Panels        = @($displays)
            PrimaryRes    = $primaryRes
            PrimaryHz     = $primaryHz
            Touchscreen   = $touchDetected
        }
        Network = [PSCustomObject]@{
            Adapters         = @($adapters)
            WifiGeneration   = $wifiGeneration
            WifiSsid         = $wifiSsid
            WifiSignalPct    = $wifiSignalPct
            WifiRadio        = $wifiRadio
            GatewayIp        = $gatewayIp
            GatewayReachable = $gatewayReachable
            GatewayLatencyMs = $gatewayLatencyMs
        }
        Bluetooth    = @($bluetooth)
        Cameras      = @($cameras)
        Biometrics   = @($biometrics)
        AudioDevices = @($audioDevices)
        Ports        = @($portsSummary)
        DeviceErrors = @($deviceErrors)
        DeviceErrorStatus = if ($hasActionableErrors) { 'WARN' } else { 'PASS' }
    }
}
