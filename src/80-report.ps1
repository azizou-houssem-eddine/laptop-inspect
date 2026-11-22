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
    $installState = [hashtable]::Synchronized(@{
        Running         = $false
        State           = 'Idle'
        CurrentIndex    = 0
        Total           = 0
        CurrentApp      = ''
        CancelRequested = $false
        Winget          = (Get-WingetInfo)
        Results         = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Logs            = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    })
    $installBg = $null
    $installAsync = $null
    $installRunspace = $null

    $batDrainState = [hashtable]::Synchronized(@{
        Running          = $false
        State            = 'Idle'
        WaitingForUnplug = $false
        LoadMode         = 'everyday'
        TargetMinutes    = 15
        CutoffPct        = 10
        ElapsedSeconds   = 0
        RemainingSeconds = 0
        CancelRequested  = $false
        Error            = ''
        CurrentSample    = $null
        Summary          = $null
        Samples          = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    })
    $batDrainBg = $null
    $batDrainAsync = $null
    $batDrainRunspace = $null

    try {
        if (-not $NoLaunchBrowser) {
            Write-Host ("[+] Interactive Report Server running at {0}" -f $prefix) -ForegroundColor Green
            Write-Host "    Complete interactive tests, battery timer, or app installs in browser, or press [Q] here to stop server." -ForegroundColor Gray
            try { Start-Process $prefix | Out-Null } catch {}
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $pending = $listener.GetContextAsync()
        $running = $true

        while ($running) {
            if ($MaxSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $MaxSeconds) {
                break
            }
            if ($installBg -and $installAsync -and $installAsync.IsCompleted) {
                try { $installBg.EndInvoke($installAsync) | Out-Null } catch {}
                try { $installBg.Dispose() } catch {}
                try { $installRunspace.Close(); $installRunspace.Dispose() } catch {}
                $installBg = $null
                $installAsync = $null
                $installRunspace = $null
            }
            if ($batDrainBg -and $batDrainAsync -and $batDrainAsync.IsCompleted) {
                try { $batDrainBg.EndInvoke($batDrainAsync) | Out-Null } catch {}
                try { $batDrainBg.Dispose() } catch {}
                try { $batDrainRunspace.Close(); $batDrainRunspace.Dispose() } catch {}
                $batDrainBg = $null
                $batDrainAsync = $null
                $batDrainRunspace = $null
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
                } elseif ($method -eq 'GET' -and $path -eq '/api/install/status') {
                    $snapObj = [PSCustomObject]@{
                        Running      = [bool]$installState.Running
                        State        = [string]$installState.State
                        CurrentIndex = [int]$installState.CurrentIndex
                        Total        = [int]$installState.Total
                        CurrentApp   = [string]$installState.CurrentApp
                        Winget       = $installState.Winget
                        Results      = @($installState.Results.ToArray())
                        Logs         = @($installState.Logs.ToArray())
                    } | ConvertTo-Json -Depth 6 -Compress
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $snapObj
                } elseif ($method -eq 'POST' -and $path -eq '/api/install') {
                    if ($installState.Running) {
                        Send-HttpResponse -Context $ctx -StatusCode 409 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"An installation queue is already running."}'
                        continue
                    }
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd()
                    $sr.Dispose()
                    $reqObj = $null
                    try { $reqObj = $body | ConvertFrom-Json } catch {}
                    if ($null -eq $reqObj) {
                        Send-HttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"Invalid JSON payload"}'
                        continue
                    }

                    $reqIds = @()
                    if ($reqObj.ids) { $reqIds = @($reqObj.ids | ForEach-Object { [string]$_ }) }
                    $reqPreset = if ($reqObj.preset) { [string]$reqObj.preset } else { '' }
                    $reqUpgrade = [bool]$reqObj.upgradeAll
                    $reqDryRun = [bool]$reqObj.dryRun

                    try {
                        $targets = @(Resolve-InstallTargets -KeysOrIds $reqIds -Preset $reqPreset)
                    } catch {
                        $badMsg = (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
                        Send-HttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body $badMsg
                        continue
                    }

                    if ($targets.Count -eq 0 -and -not $reqUpgrade) {
                        Send-HttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"No packages or upgrade option selected."}'
                        continue
                    }

                    $installState.Results.Clear()
                    $installState.Logs.Clear()
                    $installState.CancelRequested = $false
                    $installState.Running = $true
                    $installState.State = 'Running'
                    $installState.CurrentIndex = 0
                    $installState.Total = $targets.Count + $(if ($reqUpgrade) { 1 } else { 0 })
                    $installState.CurrentApp = ''

                    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                    foreach ($fnName in @('Get-AppCatalog','Get-AppPresets','Test-SafeWingetId','Resolve-InstallTargets','Get-WingetInfo','Ensure-WingetReady','Build-WingetInstallArgs','Build-WingetUpgradeAllArgs','ConvertTo-WingetInstallResult','Invoke-SilentAppInstallBatch')) {
                        $fnDef = (Get-Command -Name $fnName -ErrorAction Stop).Definition
                        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fnName, $fnDef)))
                    }
                    $installRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
                    $installRunspace.Open()
                    $installBg = [PowerShell]::Create()
                    $installBg.Runspace = $installRunspace
                    [void]$installBg.AddScript({
                        param($TgtList, $DoUpgrade, $DoDry, $SharedState)
                        Invoke-SilentAppInstallBatch -Targets $TgtList -UpgradeAll:$DoUpgrade -DryRun:$DoDry -ProgressState $SharedState | Out-Null
                    }).AddArgument($targets).AddArgument($reqUpgrade).AddArgument($reqDryRun).AddArgument($installState)
                    $installAsync = $installBg.BeginInvoke()

                    $ack = (@{ ok = $true; total = $installState.Total } | ConvertTo-Json -Compress)
                    Send-HttpResponse -Context $ctx -StatusCode 202 -ContentType 'application/json; charset=utf-8' -Body $ack
                } elseif ($method -eq 'POST' -and $path -eq '/api/install/cancel') {
                    $installState.CancelRequested = $true
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body '{"ok":true}'
                } elseif ($method -eq 'GET' -and $path -eq '/api/battery-test/status') {
                    $bSnap = [PSCustomObject]@{
                        Running          = [bool]$batDrainState.Running
                        State            = [string]$batDrainState.State
                        WaitingForUnplug = [bool]$batDrainState.WaitingForUnplug
                        LoadMode         = [string]$batDrainState.LoadMode
                        TargetMinutes    = [int]$batDrainState.TargetMinutes
                        CutoffPct        = [int]$batDrainState.CutoffPct
                        ElapsedSeconds   = [int]$batDrainState.ElapsedSeconds
                        RemainingSeconds = [int]$batDrainState.RemainingSeconds
                        Error            = [string]$batDrainState.Error
                        CurrentSample    = $batDrainState.CurrentSample
                        Summary          = $batDrainState.Summary
                        Samples          = @($batDrainState.Samples.ToArray())
                    } | ConvertTo-Json -Depth 6 -Compress
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $bSnap
                } elseif ($method -eq 'POST' -and $path -eq '/api/battery-test/start') {
                    if ($batDrainState.Running) {
                        Send-HttpResponse -Context $ctx -StatusCode 409 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"A battery drain test is already running."}'
                        continue
                    }
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd()
                    $sr.Dispose()
                    $reqObj = $null
                    try { $reqObj = $body | ConvertFrom-Json } catch {}
                    if ($null -eq $reqObj) {
                        Send-HttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"Invalid JSON payload"}'
                        continue
                    }

                    $bMins = if ($null -ne $reqObj.minutes) { [int]$reqObj.minutes } else { 15 }
                    $bMode = if ($reqObj.mode) { ([string]$reqObj.mode).Trim().ToLowerInvariant() } else { 'everyday' }
                    $bCut  = if ($null -ne $reqObj.cutoffPct) { [int]$reqObj.cutoffPct } else { 10 }

                    if (($bMins -lt -1 -or $bMins -eq 0 -or $bMins -gt 240) -or ($bMode -notin @('everyday', 'light', 'heavy')) -or ($bCut -lt 5 -or $bCut -gt 50)) {
                        Send-HttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"Invalid battery test parameters (minutes=-1 or 1..240, mode=everyday|light|heavy, cutoffPct=5..50)."}'
                        continue
                    }

                    $batsNow = @(Invoke-SafeCim -ClassName 'Win32_Battery')
                    if ($batsNow.Count -eq 0) {
                        Send-HttpResponse -Context $ctx -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body '{"ok":false,"error":"No battery detected on this machine."}'
                        continue
                    }

                    $totCap = 0.0
                    if ($ReportData.Battery -and $ReportData.Battery.Batteries) {
                        foreach ($bb in @($ReportData.Battery.Batteries)) {
                            if ($bb.FullChargeMWh -gt 0) { $totCap += [double]$bb.FullChargeMWh }
                        }
                    }

                    $batDrainState.Running = $true
                    $batDrainState.State = 'Starting'
                    $batDrainState.CancelRequested = $false

                    $issB = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
                    foreach ($fnName in @('Invoke-SafeCim','Get-CpuTempCelsius','Get-BatteryCheckpointPath','Clear-BatteryCheckpoint','Set-BatteryTestKeepAwake','Get-BatteryDischargeSample','Measure-BatteryDrainSummary','Invoke-EverydayTickWorkload','Invoke-TimedBatteryDrainTest')) {
                        $fnDef = (Get-Command -Name $fnName -ErrorAction Stop).Definition
                        $issB.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fnName, $fnDef)))
                    }
                    $batDrainRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($issB)
                    $batDrainRunspace.Open()
                    $batDrainBg = [PowerShell]::Create()
                    $batDrainBg.Runspace = $batDrainRunspace
                    [void]$batDrainBg.AddScript({
                        param($Mins, $Cut, $Mode, $Cap, $SharedState)
                        Invoke-TimedBatteryDrainTest -Minutes $Mins -CutoffPct $Cut -LoadMode $Mode -TotalCapacityMWh $Cap -ProgressState $SharedState | Out-Null
                    }).AddArgument($bMins).AddArgument($bCut).AddArgument($bMode).AddArgument($totCap).AddArgument($batDrainState)
                    $batDrainAsync = $batDrainBg.BeginInvoke()

                    Send-HttpResponse -Context $ctx -StatusCode 202 -ContentType 'application/json; charset=utf-8' -Body '{"ok":true}'
                } elseif ($method -eq 'POST' -and $path -eq '/api/battery-test/stop') {
                    $batDrainState.CancelRequested = $true
                    Send-HttpResponse -Context $ctx -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body '{"ok":true}'
                } elseif ($method -eq 'POST' -and $path -eq '/api/save') {
                    $sr = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $sr.ReadToEnd()
                    $sr.Dispose()
                    if ([string]::IsNullOrWhiteSpace($body)) { $body = '{}' }
                    $currentManualJson = $body
                    if ($null -ne $batDrainState.Summary) {
                        $ReportData | Add-Member -NotePropertyName BatteryDrain -NotePropertyValue $batDrainState.Summary -Force
                        $ReportData | Add-Member -NotePropertyName BatteryDrainSamples -NotePropertyValue @($batDrainState.Samples.ToArray()) -Force
                        $ReportData.Scoring = Get-BuyerVerdict -ReportData $ReportData
                    }
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
        if ($installBg) {
            $installState.CancelRequested = $true
            try { $installBg.Stop() } catch {}
            try { $installBg.Dispose() } catch {}
        }
        if ($installRunspace) {
            try { $installRunspace.Close(); $installRunspace.Dispose() } catch {}
        }
        if ($batDrainBg) {
            $batDrainState.CancelRequested = $true
            try { $batDrainBg.Stop() } catch {}
            try { $batDrainBg.Dispose() } catch {}
        }
        if ($batDrainRunspace) {
            try { $batDrainRunspace.Close(); $batDrainRunspace.Dispose() } catch {}
        }
        try { if ($listener.IsListening) { $listener.Stop() } } catch {}
        try { $listener.Close() } catch {}
    }
}

