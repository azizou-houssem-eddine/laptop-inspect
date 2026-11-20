function Build-ReportHtml {
    param(
        [Parameter(Mandatory = $true)]$ReportData,
        [string]$ManualStateJson = '{}',
        [bool]$ServerMode = $false
    )

    $template = $script:ReportHtmlTemplate
    if ([string]::IsNullOrWhiteSpace($template)) {
        $rootDir = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }
        $tplPath = Join-Path $rootDir 'templates\report.html'
        if (Test-Path -LiteralPath $tplPath) {
            $template = [System.IO.File]::ReadAllText($tplPath, [System.Text.Encoding]::ASCII)
        } else {
            throw "Report HTML template is unavailable."
        }
    }

    $dataJson = $ReportData | ConvertTo-Json -Depth 10 -Compress
    if ([string]::IsNullOrWhiteSpace($dataJson)) { $dataJson = '{}' }
    $dataJson = $dataJson -ireplace '</script', '<\/script'

    $manualClean = if ([string]::IsNullOrWhiteSpace($ManualStateJson)) { '{}' } else { $ManualStateJson.Trim() }
    $manualClean = $manualClean -ireplace '</script', '<\/script'

    $serverFlag = if ($ServerMode) { 'true' } else { 'false' }

    $html = $template.Replace('__LI_REPORT_DATA_JSON__', $dataJson)
    $html = $html.Replace('__LI_MANUAL_STATE_JSON__', $manualClean)
    $html = $html.Replace('__LI_SERVER_FLAG__', $serverFlag)
    return $html
}

function Write-AtomicTextFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tmp = "$Path.tmp.$PID.$([Guid]::NewGuid().ToString('N').Substring(0,6))"
    [System.IO.File]::WriteAllText($tmp, $Content, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-FreeLoopbackPort {
    $tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $tcp.Start()
        return [int]$tcp.LocalEndpoint.Port
    } finally {
        $tcp.Stop()
    }
}

function Send-HttpResponse {
    param(
        $Context,
        [int]$StatusCode = 200,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [string]$Body = ''
    )
    $resp = $Context.Response
    $resp.StatusCode = $StatusCode
    $resp.ContentType = $ContentType
    $resp.Headers['Cache-Control'] = 'no-store'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Start-ReportHttpServer {
    param(
        [Parameter(Mandatory = $true)]$ReportData,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [int]$Port = 0,
        [switch]$NoLaunchBrowser,
        [int]$MaxSeconds = 0
    )

    if ($Port -le 0) { $Port = Get-FreeLoopbackPort }
    $prefix = "http://127.0.0.1:$Port/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    $listener.Start()

    $currentManualJson = '{}'

    try {
        if (-not $NoLaunchBrowser) {
            Write-Host ("[+] Interactive Report Server running at {0}" -f $prefix) -ForegroundColor Green
            Write-Host "    Complete interactive tests in your browser, click 'Save Completed Report', or press [Q] here to stop server." -ForegroundColor Gray
            try { Start-Process $prefix | Out-Null } catch {}
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $pending = $listener.GetContextAsync()
        $running = $true

        while ($running) {
            if ($MaxSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $MaxSeconds) {
                break
            }
            try {
                if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Q) {
                        Write-Host "    Stopping local report server (requested via Q)..." -ForegroundColor Yellow
                        break
                    }
                }
            } catch {}

            if (-not $pending.Wait(200)) {
                continue
            }

            $ctx = $pending.GetAwaiter().GetResult()
            $pending = $listener.GetContextAsync()

            $req = $ctx.Request
            $path = $req.Url.AbsolutePath.ToLowerInvariant()
            $method = $req.HttpMethod.ToUpperInvariant()

            try {
                if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
                    $liveHtml = Build-ReportHtml -ReportData $ReportData -ManualStateJson $currentManualJson -ServerMode $true
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $liveHtml
                } elseif ($method -eq 'GET' -and $path -eq '/api/ports') {
                    $snap = Get-ConnectedPortsSnapshot | ConvertTo-Json -Depth 6 -Compress
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $snap
                } elseif ($method -eq 'POST' -and $path -eq '/api/save') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd()
                    $sr.Dispose()
                    if ([string]::IsNullOrWhiteSpace($body)) { $body = '{}' }
                    $currentManualJson = $body
                    $offlineHtml = Build-ReportHtml -ReportData $ReportData -ManualStateJson $currentManualJson -ServerMode $false
                    Write-AtomicTextFile -Path $ReportPath -Content $offlineHtml
                    $ack = (@{ ok = $true; path = $ReportPath } | ConvertTo-Json -Compress)
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $ack
                } elseif ($method -eq 'POST' -and $path -eq '/api/export-json') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd()
                    $sr.Dispose()
                    $manualObj = $null
                    try { if (-not [string]::IsNullOrWhiteSpace($body)) { $manualObj = $body | ConvertFrom-Json } } catch {}
                    $jsonPath = [System.IO.Path]::ChangeExtension($ReportPath, '.json')
                    $combined = [PSCustomObject]@{
                        Automated = $ReportData
                        Manual    = $manualObj
                    } | ConvertTo-Json -Depth 10
                    Write-AtomicTextFile -Path $jsonPath -Content $combined
                    $ack = (@{ ok = $true; path = $jsonPath } | ConvertTo-Json -Compress)
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $ack
                } elseif ($method -eq 'POST' -and $path -eq '/api/shutdown') {
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body '{"ok":true}'
                    $running = $false
                } else {
                    Send-HttpResponse -Context $ctx -StatusCode 404 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"Not Found"}'
                }
            } catch {
                try {
                    $errJson = (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
                    Send-HttpResponse -Context $ctx -StatusCode 500 -ContentType 'application/json; charset=utf-8' -Body $errJson
                } catch {}
            }
        }
    } finally {
        try { if ($listener.IsListening) { $listener.Stop() } } catch {}
        try { $listener.Close() } catch {}
    }
}

