function Test-IsCorporateMdmEnrollment {
    param(
        [string]$ProviderID = '',
        [string]$DiscoveryUrl = '',
        [string]$UPN = '',
        [string]$AADTenantID = '',
        $EnrollmentType = $null
    )
    $builtInProviders = @('Local Authority', 'Deploy Authority', 'Cloud Authority', 'WMI_Bridge_SCCM_Server')
    $hasRemoteEndpoint = (-not [string]::IsNullOrWhiteSpace($DiscoveryUrl)) -or (-not [string]::IsNullOrWhiteSpace($AADTenantID)) -or (-not [string]::IsNullOrWhiteSpace($UPN))
    if ($hasRemoteEndpoint) { return $true }
    $pTrim = ([string]$ProviderID).Trim()
    if ([string]::IsNullOrWhiteSpace($pTrim)) { return $false }
    if ($builtInProviders -contains $pTrim) { return $false }
    if ($null -ne $EnrollmentType -and ([int]$EnrollmentType -in @(12, 28, 30, 31))) { return $false }
    return $true
}

function Parse-DsregcmdOutput {
    param(
        [string[]]$Lines
    )
    $result = [ordered]@{
        Available        = $false
        AzureAdJoined    = $false
        EnterpriseJoined = $false
        DomainJoined     = $false
        WorkplaceJoined  = $false
        TenantName       = ''
        TenantId         = ''
        MdmUrl           = ''
        MdmTouUrl        = ''
        DeviceAuthStatus = ''
    }
    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return [PSCustomObject]$result
    }
    $result.Available = $true
    foreach ($rawLine in $Lines) {
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        $line = $rawLine.Trim()
        if ($line -match '^([^:]+?)\s*:\s*(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            switch ($key) {
                'AzureAdJoined'    { $result.AzureAdJoined    = ($val -match '^(YES|TRUE)$') }
                'EnterpriseJoined' { $result.EnterpriseJoined = ($val -match '^(YES|TRUE)$') }
                'DomainJoined'     { $result.DomainJoined     = ($val -match '^(YES|TRUE)$') }
                'WorkplaceJoined'  { $result.WorkplaceJoined  = ($val -match '^(YES|TRUE)$') }
                'TenantName'       { $result.TenantName       = $val }
                'TenantId'         { $result.TenantId         = $val }
                'MdmUrl'           { $result.MdmUrl           = $val }
                'MdmTouUrl'        { $result.MdmTouUrl        = $val }
                'DeviceAuthStatus' { $result.DeviceAuthStatus = $val }
            }
        }
    }
    return [PSCustomObject]$result
}

