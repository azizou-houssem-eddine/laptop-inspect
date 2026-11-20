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

                $portsResp = Invoke-RestMethod -Uri "$baseUrl/api/ports" -Method Get -TimeoutSec 3
                $portsResp.Timestamp | Should Not BeNullOrEmpty

                $savePayload = '{"results":{"keyboard":"PASS"},"sellerName":"PesterSeller"}'
                $saveResp = Invoke-RestMethod -Uri "$baseUrl/api/save" -Method Post -ContentType 'application/json' -Body $savePayload -TimeoutSec 3
                $saveResp.ok | Should Be $true

                $diskHtml = Get-Content -LiteralPath $reportPath -Raw
                $diskHtml | Should Match 'PesterSeller'
                $diskHtml | Should Match 'window\.__LI_SERVER__ = false;'

                $shutResp = Invoke-RestMethod -Uri "$baseUrl/api/shutdown" -Method Post -TimeoutSec 3
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
    }
} finally {
    Remove-Item Env:\LAPTOP_INSPECT_IMPORT_ONLY -ErrorAction SilentlyContinue
}