function Show-ConsoleExecutiveSummary {
    param(
        $ReportData,
        [string]$ReportPath
    )
    $s = $ReportData.Scoring
    $sys = $ReportData.System
    $corp = $ReportData.CorporateLock
    $cpu = $ReportData.Cpu
    $gpu = $ReportData.Gpu
    $ram = $ReportData.Ram
    $stor = $ReportData.Storage
    $bat = $ReportData.Battery
    $per = $ReportData.Peripherals

    $vColor = switch ($s.Verdict) {
        'BUY'        { 'Green' }
        'CAUTION'    { 'Yellow' }
        'DO NOT BUY' { 'Red' }
        default      { 'White' }
    }

    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ("  LAPTOP INSPECT v{0} - PRE-PURCHASE AUDIT SUMMARY" -f $ReportData.Meta.ToolVersion) -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ("  VERDICT        : {0}  (Score: {1}/100)" -f $s.Verdict, $s.Score) -ForegroundColor $vColor
    Write-Host ("  Machine        : {0} {1} | Serial: {2}" -f $sys.Manufacturer, $sys.Model, $sys.SerialNumber)
    Write-Host ("  Session Mode   : {0} | Duration: {1}s" -f $(if ($corp.IsAdminSession) { 'Administrator' } else { 'Standard User' }), $ReportData.Meta.DurationSeconds)

    $corpTxt = if ($corp.ConfirmedCorporateLock) { 'LOCKED / MANAGED (HIGH RISK)' } else { 'No Local Lock Detected' }
    $corpCol = if ($corp.ConfirmedCorporateLock) { 'Red' } else { 'Green' }
    Write-Host ("  Corporate Lock : {0}" -f $corpTxt) -ForegroundColor $corpCol
    Write-Host ("  Autopilot/MDM  : Autopilot={0} | MDM={1} | AAD/Domain={2}" -f $corp.Autopilot.Status, $corp.Mdm.Status, $corp.DomainJoinStatus)
    Write-Host ("  BIOS/Computrace: BIOS-Pwd={0} | Computrace={1} | BitLocker={2}" -f $corp.BiosSecurity.Status, $corp.Computrace.Status, $corp.BitLocker.Status)

    $batTxt = if ($bat.BatteryCount -eq 0) { $bat.Condition } else { ("{0}% health ({1}), Cycles={2}" -f $bat.OverallHealthPercent, $bat.Condition, $(if ($null -ne $bat.MaxCycleCount) { $bat.MaxCycleCount } else { 'N/A' })) }
    Write-Host ("  Battery        : {0}" -f $batTxt)
    Write-Host ("  CPU            : {0} ({1}C/{2}T) | Stress={3} | Peak={4}" -f $cpu.CpuName, $cpu.PhysicalCores, $cpu.LogicalProcessors, $(if ($cpu.StressSkipped) { 'Skipped' } elseif ($cpu.VerificationPassed) { 'PASS' } else { 'FAIL' }), $(if ($null -ne $cpu.PeakTempC) { "$($cpu.PeakTempC) C" } else { 'UNAVAILABLE' }))

    $gpuNames = @($gpu.Gpus | ForEach-Object { "$($_.Name) ($($_.VramGB)GB, Err=$($_.ErrorCode))" }) -join '; '
    Write-Host ("  GPU            : {0}" -f $(if ($gpuNames) { $gpuNames } else { 'None' }))
    Write-Host ("  RAM            : {0} GB ({1}/{2} slots) | Pattern={3}" -f $ram.TotalGB, $ram.UsedSlots, $ram.TotalSlots, $ram.PatternTest.Status)

    $diskNames = @($stor.Disks | Where-Object { -not $_.IsExternal } | ForEach-Object {
        $wStr = if ($null -ne $_.WearPercent) { "$($_.WearPercent)%" } else { 'N/A' }
        "$($_.FriendlyName) $($_.SizeGB)GB [$($_.HealthStatus), Wear=$wStr]"
    }) -join '; '
    Write-Host ("  Internal Disks : {0}" -f $(if ($diskNames) { $diskNames } else { 'None' }))
    Write-Host ("  Device Errors  : {0}" -f @($per.DeviceErrors | Where-Object { -not $_.IsDisabled }).Count)

    if ($s.CriticalFlags.Count -gt 0) {
        Write-Host "  CRITICAL FLAGS :" -ForegroundColor Red
        foreach ($cf in $s.CriticalFlags) { Write-Host ("    [X] {0}" -f $cf) -ForegroundColor Red }
    }
    if ($s.Warnings.Count -gt 0) {
        Write-Host "  WARNINGS       :" -ForegroundColor Yellow
        foreach ($w in $s.Warnings) { Write-Host ("    [!] {0}" -f $w) -ForegroundColor Yellow }
    }
    Write-Host ("  Saved Report   : {0}" -f $ReportPath) -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
}