function Get-CorporateLockAudit {
    param(
        [bool]$IsAdmin = (Test-IsAdmin)
    )

    # 1. dsregcmd /status
    $dsregObj = Parse-DsregcmdOutput -Lines @()
    try {
        $dsregPath = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
        if (Test-Path -LiteralPath $dsregPath) {
            $dsLines = & $dsregPath /status 2>$null
            if ($dsLines) {
                $dsregObj = Parse-DsregcmdOutput -Lines @($dsLines)
            }
        }
    } catch {
        # Leave default Unavailable
    }

    # 2. Windows Autopilot
    $autopilotEvidence = @()
    $autopilotAssigned = $false
    $apTenantDomain = ''
    $apTenantId = ''

    $apPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotSettings',
        'HKLM:\SOFTWARE\Microsoft\Provisioning\Diagnostics\AutoPilot',
        'HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache'
    )
    foreach ($p in $apPaths) {
        if (Test-Path -LiteralPath $p) {
            $td = Get-SafeRegValue -Path $p -Name 'CloudAssignedTenantDomain' -Default ''
            $ti = Get-SafeRegValue -Path $p -Name 'CloudAssignedTenantId' -Default ''
            if ([string]::IsNullOrWhiteSpace($ti)) {
                $ti = Get-SafeRegValue -Path $p -Name 'TenantId' -Default ''
            }
            $fe = Get-SafeRegValue -Path $p -Name 'CloudAssignedForcedEnrollment' -Default $null
            $oc = Get-SafeRegValue -Path $p -Name 'CloudAssignedOobeConfig' -Default $null
            $disabled = Get-SafeRegValue -Path $p -Name 'IsAutoPilotDisabled' -Default $null

            $hasTenant = (-not [string]::IsNullOrWhiteSpace($td)) -or (-not [string]::IsNullOrWhiteSpace($ti))
            $forcedOn = ($fe -eq 1)
            $hasOobeTenant = ($hasTenant -and $null -ne $oc -and $oc -ne 0)

            if (($hasTenant -or $forcedOn -or $hasOobeTenant) -and ($disabled -ne 1)) {
                $autopilotAssigned = $true
                if (-not [string]::IsNullOrWhiteSpace($td)) { $apTenantDomain = $td }
                if (-not [string]::IsNullOrWhiteSpace($ti)) { $apTenantId = $ti }
                $autopilotEvidence += ("Registry {0}: Tenant={1} Id={2}" -f $p, $td, $ti)
            }
        }
    }

    $apJsonPath = Join-Path $env:SystemRoot 'Provisioning\Autopilot\AutopilotConfigurationFile.json'
    if (Test-Path -LiteralPath $apJsonPath) {
        $autopilotAssigned = $true
        try {
            $apJson = Get-Content -LiteralPath $apJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($apJson.CloudAssignedTenantDomain) { $apTenantDomain = [string]$apJson.CloudAssignedTenantDomain }
            if ($apJson.CloudAssignedTenantId) { $apTenantId = [string]$apJson.CloudAssignedTenantId }
        } catch {
            # Ignore parse error
        }
        $autopilotEvidence += ("Offline Profile File: {0}" -f $apJsonPath)
    }

    try {
        $cloudCache = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\Machine\Cache'
        if (Test-Path -LiteralPath $cloudCache) {
            $apCacheHits = Get-ChildItem -LiteralPath $cloudCache -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'autopilot' }
            foreach ($hit in $apCacheHits) {
                $autopilotEvidence += ("CloudStore Cache: {0}" -f $hit.PSChildName)
            }
        }
    } catch {
        # Ignore registry access issue
    }

    $hwHashPresent = $false
    $hwHashSummary = 'Unavailable (Admin required or MDM namespace absent)'
    if ($IsAdmin) {
        $devDetail = Invoke-SafeCim -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_DevDetail_Ext01'
        if ($devDetail.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($devDetail[0].DeviceHardwareData)) {
            $hwHashPresent = $true
            $rawHash = [string]$devDetail[0].DeviceHardwareData
            $prefix = if ($rawHash.Length -gt 16) { $rawHash.Substring(0, 16) } else { $rawHash }
            $hwHashSummary = ("Readable ({0} chars, prefix {1}...)" -f $rawHash.Length, $prefix)
        } else {
            $hwHashSummary = 'Not exposed by MDM_DevDetail_Ext01'
        }
    }

    $autopilotStatus = if ($autopilotAssigned) { 'FAIL' } else { 'PASS' }
    $autopilotAdvisory = 'Local registry/cache clean does not rule out cloud-only Autopilot after a fresh offline wipe; verify online at Windows Reset OOBE before finalizing if possible.'

    # 3. Intune / MDM Enrollment
    $mdmEntries = @()
    $enrollBase = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $enrollBase) {
        $subKeys = Get-ChildItem -LiteralPath $enrollBase -ErrorAction SilentlyContinue
        foreach ($sk in $subKeys) {
            $p = $sk.PSPath
            $prov  = [string](Get-SafeRegValue -Path $p -Name 'ProviderID' -Default '')
            $disc  = [string](Get-SafeRegValue -Path $p -Name 'DiscoveryServiceFullURL' -Default '')
            $upn   = [string](Get-SafeRegValue -Path $p -Name 'UPN' -Default '')
            $aad   = [string](Get-SafeRegValue -Path $p -Name 'AADTenantID' -Default '')
            $etype = Get-SafeRegValue -Path $p -Name 'EnrollmentType' -Default $null
            $state = Get-SafeRegValue -Path $p -Name 'EnrollmentState' -Default $null

            if (Test-IsCorporateMdmEnrollment -ProviderID $prov -DiscoveryUrl $disc -UPN $upn -AADTenantID $aad -EnrollmentType $etype) {
                $mdmEntries += [PSCustomObject]@{
                    EnrollmentId   = $sk.PSChildName
                    ProviderID     = $prov
                    DiscoveryUrl   = $disc
                    UPN            = $upn
                    AADTenantID    = $aad
                    EnrollmentType = $etype
                    State          = $state
                }
            }
        }
    }
    $cimMdm = @()
    if ($IsAdmin) {
        $rawCimMdm = @(Invoke-SafeCim -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernManagement_Enrollment01')
        $cimMdm = @($rawCimMdm | Where-Object {
            (-not [string]::IsNullOrWhiteSpace([string]$_.EntDMID)) -or
            (-not [string]::IsNullOrWhiteSpace([string]$_.UPN))
        })
    }
    $ppkgFiles = @()
    $provDir = Join-Path $env:ProgramData 'Microsoft\Provisioning'
    if (Test-Path -LiteralPath $provDir) {
        $ppkgFiles = @(Get-ChildItem -LiteralPath $provDir -Filter '*.ppkg' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(AMD|Intel|Microsoft)\.' } |
            Select-Object -ExpandProperty Name)
    }
    $mdmDetected = ($mdmEntries.Count -gt 0) -or ($cimMdm.Count -gt 0) -or ($ppkgFiles.Count -gt 0) -or (-not [string]::IsNullOrWhiteSpace($dsregObj.MdmUrl))
    $mdmStatus = if ($mdmDetected) { 'FAIL' } else { 'PASS' }

    # 4. Absolute Persistence / Computrace + Vendor BIOS WMI
    $compOsEvidence = @()
    $svcNames = @('rpcnet', 'rpcnetp', 'ctesdursvc', 'AbsoluteAgent', 'AbsolutePersistence')
    try {
        $svcs = Get-Service -ErrorAction SilentlyContinue
        foreach ($s in $svcs) {
            if (($svcNames -contains $s.Name) -or ($s.DisplayName -match 'Computrace|Absolute Persistence|Absolute Agent')) {
                $compOsEvidence += ("Service {0} ({1}) [{2}]" -f $s.Name, $s.DisplayName, $s.Status)
            }
        }
    } catch {
        # Ignore service enum issues
    }
    $compFiles = @(
        (Join-Path $env:SystemRoot 'System32\rpcnet.exe'),
        (Join-Path $env:SystemRoot 'System32\rpcnetp.exe'),
        (Join-Path $env:SystemRoot 'System32\rpcnet.dll'),
        (Join-Path $env:SystemRoot 'System32\rpcnetp.dll'),
        (Join-Path $env:SystemRoot 'SysWOW64\rpcnet.exe'),
        (Join-Path $env:SystemRoot 'SysWOW64\rpcnetp.exe')
    )
    foreach ($f in $compFiles) {
        if (Test-Path -LiteralPath $f) { $compOsEvidence += ("File: {0}" -f $f) }
    }
    foreach ($rk in @('HKLM:\SOFTWARE\Absolute Software', 'HKLM:\SOFTWARE\WOW6432Node\Absolute Software')) {
        if (Test-Path -LiteralPath $rk) {
            try {
                $subKeys = @(Get-ChildItem -LiteralPath $rk -Recurse -ErrorAction SilentlyContinue)
                $activeAgentKey = $false
                foreach ($sk in $subKeys) {
                    $props = Get-ItemProperty -LiteralPath $sk.PSPath -ErrorAction SilentlyContinue
                    if ($null -ne $props) {
                        $hasParams = ($props.PSObject.Properties.Name -contains 'Params') -and (-not [string]::IsNullOrWhiteSpace([string]$props.Params))
                        $hasActiveState = ($props.PSObject.Properties.Name -contains 'State') -and ($props.State -eq 1)
                        $hasAgentMeta = ($props.PSObject.Properties.Name | Where-Object { $_ -in @('ServerURL', 'AgentId', 'AccountId', 'ESN') }).Count -gt 0
                        if ($hasParams -or $hasActiveState -or $hasAgentMeta) {
                            $activeAgentKey = $true
                            break
                        }
                    }
                }
                if ($activeAgentKey) {
                    $compOsEvidence += ("Active Registry: {0}" -f $rk)
                }
            } catch {
                # Ignore inactive stub
            }
        }
    }

    # Vendor BIOS WMI
    $biosVendorWmiChecked = $false
    $biosVendorUsed = 'None'
    $biosPasswordSet = $false
    $biosComputraceActive = $false
    $biosSettingsSummary = @()

    # HP
    $hpSettings = Invoke-SafeCim -Namespace 'root\HP\InstrumentedBIOS' -ClassName 'HP_BIOSSetting'
    if ($hpSettings.Count -gt 0) {
        $biosVendorWmiChecked = $true
        $biosVendorUsed = 'HP (root\HP\InstrumentedBIOS)'
        foreach ($item in $hpSettings) {
            $n = [string]$item.Name
            $v = [string]$item.Value
            if ($n -match 'Absolute|Computrace|Setup Password|BIOS Administrator|Sure Admin|Sure Start|Sure Recover|Ownership Tag|Lock BIOS') {
                $biosSettingsSummary += ("{0} = {1}" -f $n, $v)
                if ($n -match 'Absolute|Computrace' -and $v -match 'Enable|Active|Permanent') {
                    $biosComputraceActive = $true
                }
                if ($n -match 'Password|Lock BIOS' -and $v -match 'Enable|Set|True|Yes') {
                    $biosPasswordSet = $true
                }
            }
        }
        $hpPwd = Invoke-SafeCim -Namespace 'root\HP\InstrumentedBIOS' -ClassName 'HP_BIOSPassword'
        foreach ($pItem in $hpPwd) {
            if ($pItem.IsSet -eq $true -or $pItem.IsSet -eq 1) {
                $biosPasswordSet = $true
                $biosSettingsSummary += ("HP_BIOSPassword ({0}): Set" -f $pItem.Name)
            }
        }
    }

    # Lenovo
    if (-not $biosVendorWmiChecked) {
        $lenovoSettings = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'Lenovo_BiosSetting'
        if ($lenovoSettings.Count -gt 0) {
            $biosVendorWmiChecked = $true
            $biosVendorUsed = 'Lenovo (root\wmi)'
            foreach ($item in $lenovoSettings) {
                $cs = [string]$item.CurrentSetting
                if ($cs -match 'Computrace|Absolute|Supervisor|Password|SecurityChip') {
                    $biosSettingsSummary += $cs
                    if ($cs -match '(Computrace|Absolute).*(Enable|Active|Permanent)') {
                        $biosComputraceActive = $true
                    }
                }
            }
            $lenovoPwd = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'Lenovo_BiosPasswordSettings'
            foreach ($lp in $lenovoPwd) {
                $ps = [int]$lp.PasswordState
                if ($ps -ne 0) {
                    $biosPasswordSet = $true
                    $biosSettingsSummary += ("Lenovo PasswordState bitmask = {0}" -f $ps)
                } else {
                    $biosSettingsSummary += 'Lenovo PasswordState = 0 (None Set)'
                }
            }
        }
    }

    # Dell
    if (-not $biosVendorWmiChecked) {
        $dellSettings = Invoke-SafeCim -Namespace 'root\dcim\sysman' -ClassName 'DCIM_BIOSEnumeration'
        if ($dellSettings.Count -gt 0) {
            $biosVendorWmiChecked = $true
            $biosVendorUsed = 'Dell (root\dcim\sysman)'
            foreach ($item in $dellSettings) {
                $an = [string]$item.AttributeName
                $cv = ($item.CurrentValue -join ',')
                if ($an -match 'Computrace|Absolute|AdminPwd|SysPwd|AdminSetupLockout') {
                    $biosSettingsSummary += ("{0} = {1}" -f $an, $cv)
                    if ($an -match 'Computrace|Absolute' -and $cv -match 'Enable|Activate|Permanent') {
                        $biosComputraceActive = $true
                    }
                    if ($an -match 'AdminPwd|SysPwd|AdminSetupLockout' -and $cv -match 'Set|True|Enable|Yes') {
                        $biosPasswordSet = $true
                    }
                }
            }
        }
    }

    $computraceStatus = if ($compOsEvidence.Count -gt 0 -or $biosComputraceActive) {
        'FAIL'
    } elseif ($biosVendorWmiChecked) {
        'PASS'
    } else {
        'UNAVAILABLE'
    }
    $biosPwdStatus = if ($biosPasswordSet) {
        'FAIL'
    } elseif ($biosVendorWmiChecked) {
        'PASS'
    } else {
        'UNAVAILABLE'
    }

    # 5. BitLocker / Device Encryption
    $bitlockerVolumes = @()
    $bitlockerLockedOrOn = $false
    $bitlockerChecked = $false
    if ($IsAdmin) {
        try {
            if (Get-Command -Name 'Get-BitLockerVolume' -ErrorAction SilentlyContinue) {
                $blv = @(Get-BitLockerVolume -ErrorAction Stop 2>$null)
                $bitlockerChecked = $true
                foreach ($v in $blv) {
                    $prot = [string]$v.ProtectionStatus
                    if ($prot -eq 'On' -or [string]$v.LockStatus -eq 'Locked') {
                        $bitlockerLockedOrOn = $true
                    }
                    $bitlockerVolumes += [PSCustomObject]@{
                        MountPoint           = [string]$v.MountPoint
                        VolumeStatus         = [string]$v.VolumeStatus
                        ProtectionStatus     = $prot
                        LockStatus           = [string]$v.LockStatus
                        EncryptionPercentage = $v.EncryptionPercentage
                    }
                }
            }
        } catch {}
        if (-not $bitlockerChecked) {
            $encVols = Invoke-SafeCim -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName 'Win32_EncryptableVolume'
            if ($encVols.Count -gt 0) {
                $bitlockerChecked = $true
                foreach ($ev in $encVols) {
                    $protTxt = switch ($ev.ProtectionStatus) {
                        0 { 'Off' }
                        1 { 'On' }
                        default { 'Unknown' }
                    }
                    if ($ev.ProtectionStatus -eq 1) { $bitlockerLockedOrOn = $true }
                    $bitlockerVolumes += [PSCustomObject]@{
                        MountPoint           = [string]$ev.DriveLetter
                        VolumeStatus         = [string]$ev.ConversionStatus
                        ProtectionStatus     = $protTxt
                        LockStatus           = 'Unknown'
                        EncryptionPercentage = $null
                    }
                }
            }
        }
    } else {
        # Fast non-admin BitLocker check via Shell.Application ExtendedProperty
        try {
            $shell = New-Object -ComObject Shell.Application
            $fixedDrives = @(Get-CimInstance -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
            foreach ($fd in $fixedDrives) {
                $dl = [string]$fd.DeviceID
                $folder = $shell.NameSpace("$dl\")
                if ($folder -and $folder.Self) {
                    $blProp = $folder.Self.ExtendedProperty('System.Volume.BitLockerProtection')
                    if ($null -ne $blProp) {
                        $bitlockerChecked = $true
                        $pCode = [int]$blProp
                        $protTxt = switch ($pCode) {
                            1 { 'On' }
                            3 { 'Encrypting' }
                            5 { 'Suspended' }
                            6 { 'Locked' }
                            default { 'Off' }
                        }
                        if ($pCode -in @(1, 3, 6)) { $bitlockerLockedOrOn = $true }
                        $bitlockerVolumes += [PSCustomObject]@{
                            MountPoint           = $dl
                            VolumeStatus         = "ShellCode-$pCode"
                            ProtectionStatus     = $protTxt
                            LockStatus           = if ($pCode -eq 6) { 'Locked' } else { 'Unlocked' }
                            EncryptionPercentage = $null
                        }
                    }
                }
            }
        } catch {}
    }
    $bitlockerStatus = if (-not $bitlockerChecked) {
        'UNAVAILABLE'
    } elseif ($bitlockerLockedOrOn) {
        'WARN'
    } else {
        'PASS'
    }

    # 6. Secure Boot, TPM & Intel AMT / vPro
    $secureBoot = 'UNAVAILABLE'
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        $secureBoot = if ($sb) { 'Enabled' } else { 'Disabled' }
    } catch {
        $secureBoot = 'UNAVAILABLE'
    }

    $tpmInfo = [PSCustomObject]@{
        Available    = $false
        TpmPresent   = $false
        TpmReady     = $false
        TpmEnabled   = $false
        LockoutCount = $null
    }
    try {
        if (Get-Command -Name 'Get-Tpm' -ErrorAction SilentlyContinue) {
            $t = Get-Tpm -ErrorAction Stop
            if ($t) {
                $tpmInfo = [PSCustomObject]@{
                    Available    = $true
                    TpmPresent   = [bool]$t.TpmPresent
                    TpmReady     = [bool]$t.TpmReady
                    TpmEnabled   = [bool]$t.TpmEnabled
                    LockoutCount = $t.LockoutCount
                }
            }
        }
    } catch {
        # Access denied if non-admin
    }

    $amtDetected = $false
    $amtEvidence = @()
    try {
        $amtSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('LMS', 'jhi_service') }
        foreach ($s in $amtSvcs) {
            $amtDetected = $true
            $amtEvidence += ("Service {0} [{1}]" -f $s.Name, $s.Status)
        }
        $pnpAmt = Invoke-SafeCim -ClassName 'Win32_PnPEntity' | Where-Object { $_.Name -match 'Active Management Technology|\bSOL\b' }
        foreach ($pa in $pnpAmt) {
            $amtDetected = $true
            $amtEvidence += ("Device: {0}" -f $pa.Name)
        }
    } catch {
        # Ignore
    }

    # 7. Corporate RMM / EDR Agents
    $rmmSignatures = @(
        @{ Pattern = '^CcmExec$'; Label = 'Microsoft SCCM / MECM' },
        @{ Pattern = '^CSFalconService$|^CSFalconContainer$'; Label = 'CrowdStrike Falcon' },
        @{ Pattern = '^SentinelAgent$|^SentinelOne'; Label = 'SentinelOne EDR' },
        @{ Pattern = '^NinjaRMMAgent'; Label = 'NinjaRMM' },
        @{ Pattern = '^ScreenConnect'; Label = 'ConnectWise ScreenConnect' },
        @{ Pattern = '^LTService$|^LTSvcMon$'; Label = 'ConnectWise Automate' },
        @{ Pattern = '^TaniumClient$'; Label = 'Tanium Client' },
        @{ Pattern = '^cbdefense$|^RepMgr$'; Label = 'VMware Carbon Black' },
        @{ Pattern = '^cyserver$|^cyvera'; Label = 'Palo Alto Cortex XDR' },
        @{ Pattern = '^HuntressAgent$'; Label = 'Huntress EDR' },
        @{ Pattern = '^CagService$'; Label = 'Datto RMM' },
        @{ Pattern = '^AteraAgent$'; Label = 'Atera RMM' },
        @{ Pattern = '^Pulseway$'; Label = 'Pulseway RMM' },
        @{ Pattern = '^MeshAgent$'; Label = 'MeshCentral Agent' },
        @{ Pattern = '^UEMS|^dcagentservice$'; Label = 'ManageEngine Endpoint Central' },
        @{ Pattern = '^Sophos'; Label = 'Sophos Endpoint' },
        @{ Pattern = '^FrzState2k$'; Label = 'Faronics Deep Freeze' }
    )
    $rmmHits = @()
    $allProcNames = @()
    try { $allProcNames = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique) } catch {}
    $allSvcList = @()
    try { $allSvcList = @(Get-Service -ErrorAction SilentlyContinue) } catch {}

    foreach ($sig in $rmmSignatures) {
        $matched = $false
        foreach ($svc in $allSvcList) {
            if ($svc.Name -match $sig.Pattern) {
                $rmmHits += ("{0} (Service: {1} [{2}])" -f $sig.Label, $svc.Name, $svc.Status)
                $matched = $true
                break
            }
        }
        if (-not $matched) {
            foreach ($pn in $allProcNames) {
                if ($pn -match $sig.Pattern) {
                    $rmmHits += ("{0} (Process: {1})" -f $sig.Label, $pn)
                    break
                }
            }
        }
    }
    $rmmStatus = if ($rmmHits.Count -gt 0) { 'FAIL' } else { 'PASS' }

    # 8. Windows Activation & OEM Firmware Key
    $sls = Invoke-SafeCim -ClassName 'SoftwareLicensingService' | Select-Object -First 1
    $hasOemKey = $false
    $maskedOemKey = ''
    if ($sls -and -not [string]::IsNullOrWhiteSpace($sls.OA3xOriginalProductKey)) {
        $hasOemKey = $true
        $rawKey = [string]$sls.OA3xOriginalProductKey
        if ($rawKey.Length -ge 5) {
            $maskedOemKey = 'XXXXX-XXXXX-XXXXX-XXXXX-' + $rawKey.Substring($rawKey.Length - 5)
        } else {
            $maskedOemKey = 'Present'
        }
    }

    $winLicStatus = 'Unknown'
    $winLicChannel = 'Unknown'
    $winLicDesc = ''
    $slp = Invoke-SafeCim -ClassName 'SoftwareLicensingProduct' -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
    if ($slp) {
        $winLicDesc = [string]$slp.Description
        $winLicStatus = switch ([int]$slp.LicenseStatus) {
            0 { 'Unlicensed' }
            1 { 'Licensed' }
            2 { 'OOBGrace' }
            3 { 'OOTGrace' }
            4 { 'NonGenuineGrace' }
            5 { 'Notification' }
            6 { 'ExtendedGrace' }
            default { "Status-$($slp.LicenseStatus)" }
        }
        if ($winLicDesc -match 'VOLUME_KMSCLIENT|KMS') { $winLicChannel = 'VOLUME_KMSCLIENT' }
        elseif ($winLicDesc -match 'VOLUME_MAK') { $winLicChannel = 'VOLUME_MAK' }
        elseif ($winLicDesc -match 'OEM') { $winLicChannel = 'OEM' }
        elseif ($winLicDesc -match 'RETAIL') { $winLicChannel = 'RETAIL' }
        else { $winLicChannel = $winLicDesc }
    } else {
        $winLicStatus = 'Unlicensed'
    }

    $licenseCheckStatus = if ($winLicStatus -ne 'Licensed' -or $winLicChannel -eq 'VOLUME_KMSCLIENT') { 'WARN' } else { 'PASS' }

    $domainJoinStatus = if ($dsregObj.AzureAdJoined -or $dsregObj.EnterpriseJoined -or $dsregObj.DomainJoined) {
        'FAIL'
    } elseif ($dsregObj.WorkplaceJoined) {
        'WARN'
    } elseif ($dsregObj.Available) {
        'PASS'
    } else {
        'UNAVAILABLE'
    }

    $anyConfirmedLock = (
        $autopilotAssigned -or
        $dsregObj.AzureAdJoined -or
        $dsregObj.EnterpriseJoined -or
        $dsregObj.DomainJoined -or
        $mdmDetected -or
        ($compOsEvidence.Count -gt 0) -or
        $biosComputraceActive -or
        $biosPasswordSet -or
        ($rmmHits.Count -gt 0)
    )

    return [PSCustomObject]@{
        ConfirmedCorporateLock = [bool]$anyConfirmedLock
        IsAdminSession         = [bool]$IsAdmin
        Dsreg                  = $dsregObj
        DomainJoinStatus       = $domainJoinStatus
        Autopilot              = [PSCustomObject]@{
            Status                = $autopilotStatus
            Assigned              = $autopilotAssigned
            TenantDomain          = $apTenantDomain
            TenantId              = $apTenantId
            Evidence              = @($autopilotEvidence)
            HardwareHashAvailable = $hwHashPresent
            HardwareHashSummary   = $hwHashSummary
            Advisory              = $autopilotAdvisory
        }
        Mdm                    = [PSCustomObject]@{
            Status       = $mdmStatus
            Detected     = $mdmDetected
            Entries      = @($mdmEntries)
            PpkgFiles    = @($ppkgFiles)
            CimCount     = $cimMdm.Count
        }
        Computrace             = [PSCustomObject]@{
            Status           = $computraceStatus
            OsEvidence       = @($compOsEvidence)
            BiosActive       = $biosComputraceActive
            BiosWmiChecked   = $biosVendorWmiChecked
            BiosVendor       = $biosVendorUsed
            BiosSettings     = @($biosSettingsSummary)
        }
        BiosSecurity           = [PSCustomObject]@{
            Status         = $biosPwdStatus
            PasswordSet    = $biosPasswordSet
            WmiChecked     = $biosVendorWmiChecked
            VendorProvider = $biosVendorUsed
            SecureBoot     = $secureBoot
            Tpm            = $tpmInfo
            IntelAmtActive = $amtDetected
            IntelAmtDetail = @($amtEvidence)
        }
        BitLocker              = [PSCustomObject]@{
            Status  = $bitlockerStatus
            Checked = $bitlockerChecked
            Active  = $bitlockerLockedOrOn
            Volumes = @($bitlockerVolumes)
        }
        RmmEdr                 = [PSCustomObject]@{
            Status     = $rmmStatus
            Detected   = ($rmmHits.Count -gt 0)
            Findings   = @($rmmHits)
        }
        Activation             = [PSCustomObject]@{
            Status            = $licenseCheckStatus
            LicenseStatus     = $winLicStatus
            Channel           = $winLicChannel
            Description       = $winLicDesc
            HasOemFirmwareKey = $hasOemKey
            MaskedOemKey      = $maskedOemKey
        }
    }
}