function Show-ConsoleExecutiveSummary {
    param(
        $ReportData,
        [string]$ReportPath
    )
    Show-TuiExecutiveSummary -ReportData $ReportData -ReportPath $ReportPath
}

function Invoke-LaptopInspect {
    $isAdmin = Test-IsAdmin
    $targetOutDir = Get-DefaultOutputDirectory -Requested $OutDir
    $launchedFromTuiTerminalOnly = $false

    try {
        $hasActionFlags = (
            $Quick -or
            $SkipStress -or
            $NoBrowser -or
            $NoServer -or
            $JsonOnly -or
            $InstallOnly -or
            $UpgradeAll -or
            $DryRun -or
            $BatteryTestOnly -or
            ($BatteryTestMinutes -ne 0) -or
            -not [string]::IsNullOrWhiteSpace($InstallPreset) -or
            ($InstallApps -and $InstallApps.Count -gt 0) -or
            ($PSBoundParameters.ContainsKey('StressSeconds'))
        )

        $showMenu = ($Menu -or (-not $NoMenu -and -not $hasActionFlags)) -and (Test-InteractiveConsole)
        if ($showMenu) {
            while ($true) {
                $choice = Show-TuiMainMenu -IsAdmin $isAdmin
                switch ($choice) {
                    'Exit' { return }
                    'Elevate' {
                        $elevOk = Request-OptionalElevation -TargetOutDir $targetOutDir -MenuFlag -ForceElevate
                        if ($elevOk) {
                            Write-Host '  [+] Elevated TUI session launched in new Administrator window.' -ForegroundColor Green
                            return
                        }
                        Read-Host '  Press Enter to return to menu' | Out-Null
                    }
                    'InstallerTui' {
                        Invoke-TuiSilentInstallerMenu
                    }
                    'BatteryTui' {
                        Invoke-TuiBatteryDrainMenu
                    }
                    'FullAudit' {
                        break
                    }
                    'QuickAudit' {
                        $Quick = $true; $SkipStress = $true; $StressSeconds = 0
                        break
                    }
                    'TerminalOnly' {
                        $Quick = $true; $SkipStress = $true; $StressSeconds = 0; $NoBrowser = $true
                        $launchedFromTuiTerminalOnly = $true
                        break
                    }
                    'AuditAndEss' {
                        $InstallPreset = 'essentials'
                        break
                    }
                    'UpgradeAll' {
                        $InstallOnly = $true; $UpgradeAll = $true
                        break
                    }
                }
                if ($choice -in @('FullAudit', 'QuickAudit', 'TerminalOnly', 'AuditAndEss', 'UpgradeAll')) {
                    break
                }
            }
        }

        $elevatedStarted = Request-OptionalElevation `
            -QuickFlag:$Quick `
            -SkipStressFlag:$SkipStress `
            -StressSec $StressSeconds `
            -NoBrowserFlag:$NoBrowser `
            -NoServerFlag:$NoServer `
            -JsonOnlyFlag:$JsonOnly `
            -TargetOutDir $targetOutDir `
            -PresetFlag $InstallPreset `
            -AppsFlag $InstallApps `
            -UpgradeAllFlag:$UpgradeAll `
            -InstallOnlyFlag:$InstallOnly `
            -DryRunFlag:$DryRun `
            -BatMinutesFlag $BatteryTestMinutes `
            -BatModeFlag $BatteryTestMode `
            -BatCutoffFlag $BatteryCutoffPct `
            -BatOnlyFlag:$BatteryTestOnly
        if ($elevatedStarted) {
            Write-Host "  [+] Elevated session started in new window. Exiting non-admin parent." -ForegroundColor Green
            return
        }

        if ($BatteryTestOnly) {
            $bMins = if ($BatteryTestMinutes -ne 0) { $BatteryTestMinutes } else { 15 }
            Show-TuiHeader -IsAdmin $isAdmin -Subtitle ("Timed Battery Drain Test ({0} mode, cutoff {1}%)" -f $BatteryTestMode, $BatteryCutoffPct)
            $bSum = Invoke-TimedBatteryDrainTest -Minutes $bMins -CutoffPct $BatteryCutoffPct -LoadMode $BatteryTestMode -ConsoleLive
            Write-Host ""
            Write-Host "  === Battery Endurance Summary ===" -ForegroundColor Cyan
            Write-Host ("  Status       : {0} ({1})" -f $bSum.Status, $bSum.StopReason)
            $dropTxt = if ($null -ne $bSum.StartPct) { ("{0}% -> {1}% (-{2}%)" -f $bSum.StartPct, $bSum.EndPct, $bSum.DropPct) } else { 'N/A' }
            Write-Host ("  Elapsed      : {0} min | Drop: {1}" -f $bSum.ElapsedMinutes, $dropTxt)
            if ($null -ne $bSum.EstimatedRuntimeFrom100Minutes) {
                Write-Host ("  Est. 100->0% : ~{0} min ({1} hrs)" -f $bSum.EstimatedRuntimeFrom100Minutes, [Math]::Round($bSum.EstimatedRuntimeFrom100Minutes / 60.0, 1)) -ForegroundColor Green
            }
            return
        }

        if ($InstallOnly) {
            Show-TuiHeader -IsAdmin $isAdmin -Subtitle 'Silent Zero-Prompt Software Installer'
            $targets = @(Resolve-InstallTargets -KeysOrIds $InstallApps -Preset $InstallPreset)
            if ($targets.Count -eq 0 -and -not $UpgradeAll) {
                throw "No apps specified. Pass -InstallPreset <essentials|office|tech|dev>, -InstallApps <keys/ids>, or -UpgradeAll."
            }
            $resList = @(Invoke-SilentAppInstallBatch -Targets $targets -UpgradeAll:$UpgradeAll -DryRun:$DryRun -ConsoleOutput)
            Write-Host ""
            Write-Host "  === Silent Install Summary ===" -ForegroundColor Cyan
            foreach ($ri in $resList) {
                Write-Host '  ' -NoNewline
                Write-TuiStatusTag -Status $(if ($ri.Success) { 'OK' } else { 'FAIL' }) -NoNewline
                Write-Host (" {0} ({1}) -> {2}" -f $ri.Name, $ri.WingetId, $ri.Status)
            }
            return
        }

        $prevBatCrash = Get-UnfinishedBatteryCheckpoint

        $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
        if ($showMenu -and (Test-InteractiveConsole)) { try { Clear-Host } catch {} }
        Show-TuiHeader -IsAdmin $isAdmin
        Write-Host ""

        $swStep = [System.Diagnostics.Stopwatch]::StartNew()
        Write-TuiStepStart -Index 1 -Total 9 -Title 'System Identity'
        $sysInfo = Get-SystemIdentity
        Complete-TuiStep -Index 1 -Total 9 -Title 'System Identity' -Status 'PASS' -Summary ("{0} {1}" -f $sysInfo.Manufacturer, $sysInfo.Model) -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 2 -Total 9 -Title 'Corporate Lock Audit'
        $corpAudit = Get-CorporateLockAudit -IsAdmin $isAdmin
        $corpSt = if ($corpAudit.ConfirmedCorporateLock) { 'LOCKED' } elseif ($corpAudit.BitLocker.Active) { 'WARN' } else { 'CLEAN' }
        $corpSum = if ($corpAudit.ConfirmedCorporateLock) { 'Lock / Management Detected' } else { "AP=$($corpAudit.Autopilot.Status) MDM=$($corpAudit.Mdm.Status) BL=$($corpAudit.BitLocker.Status)" }
        Complete-TuiStep -Index 2 -Total 9 -Title 'Corporate Lock Audit' -Status $corpSt -Summary $corpSum -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 3 -Total 9 -Title 'GPU & VRAM Telemetry'
        $nvPath = Find-NvidiaSmiPath
        $gpuInfo = Get-GpuDiagnostics -NvidiaSmiPath $nvPath
        $gpuTop = $gpuInfo.Gpus | Sort-Object { $_.Type -ne 'Discrete GPU' } | Select-Object -First 1
        $gpuSum = if ($gpuTop) { "{0} ({1} GB)" -f $gpuTop.Name, $gpuTop.VramGB } else { 'None detected' }
        Complete-TuiStep -Index 3 -Total 9 -Title 'GPU & VRAM Telemetry' -Status $gpuInfo.Status -Summary $gpuSum -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        $stressTitle = if ($StressSeconds -gt 0) { "CPU Math + $($StressSeconds)s Thermal" } else { 'CPU Identity' }
        Write-TuiStepStart -Index 4 -Total 9 -Title $stressTitle
        $cpuInfo = Get-CpuAndThermalTest -StressSeconds $StressSeconds -NvidiaSmiPath $nvPath
        $cpuSt = if (-not $cpuInfo.StressSkipped -and -not $cpuInfo.VerificationPassed) { 'FAIL' } elseif ($cpuInfo.ThrottlingSuspected) { 'WARN' } else { 'PASS' }
        $cpuSum = if ($cpuInfo.StressSkipped) { "{0}C/{1}T (Stress skipped)" -f $cpuInfo.PhysicalCores, $cpuInfo.LogicalProcessors } else { "{0}C/{1}T Int+FP PASS" -f $cpuInfo.PhysicalCores, $cpuInfo.LogicalProcessors }
        Complete-TuiStep -Index 4 -Total 9 -Title $stressTitle -Status $cpuSt -Summary $cpuSum -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 5 -Total 9 -Title 'RAM Slots & Pattern'
        $ramInfo = Get-RamDiagnostics -SkipStress:$SkipStress
        $ramSt = if ($ramInfo.PatternTest.Status -eq 'FAIL') { 'FAIL' } else { 'PASS' }
        Complete-TuiStep -Index 5 -Total 9 -Title 'RAM Slots & Pattern' -Status $ramSt -Summary ("{0} GB ({1}/{2} slots) [{3}]" -f $ramInfo.TotalGB, $ramInfo.UsedSlots, $ramInfo.TotalSlots, $ramInfo.PatternTest.Status) -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 6 -Total 9 -Title 'Storage SMART & Speed'
        $storInfo = Get-StorageDiagnostics -SkipBench:$SkipStress
        $d0 = $storInfo.Disks | Where-Object { -not $_.IsExternal } | Select-Object -First 1
        $storSum = if ($d0) { "{0} ({1} GB) [{2}]" -f $d0.FriendlyName, $d0.SizeGB, $d0.HealthStatus } else { 'No internal disk' }
        Complete-TuiStep -Index 6 -Total 9 -Title 'Storage SMART & Speed' -Status $storInfo.Status -Summary $storSum -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 7 -Total 9 -Title 'Battery & AC Stability'
        $batInfo = Get-BatteryDiagnostics -LoadSamples $cpuInfo.LoadSamples -IsLaptop $sysInfo.IsLaptop
        $batSum = if ($batInfo.BatteryCount -gt 0) { "{0}% ({1}, {2} cycles)" -f $batInfo.OverallHealthPercent, $batInfo.Condition, $(if ($null -ne $batInfo.MaxCycleCount) { $batInfo.MaxCycleCount } else { 'N/A' }) } else { $batInfo.Condition }
        Complete-TuiStep -Index 7 -Total 9 -Title 'Battery & AC Stability' -Status $batInfo.Status -Summary $batSum -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 8 -Total 9 -Title 'Display, Wi-Fi & Ports'
        $periphInfo = Get-PeripheralsAndNetwork
        $portSnap = Get-ConnectedPortsSnapshot
        $errCnt = @($periphInfo.DeviceErrors | Where-Object { -not $_.IsDisabled }).Count
        $perSum = ("{0} | {1} | Err={2}" -f $periphInfo.Display.PrimaryRes, $periphInfo.Network.WifiGeneration, $errCnt)
        Complete-TuiStep -Index 8 -Total 9 -Title 'Display, Wi-Fi & Ports' -Status $periphInfo.DeviceErrorStatus -Summary $perSum -Seconds $swStep.Elapsed.TotalSeconds

        $swStep.Restart()
        Write-TuiStepStart -Index 9 -Total 9 -Title 'Scoring & HTML Report'
        $swTotal.Stop()

        $batDrainResult = $null
        if ($BatteryTestMinutes -ne 0 -and $batInfo.BatteryCount -gt 0) {
            Write-Host ""
            Write-Host ("  [+] Running Timed Battery Drain ({0} min, {1} mode, cutoff {2}%)..." -f $BatteryTestMinutes, $BatteryTestMode, $BatteryCutoffPct) -ForegroundColor Cyan
            $batDrainResult = Invoke-TimedBatteryDrainTest -Minutes $BatteryTestMinutes -CutoffPct $BatteryCutoffPct -LoadMode $BatteryTestMode -ConsoleLive
        }

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
            System               = $sysInfo
            CorporateLock        = $corpAudit
            Cpu                  = $cpuInfo
            Gpu                  = $gpuInfo
            Ram                  = $ramInfo
            Storage              = $storInfo
            Battery              = $batInfo
            PreviousBatteryCrash = $prevBatCrash
            BatteryDrain         = $batDrainResult
            Peripherals          = $periphInfo
            InitialPorts         = $portSnap
            Installer            = [PSCustomObject]@{
                Winget  = (Get-WingetInfo)
                Catalog = @(Get-AppCatalog)
                Presets = @(Get-AppPresets)
            }
            Scoring              = $null
        }

        $reportObj.Scoring = Get-BuyerVerdict -ReportData $reportObj
        Complete-TuiStep -Index 9 -Total 9 -Title 'Scoring & HTML Report' -Status $reportObj.Scoring.Verdict -Summary ("Score: {0}/100" -f $reportObj.Scoring.Score) -Seconds $swStep.Elapsed.TotalSeconds

        $cliTargets = @()
        if (-not [string]::IsNullOrWhiteSpace($InstallPreset) -or ($InstallApps -and $InstallApps.Count -gt 0)) {
            $cliTargets = @(Resolve-InstallTargets -KeysOrIds $InstallApps -Preset $InstallPreset)
        }
        if ($cliTargets.Count -gt 0 -or $UpgradeAll) {
            Write-Host ""
            Write-Host "  [+] Running Silent App Installer Queue..." -ForegroundColor Cyan
            $cliInstResults = @(Invoke-SilentAppInstallBatch -Targets $cliTargets -UpgradeAll:$UpgradeAll -DryRun:$DryRun -ConsoleOutput)
            foreach ($ri in $cliInstResults) {
                Write-Host '  ' -NoNewline
                Write-TuiStatusTag -Status $(if ($ri.Success) { 'OK' } else { 'FAIL' }) -NoNewline
                Write-Host (" {0} -> {1}" -f $ri.Name, $ri.Status)
            }
        }

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
        } elseif ($launchedFromTuiTerminalOnly -and (Test-InteractiveConsole)) {
            while ($true) {
                Write-Host ''
                Write-Host '  Actions: [O] Open HTML Report  [C] Copy Summary  [I] App Installer  [Enter] Exit: ' -NoNewline -ForegroundColor Yellow
                $pk = [Console]::ReadKey($true)
                $pch = $pk.KeyChar.ToString().ToUpperInvariant()
                Write-Host $pch
                if ($pk.Key -eq [ConsoleKey]::Enter -or $pk.Key -eq [ConsoleKey]::Escape) {
                    break
                } elseif ($pch -eq 'O') {
                    try { Start-Process $htmlPath | Out-Null } catch {}
                } elseif ($pch -eq 'C') {
                    try {
                        Set-Clipboard -Value (Build-PlainTextSummaryFromPs -ReportData $reportObj)
                        Write-Host '  [+] Summary copied to clipboard!' -ForegroundColor Green
                    } catch {}
                } elseif ($pch -eq 'I') {
                    Invoke-TuiSilentInstallerMenu
                    Show-ConsoleExecutiveSummary -ReportData $reportObj -ReportPath $htmlPath
                }
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