function Invoke-LaptopInspect {
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    $isAdmin = Test-IsAdmin
    $targetOutDir = Get-DefaultOutputDirectory -Requested $OutDir

    try {
        $elevatedStarted = Request-OptionalElevation `
            -QuickFlag:$Quick `
            -SkipStressFlag:$SkipStress `
            -StressSec $StressSeconds `
            -NoBrowserFlag:$NoBrowser `
            -NoServerFlag:$NoServer `
            -JsonOnlyFlag:$JsonOnly `
            -TargetOutDir $targetOutDir
        if ($elevatedStarted) {
            Write-Host "Elevated session started in new window. Exiting non-admin parent." -ForegroundColor Green
            return
        }

        Write-Host ""
        Write-Host ("=== {0} v{1} ===" -f $script:ToolName, $script:ToolVersion) -ForegroundColor Cyan

        Write-Step -Index 1 -Total 9 -Title 'System Identity & Environment'
        $sysInfo = Get-SystemIdentity

        Write-Step -Index 2 -Total 9 -Title 'Corporate Lock & Ownership Audit (Autopilot/MDM/Computrace/BIOS/BitLocker)'
        $corpAudit = Get-CorporateLockAudit -IsAdmin $isAdmin

        Write-Step -Index 3 -Total 9 -Title 'GPU & Display Adapters'
        $nvPath = Find-NvidiaSmiPath
        $gpuInfo = Get-GpuDiagnostics -NvidiaSmiPath $nvPath

        $stressLabel = if ($StressSeconds -gt 0) { "CPU Specs, Verified Workload & $($StressSeconds)s Thermal Load" } else { 'CPU Specs (Stress Skipped)' }
        Write-Step -Index 4 -Total 9 -Title $stressLabel
        $cpuInfo = Get-CpuAndThermalTest -StressSeconds $StressSeconds -NvidiaSmiPath $nvPath

        Write-Step -Index 5 -Total 9 -Title 'RAM Slots & Verified Pattern Check'
        $ramInfo = Get-RamDiagnostics -SkipStress:$SkipStress

        Write-Step -Index 6 -Total 9 -Title 'Storage SMART Health & Speed Benchmark'
        $storInfo = Get-StorageDiagnostics -SkipBench:$SkipStress

        Write-Step -Index 7 -Total 9 -Title 'Battery Health, Cycles & AC Load Stability'
        $batInfo = Get-BatteryDiagnostics -LoadSamples $cpuInfo.LoadSamples -IsLaptop $sysInfo.IsLaptop

        Write-Step -Index 8 -Total 9 -Title 'Display EDID, Wi-Fi, Gateway Ping, Ports & Device Errors'
        $periphInfo = Get-PeripheralsAndNetwork
        $portSnap = Get-ConnectedPortsSnapshot

        Write-Step -Index 9 -Total 9 -Title 'Scoring & Generating Report'
        $swTotal.Stop()

        $reportObj = [PSCustomObject]@{
            Meta = [PSCustomObject]@{
                ToolName        = $script:ToolName
                ToolVersion     = $script:ToolVersion
                RepoUrl         = $script:RepoUrl
                GeneratedAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                DurationSeconds = [Math]::Round($swTotal.Elapsed.TotalSeconds, 1)
                QuickMode       = [bool]$Quick
                StressSeconds   = $StressSeconds
                IsAdmin         = [bool]$isAdmin
            }
            System        = $sysInfo
            CorporateLock = $corpAudit
            Cpu           = $cpuInfo
            Gpu           = $gpuInfo
            Ram           = $ramInfo
            Storage       = $storInfo
            Battery       = $batInfo
            Peripherals   = $periphInfo
            InitialPorts  = $portSnap
            Scoring       = $null
        }

        $reportObj.Scoring = Get-BuyerVerdict -ReportData $reportObj

        $safeModel = ($sysInfo.Model -replace '[^A-Za-z0-9\-_]+', '_').Trim('_')
        if ([string]::IsNullOrWhiteSpace($safeModel)) { $safeModel = 'Laptop' }
        if ($safeModel.Length -gt 28) { $safeModel = $safeModel.Substring(0, 28) }
        $safeSerial = ($sysInfo.SerialNumber -replace '[^A-Za-z0-9\-_]+', '_').Trim('_')
        if ([string]::IsNullOrWhiteSpace($safeSerial)) { $safeSerial = 'NoSerial' }
        if ($safeSerial.Length -gt 18) { $safeSerial = $safeSerial.Substring(0, 18) }
        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

        if ($JsonOnly) {
            $jsonOut = Join-Path $targetOutDir ("LaptopReport_{0}_{1}_{2}.json" -f $safeModel, $safeSerial, $stamp)
            Write-AtomicTextFile -Path $jsonOut -Content ($reportObj | ConvertTo-Json -Depth 10)
            Show-ConsoleExecutiveSummary -ReportData $reportObj -ReportPath $jsonOut
            return
        }

        $htmlPath = Join-Path $targetOutDir ("LaptopReport_{0}_{1}_{2}.html" -f $safeModel, $safeSerial, $stamp)
        $offlineHtml = Build-ReportHtml -ReportData $reportObj -ManualStateJson '{}' -ServerMode $false
        Write-AtomicTextFile -Path $htmlPath -Content $offlineHtml

        Show-ConsoleExecutiveSummary -ReportData $reportObj -ReportPath $htmlPath

        if (-not $NoBrowser) {
            if (-not $NoServer) {
                Start-ReportHttpServer -ReportData $reportObj -ReportPath $htmlPath
            } else {
                try { Start-Process $htmlPath | Out-Null } catch {}
            }
        }
    } finally {
        try { Write-Progress -Activity "$($script:ToolName) v$($script:ToolVersion)" -Completed } catch {}
        if (-not [string]::IsNullOrWhiteSpace($CleanupTempPath) -and (Test-Path -LiteralPath $CleanupTempPath)) {
            Remove-Item -LiteralPath $CleanupTempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($env:LAPTOP_INSPECT_IMPORT_ONLY -ne '1') {
    Invoke-LaptopInspect
    if (-not [string]::IsNullOrWhiteSpace($CleanupTempPath) -and -not $NoBrowser) {
        try {
            if (-not [Console]::IsInputRedirected) {
                Read-Host "`nInspection finished. Press Enter to close this window" | Out-Null
            }
        } catch {}
    }
}
