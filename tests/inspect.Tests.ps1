$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$builtScript = Join-Path $repoRoot 'inspect.ps1'

$env:LAPTOP_INSPECT_IMPORT_ONLY = '1'
try {
    . $builtScript

    Describe 'Build & Encoding Integrity' {
        It 'inspect.ps1 exists and contains 100% pure 7-bit ASCII bytes' {
            Test-Path -LiteralPath $builtScript | Should Be $true
            $bytes = [System.IO.File]::ReadAllBytes($builtScript)
            $bad = 0
            foreach ($b in $bytes) {
                if (-not ($b -eq 9 -or $b -eq 10 -or $b -eq 13 -or ($b -ge 32 -and $b -le 126))) { $bad++ }
            }
            $bad | Should Be 0
        }

        It 'inspect.ps1 parses with zero PowerShell AST syntax errors' {
            $tokens = $null
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($builtScript, [ref]$tokens, [ref]$errs)
            $errs.Count | Should Be 0
        }
    }

    Describe 'Parse-DsregcmdOutput' {
        It 'Detects Corporate AzureAD-joined machine with tenant and MDM URL' {
            $sample = @(
                'AzureAdJoined : YES',
                'EnterpriseJoined : NO',
                'DomainJoined : NO',
                'WorkplaceJoined : NO',
                'TenantName : Contoso Corp',
                'TenantId : 11111111-2222-3333-4444-555555555555',
                'MdmUrl : https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc'
            )
            $res = Parse-DsregcmdOutput -Lines $sample
            $res.Available | Should Be $true
            $res.AzureAdJoined | Should Be $true
            $res.DomainJoined | Should Be $false
            $res.TenantName | Should Be 'Contoso Corp'
            $res.MdmUrl | Should Match 'manage\.microsoft\.com'
        }

        It 'Detects On-Prem Active Directory DomainJoined machine' {
            $sample = @('AzureAdJoined : NO', 'DomainJoined : YES', 'WorkplaceJoined : NO')
            $res = Parse-DsregcmdOutput -Lines $sample
            $res.DomainJoined | Should Be $true
            $res.AzureAdJoined | Should Be $false
        }

        It 'Reports clean personal machine accurately' {
            $sample = @('AzureAdJoined : NO', 'EnterpriseJoined : NO', 'DomainJoined : NO', 'WorkplaceJoined : NO')
            $res = Parse-DsregcmdOutput -Lines $sample
            $res.AzureAdJoined | Should Be $false
            $res.DomainJoined | Should Be $false
            $res.WorkplaceJoined | Should Be $false
        }
    }

    Describe 'EDID Helpers' {
        It 'Decodes WmiMonitorID ASCII code arrays' {
            Decode-EdidManufacturer -Bytes @(65, 85, 79, 0) | Should Be 'AUO'
            Decode-EdidManufacturer -Bytes @(66, 79, 69, 0) | Should Be 'BOE'
            Decode-EdidString -Bytes @(66, 49, 52, 48, 72, 65, 78, 48, 52, 0) | Should Be 'B140HAN04'
        }

        It 'Decodes packed 2-byte EDID PNP IDs' {
            # LGD -> L=12(01100), G=7(00111), D=4(00100) => 0x30E4
            Decode-EdidManufacturer -Bytes @(0x30, 0xE4) | Should Be 'LGD'
        }
    }

    Describe 'Get-BuyerVerdict' {
        function New-MockReportData {
            return [PSCustomObject]@{
                System = [PSCustomObject]@{ IsLaptop = $true; Model = 'TestBook'; SerialNumber = 'SN123' }
                CorporateLock = [PSCustomObject]@{
                    ConfirmedCorporateLock = $false
                    IsAdminSession = $true
                    Autopilot = [PSCustomObject]@{ Assigned = $false; TenantDomain = ''; Advisory = 'OOBE check note' }
                    Dsreg = [PSCustomObject]@{ AzureAdJoined = $false; EnterpriseJoined = $false; DomainJoined = $false; WorkplaceJoined = $false; TenantName = '' }
                    Mdm = [PSCustomObject]@{ Detected = $false }
                    Computrace = [PSCustomObject]@{ OsEvidence = @(); BiosActive = $false }
                    BiosSecurity = [PSCustomObject]@{ PasswordSet = $false; WmiChecked = $true }
                    RmmEdr = [PSCustomObject]@{ Detected = $false; Findings = @() }
                    BitLocker = [PSCustomObject]@{ Active = $false }
                    Activation = [PSCustomObject]@{ LicenseStatus = 'Licensed'; Channel = 'OEM' }
                }
                Cpu = [PSCustomObject]@{ StressSkipped = $false; VerificationPassed = $true; ThrottlingSuspected = $false; PeakTempC = 72; ThermalStatus = 'PASS' }
                Gpu = [PSCustomObject]@{ HasError = $false; Gpus = @([PSCustomObject]@{ Name = 'Intel Iris Xe'; ErrorCode = 0 }) }
                Ram = [PSCustomObject]@{ TotalSlots = 2; UsedSlots = 1; FreeSlots = 1; SolderedDetected = $false; PatternTest = [PSCustomObject]@{ Status = 'PASS' } }
                Storage = [PSCustomObject]@{ InternalUnhealthy = $false; InternalErrors = $false; HighWearDetected = $false; Disks = @() }
                Battery = [PSCustomObject]@{ BatteryCount = 1; OverallHealthPercent = 91; MaxCycleCount = 80; AcFlickerDetected = $false; VoltageDroopDetected = $false }
                Peripherals = [PSCustomObject]@{ DeviceErrors = @() }
            }
        }

        It 'Returns BUY and 100 score for clean laptop' {
            $d = New-MockReportData
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'BUY'
            $v.Score | Should Be 100
        }

        It 'Returns DO NOT BUY when Autopilot is assigned' {
            $d = New-MockReportData
            $d.CorporateLock.Autopilot.Assigned = $true
            $d.CorporateLock.Autopilot.TenantDomain = 'corp.com'
            $d.CorporateLock.ConfirmedCorporateLock = $true
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'DO NOT BUY'
            ($v.CriticalFlags -join ' ') | Should Match 'Autopilot'
        }

        It 'Returns DO NOT BUY when AzureAdJoined is true' {
            $d = New-MockReportData
            $d.CorporateLock.Dsreg.AzureAdJoined = $true
            $d.CorporateLock.ConfirmedCorporateLock = $true
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'DO NOT BUY'
        }

        It 'Returns DO NOT BUY when Computrace is active' {
            $d = New-MockReportData
            $d.CorporateLock.Computrace.BiosActive = $true
            $d.CorporateLock.ConfirmedCorporateLock = $true
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'DO NOT BUY'
        }

        It 'Returns DO NOT BUY when CPU verification checksum fails' {
            $d = New-MockReportData
            $d.Cpu.VerificationPassed = $false
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'DO NOT BUY'
        }

        It 'Returns DO NOT BUY when GPU reports Code 43 error' {
            $d = New-MockReportData
            $d.Gpu.HasError = $true
            $d.Gpu.Gpus = @([PSCustomObject]@{ Name = 'RTX 3060'; ErrorCode = 43 })
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'DO NOT BUY'
        }

        It 'Returns CAUTION when BitLocker is active' {
            $d = New-MockReportData
            $d.CorporateLock.BitLocker.Active = $true
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'CAUTION'
            $v.Score | Should Be 85
        }

        It 'Returns CAUTION when battery health is 62 percent' {
            $d = New-MockReportData
            $d.Battery.OverallHealthPercent = 62
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'CAUTION'
            $v.Score | Should Be 85
        }

        It 'Returns DO NOT BUY when laptop chassis has 0 batteries' {
            $d = New-MockReportData
            $d.Battery.BatteryCount = 0
            $v = Get-BuyerVerdict -ReportData $d
            $v.Verdict | Should Be 'DO NOT BUY'
        }
    }

    Describe 'Build-ReportHtml' {
        It 'Escapes closing script tags and preserves literal dollar strings' {
            $mock = [PSCustomObject]@{
                Meta = [PSCustomObject]@{ ToolVersion = '1.0.0'; GeneratedAt = '2026-11-20'; DurationSeconds = 1.2 }
                System = [PSCustomObject]@{ Manufacturer = 'Acme'; Model = 'Price $100 $& </script>'; SerialNumber = 'S1' }
                Scoring = [PSCustomObject]@{ Verdict = 'BUY'; Score = 100; Deductions = @(); CriticalFlags = @(); Warnings = @(); Advisories = @() }
            }
            $html = Build-ReportHtml -ReportData $mock -ManualStateJson '{"notes":"Paid $100 </script>"}' -ServerMode $false
            ($html -match '</script>","') | Should Be $false
            $html | Should Match '<\\/script>'
            $html | Should Match 'window\.__LI_SERVER__ = false;'
            $dataMatch = [regex]::Match($html, '<script id="li-report-data" type="application/json">(.*?)</script>')
            $dataMatch.Success | Should Be $true
            $parsed = ($dataMatch.Groups[1].Value -replace '<\\/script', '</script') | ConvertFrom-Json
            $parsed.System.Model | Should Be 'Price $100 $& </script>'
        }
    }

    Describe 'Localhost HttpListener Server Roundtrip' {
        It 'Serves GET /, GET /api/ports, persists POST /api/save to disk, and exits on POST /api/shutdown' {
            $port = Get-FreeLoopbackPort
            $tmpDir = Join-Path $env:TEMP ("li_pester_http_{0}" -f $PID)
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $reportPath = Join-Path $tmpDir 'LaptopReport_Test.html'
            $mockData = [PSCustomObject]@{
                Meta = [PSCustomObject]@{ ToolVersion = '1.0.0'; GeneratedAt = '2026-11-20'; DurationSeconds = 1.0 }
                System = [PSCustomObject]@{ Manufacturer = 'TestCo'; Model = 'TestLap'; SerialNumber = 'T001' }
                Scoring = [PSCustomObject]@{ Verdict = 'BUY'; Score = 100; Deductions = @(); CriticalFlags = @(); Warnings = @(); Advisories = @() }
            }
            Write-AtomicTextFile -Path $reportPath -Content (Build-ReportHtml -ReportData $mockData -ServerMode $false)

            $ps = [PowerShell]::Create()
            $scriptBlock = {
                param($BuiltPath, $DataObj, $OutHtml, $ListenPort)
                $env:LAPTOP_INSPECT_IMPORT_ONLY = '1'
                . $BuiltPath
                Start-ReportHttpServer -ReportData $DataObj -ReportPath $OutHtml -Port $ListenPort -NoLaunchBrowser -MaxSeconds 20
            }
            [void]$ps.AddScript($scriptBlock).AddArgument($builtScript).AddArgument($mockData).AddArgument($reportPath).AddArgument($port)
            $async = $ps.BeginInvoke()

            try {
                $baseUrl = "http://127.0.0.1:$port"
                $ready = $false
                for ($w = 0; $w -lt 25; $w++) {
                    try {
                        $r = Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing -TimeoutSec 2
                        if ($r.StatusCode -eq 200) {
                            $ready = $true
                            $r.Content | Should Match 'window\.__LI_SERVER__ = true;'
                            break
                        }
                    } catch {
                        Start-Sleep -Milliseconds 150
                    }
                }
                $ready | Should Be $true

                $portsResp = Invoke-RestMethod -Uri "$baseUrl/api/ports" -Method Get -TimeoutSec 15
                $portsResp.Timestamp | Should Not BeNullOrEmpty

                $savePayload = '{"results":{"keyboard":"PASS"},"sellerName":"PesterSeller"}'
                $saveResp = Invoke-RestMethod -Uri "$baseUrl/api/save" -Method Post -ContentType 'application/json' -Body $savePayload -TimeoutSec 10
                $saveResp.ok | Should Be $true

                $diskHtml = Get-Content -LiteralPath $reportPath -Raw
                $diskHtml | Should Match 'PesterSeller'
                $diskHtml | Should Match 'window\.__LI_SERVER__ = false;'

                # Invalid Winget ID must return HTTP 400
                $badStatus = 0
                try {
                    Invoke-RestMethod -Uri "$baseUrl/api/install" -Method Post -ContentType 'application/json' -Body '{"ids":["chrome; calc"]}' -TimeoutSec 10 | Out-Null
                } catch {
                    if ($_.Exception.Response) { $badStatus = [int]$_.Exception.Response.StatusCode }
                }
                $badStatus | Should Be 400

                # Valid DryRun batch returns HTTP 202 and completes asynchronously
                $instStart = Invoke-RestMethod -Uri "$baseUrl/api/install" -Method Post -ContentType 'application/json' -Body '{"ids":["chrome","7zip"],"dryRun":true}' -TimeoutSec 10
                $instStart.ok | Should Be $true
                $instStart.total | Should Be 2

                $finalSt = $null
                for ($poll = 0; $poll -lt 30; $poll++) {
                    Start-Sleep -Milliseconds 150
                    $st = Invoke-RestMethod -Uri "$baseUrl/api/install/status" -Method Get -TimeoutSec 10
                    if (-not $st.Running -and $st.State -eq 'Completed') {
                        $finalSt = $st
                        break
                    }
                }
                $finalSt | Should Not BeNullOrEmpty
                $finalSt.Results.Count | Should Be 2
                $finalSt.Results[0].Status | Should Be 'DryRun OK'
                $finalSt.Results[1].Status | Should Be 'DryRun OK'

                $shutResp = Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 10
                $shutResp.ok | Should Be $true

                [void]$async.AsyncWaitHandle.WaitOne(5000)
                $ps.EndInvoke($async) | Out-Null
            } finally {
                $ps.Dispose()
                if (Test-Path -LiteralPath $tmpDir) {
                    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Battery test API returns Idle status and rejects invalid parameters with HTTP 400' {
            $port = Get-FreeLoopbackPort
            $tmpDir = Join-Path $env:TEMP ("li_pester_bathttp_{0}" -f $PID)
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            $reportPath = Join-Path $tmpDir 'LaptopReport_Bat.html'
            $mockData = [PSCustomObject]@{
                Meta = [PSCustomObject]@{ ToolVersion = '1.3.0'; GeneratedAt = '2026-11-22'; DurationSeconds = 1.0 }
                System = [PSCustomObject]@{ Manufacturer = 'TestCo'; Model = 'TestLap'; SerialNumber = 'B001' }
                Scoring = [PSCustomObject]@{ Verdict = 'BUY'; Score = 100; Deductions = @(); CriticalFlags = @(); Warnings = @(); Advisories = @() }
            }
            Write-AtomicTextFile -Path $reportPath -Content (Build-ReportHtml -ReportData $mockData -ServerMode $false)

            $ps = [PowerShell]::Create()
            [void]$ps.AddScript({
                param($BuiltPath, $DataObj, $OutHtml, $ListenPort)
                $env:LAPTOP_INSPECT_IMPORT_ONLY = '1'
                . $BuiltPath
                Start-ReportHttpServer -ReportData $DataObj -ReportPath $OutHtml -Port $ListenPort -NoLaunchBrowser -MaxSeconds 15
            }).AddArgument($builtScript).AddArgument($mockData).AddArgument($reportPath).AddArgument($port)
            $async = $ps.BeginInvoke()

            try {
                $baseUrl = "http://127.0.0.1:$port"
                $ready = $false
                for ($w = 0; $w -lt 25; $w++) {
                    try {
                        $bSt = Invoke-RestMethod -Uri "$baseUrl/api/battery-test/status" -Method Get -TimeoutSec 5
                        if ($bSt.State -eq 'Idle') { $ready = $true; break }
                    } catch {
                        Start-Sleep -Milliseconds 150
                    }
                }
                $ready | Should Be $true

                $badCode = 0
                try {
                    Invoke-RestMethod -Uri "$baseUrl/api/battery-test/start" -Method Post -ContentType 'application/json' -Body '{"minutes":999,"mode":"everyday","cutoffPct":10}' -TimeoutSec 5 | Out-Null
                } catch {
                    if ($_.Exception.Response) { $badCode = [int]$_.Exception.Response.StatusCode }
                }
                $badCode | Should Be 400

                Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 5 | Out-Null
                [void]$async.AsyncWaitHandle.WaitOne(5000)
                $ps.EndInvoke($async) | Out-Null
            } finally {
                $ps.Dispose()
                if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    Describe 'Silent App Installer (65-installer.ps1)' {
        It 'Catalog contains >= 35 apps with unique keys and safe Winget IDs' {
            $cat = Get-AppCatalog
            ($cat.Count -ge 35) | Should Be $true
            $keys = @($cat | Select-Object -ExpandProperty Key -Unique)
            $keys.Count | Should Be $cat.Count
            foreach ($item in $cat) {
                Test-SafeWingetId -Id $item.WingetId | Should Be $true
            }
        }

        It 'Test-SafeWingetId accepts valid IDs and blocks shell/injection strings' {
            Test-SafeWingetId -Id 'Google.Chrome' | Should Be $true
            Test-SafeWingetId -Id 'Microsoft.VCRedist.2015+.x64' | Should Be $true
            Test-SafeWingetId -Id '9NKSQGP7F2NH' | Should Be $true
            Test-SafeWingetId -Id 'chrome; calc' | Should Be $false
            Test-SafeWingetId -Id 'foo|bar' | Should Be $false
            Test-SafeWingetId -Id '$(whoami)' | Should Be $false
            Test-SafeWingetId -Id '' | Should Be $false
        }

        It 'Resolve-InstallTargets resolves presets, mixed IDs, deduplicates, and rejects invalid IDs' {
            $res = Resolve-InstallTargets -Preset 'essentials' -KeysOrIds @('chrome', 'Mozilla.Thunderbird')
            $res.Count | Should Be 9
            @($res | Where-Object { $_.WingetId -eq 'Google.Chrome' }).Count | Should Be 1
            @($res | Where-Object { $_.WingetId -eq 'Mozilla.Thunderbird' }).Count | Should Be 1
            { Resolve-InstallTargets -KeysOrIds @('bad&id') } | Should Throw
        }

        It 'Build-WingetInstallArgs includes silent and zero-prompt agreement flags' {
            $args = Build-WingetInstallArgs -WingetId 'Google.Chrome' -Source 'winget'
            ($args -contains '--silent') | Should Be $true
            ($args -contains '--accept-package-agreements') | Should Be $true
            ($args -contains '--accept-source-agreements') | Should Be $true
            ($args -contains '--disable-interactivity') | Should Be $true
            ($args -contains '--exact') | Should Be $true
        }

        It 'ConvertTo-WingetInstallResult maps standard Winget exit codes accurately' {
            (ConvertTo-WingetInstallResult -ExitCode 0).Status | Should Be 'Installed'
            (ConvertTo-WingetInstallResult -ExitCode -1978335189).Status | Should Be 'Already Installed'
            (ConvertTo-WingetInstallResult -ExitCode 3010).Status | Should Be 'Installed (Reboot Needed)'
            $fail = ConvertTo-WingetInstallResult -ExitCode 5 -OutputLines @('Package failed')
            $fail.Success | Should Be $false
            $fail.Status | Should Match 'Failed \(Exit 5\)'
        }

        It 'Runs CLI -InstallPreset essentials -InstallOnly -DryRun end-to-end cleanly' {
            $prevImport = $env:LAPTOP_INSPECT_IMPORT_ONLY
            Remove-Item Env:\LAPTOP_INSPECT_IMPORT_ONLY -ErrorAction SilentlyContinue
            try {
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $builtScript -InstallPreset essentials -InstallOnly -DryRun -NoElevate
                $LASTEXITCODE | Should Be 0
                ($out -join "`n") | Should Match 'Google\.Chrome'
                ($out -join "`n") | Should Match '--accept-package-agreements'
            } finally {
                $env:LAPTOP_INSPECT_IMPORT_ONLY = $prevImport
            }
        }
    }

    Describe 'MDM Built-in False-Positive Guard (Test-IsCorporateMdmEnrollment)' {
        It 'Ignores built-in Windows 11 local/bridge authorities with no remote endpoint' {
            Test-IsCorporateMdmEnrollment -ProviderID 'WMI_Bridge_SCCM_Server' -EnrollmentType 12 | Should Be $false
            Test-IsCorporateMdmEnrollment -ProviderID 'Local Authority' -EnrollmentType 28 | Should Be $false
            Test-IsCorporateMdmEnrollment -ProviderID 'Deploy Authority' -EnrollmentType 30 | Should Be $false
            Test-IsCorporateMdmEnrollment -ProviderID 'Cloud Authority' -EnrollmentType 31 | Should Be $false
        }

        It 'Flags genuine Intune / corporate MDM enrollments' {
            Test-IsCorporateMdmEnrollment -ProviderID 'MS DM Server' -DiscoveryUrl 'https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc' -EnrollmentType 6 | Should Be $true
            Test-IsCorporateMdmEnrollment -ProviderID 'WMI_Bridge_SCCM_Server' -AADTenantID '11111111-2222-3333-4444-555555555555' | Should Be $true
            Test-IsCorporateMdmEnrollment -ProviderID 'WorkspaceONE' -EnrollmentType 6 | Should Be $true
        }
    }

    Describe 'TUI Helpers (75-tui.ps1)' {
        It 'Formats ASCII progress bars and padded lines cleanly' {
            Format-TuiBar -Percent 50 -Width 10 | Should Be '[#####.....]'
            Format-TuiBar -Percent 100 -Width 10 | Should Be '[##########]'
            (Format-TuiPad -Text 'ABC' -Width 6) | Should Be 'ABC   '
            (Format-TuiPad -Text 'ABCDEFGHIJ' -Width 7) | Should Be 'ABCD...'
        }
    }

    Describe 'Timed Battery Drain & Everyday Load (50-battery-power.ps1)' {
        It 'Computes linear drain summary and estimated 100-to-0 runtime cleanly' {
            $samples = @(
                [PSCustomObject]@{ ElapsedSec = 0;   ChargePct = 90; RemainingMWh = 45000; DischargeMw = 15000; VoltageMv = 11400 },
                [PSCustomObject]@{ ElapsedSec = 300; ChargePct = 88; RemainingMWh = 44000; DischargeMw = 14000; VoltageMv = 11350 },
                [PSCustomObject]@{ ElapsedSec = 600; ChargePct = 87; RemainingMWh = 43500; DischargeMw = 16000; VoltageMv = 11300 },
                [PSCustomObject]@{ ElapsedSec = 900; ChargePct = 85; RemainingMWh = 42500; DischargeMw = 15000; VoltageMv = 11250 }
            )
            $sum = Measure-BatteryDrainSummary -Samples $samples -TotalCapacityMWh 50000 -LoadMode 'everyday' -StopReason 'Completed (15 min timer)'
            $sum.Status | Should Be 'PASS'
            $sum.StartPct | Should Be 90
            $sum.EndPct | Should Be 85
            $sum.DropPct | Should Be 5
            $sum.AvgDischargeWatts | Should Be 15
            $sum.SuddenDropDetected | Should Be $false
            $sum.EstimatedRuntimeFrom100Minutes | Should Be 200
        }

        It 'Detects sudden dead-cell drop >=5% within <=30s and flags FAIL' {
            $samples = @(
                [PSCustomObject]@{ ElapsedSec = 0;  ChargePct = 60; RemainingMWh = 30000; DischargeMw = 15000; VoltageMv = 11200 },
                [PSCustomObject]@{ ElapsedSec = 10; ChargePct = 42; RemainingMWh = 21000; DischargeMw = 15000; VoltageMv = 10900 }
            )
            $sum = Measure-BatteryDrainSummary -Samples $samples -LoadMode 'everyday'
            $sum.SuddenDropDetected | Should Be $true
            $sum.Status | Should Be 'FAIL'
            $sum.SuddenDropDetail | Should Match '60% -> 42%'
        }

        It 'Detects >15% voltage sag and flags WARN' {
            $samples = @(
                [PSCustomObject]@{ ElapsedSec = 0;  ChargePct = 80; RemainingMWh = 40000; DischargeMw = 12000; VoltageMv = 12000 },
                [PSCustomObject]@{ ElapsedSec = 60; ChargePct = 79; RemainingMWh = 39500; DischargeMw = 12000; VoltageMv = 9800 }
            )
            $sum = Measure-BatteryDrainSummary -Samples $samples -LoadMode 'everyday'
            ($sum.VoltageSagPct -gt 15.0) | Should Be $true
            $sum.Status | Should Be 'WARN'
        }

        It 'Scores sudden drop and unfinished crash checkpoint as DO NOT BUY' {
            $mock = [PSCustomObject]@{
                System = [PSCustomObject]@{ IsLaptop = $true }
                CorporateLock = $null
                Cpu = $null
                Gpu = $null
                Ram = $null
                Storage = $null
                Battery = [PSCustomObject]@{ BatteryCount = 1; OverallHealthPercent = 88; MaxCycleCount = 50; AcFlickerDetected = $false; VoltageDroopDetected = $false }
                PreviousBatteryCrash = [PSCustomObject]@{ LastChargePct = 45; ElapsedSeconds = 420; LoadMode = 'everyday' }
                BatteryDrain = [PSCustomObject]@{ SuddenDropDetected = $true; SuddenDropDetail = '45% -> 12% in 5s'; VoltageSagPct = 5.0; LoadMode = 'everyday'; EstimatedRuntimeFrom100Minutes = 120 }
                Peripherals = $null
            }
            $v = Get-BuyerVerdict -ReportData $mock
            $v.Verdict | Should Be 'DO NOT BUY'
            ($v.CriticalFlags -join ' ') | Should Match 'Unfinished battery drain'
            ($v.CriticalFlags -join ' ') | Should Match 'Sudden battery charge collapse'
        }

        It 'Runs Everyday Use burst workload cleanly without error and cleans temp IO file' {
            $buf = New-Object byte[] (32MB)
            $ioPath = Join-Path $env:TEMP ("li_pester_io_{0}.tmp" -f $PID)
            try {
                Invoke-EverydayTickWorkload -WorkBuffer $buf -TickIndex 0 -IoTempPath $ioPath
                Test-Path -LiteralPath $ioPath | Should Be $true
            } finally {
                if (Test-Path -LiteralPath $ioPath) { Remove-Item -LiteralPath $ioPath -Force -ErrorAction SilentlyContinue }
                $buf = $null
                [GC]::Collect()
            }
        }
    }
} finally {
    Remove-Item Env:\LAPTOP_INSPECT_IMPORT_ONLY -ErrorAction SilentlyContinue
}
