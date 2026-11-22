function Test-InteractiveConsole {
    if ($env:LAPTOP_INSPECT_IMPORT_ONLY -eq '1') { return $false }
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
        $null = $Host.UI.RawUI.WindowSize
        return $true
    } catch {
        return $false
    }
}

function Format-TuiPad {
    param(
        [string]$Text = '',
        [int]$Width = 74
    )
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -gt $Width) {
        return $Text.Substring(0, $Width - 3) + '...'
    }
    return $Text.PadRight($Width, ' ')
}

function Format-TuiBar {
    param(
        [int]$Percent,
        [int]$Width = 24
    )
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $filled = [int][Math]::Round(($Percent / 100.0) * $Width)
    $empty = [Math]::Max(0, $Width - $filled)
    return ('[' + ('#' * $filled) + ('.' * $empty) + ']')
}

function Write-TuiStatusTag {
    param(
        [string]$Status,
        [switch]$NoNewline
    )
    $s = ([string]$Status).ToUpperInvariant()
    $label = ' INFO '
    $fg = 'Cyan'
    switch ($s) {
        'PASS'        { $label = ' PASS '; $fg = 'Green' }
        'OK'          { $label = '  OK  '; $fg = 'Green' }
        'BUY'         { $label = ' BUY  '; $fg = 'Green' }
        'CLEAN'       { $label = 'CLEAN '; $fg = 'Green' }
        'WARN'        { $label = ' WARN '; $fg = 'Yellow' }
        'CAUTION'     { $label = 'CAUTN '; $fg = 'Yellow' }
        'FAIL'        { $label = ' FAIL '; $fg = 'Red' }
        'LOCKED'      { $label = 'LOCKED'; $fg = 'Red' }
        'DO NOT BUY'  { $label = 'REJECT'; $fg = 'Red' }
        'UNAVAILABLE' { $label = ' N/A  '; $fg = 'DarkGray' }
        'SKIPPED'     { $label = ' SKIP '; $fg = 'DarkGray' }
        'RUN'         { $label = ' .... '; $fg = 'Cyan' }
        default       { $label = (' ' + $s.PadRight(4).Substring(0, 4) + ' '); $fg = 'Gray' }
    }
    Write-Host '[' -NoNewline -ForegroundColor DarkGray
    Write-Host $label -NoNewline -ForegroundColor $fg
    if ($NoNewline) {
        Write-Host ']' -NoNewline -ForegroundColor DarkGray
    } else {
        Write-Host ']' -ForegroundColor DarkGray
    }
}

function Show-TuiHeader {
    param(
        [bool]$IsAdmin = (Test-IsAdmin),
        [string]$Subtitle = 'Pre-Purchase Laptop Diagnostic, Corporate Lock & Silent Installer'
    )
    $w = 88
    $line = '+' + ('=' * $w) + '+'
    $div  = '+' + ('-' * $w) + '+'

    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    $titleText = ("  LAPTOP INSPECT v{0}  |  WINDOWS BUYER & REFURBISHER SUITE" -f $script:ToolVersion)
    Write-Host ('|' + (Format-TuiPad -Text $titleText -Width $w) + '|') -ForegroundColor White
    Write-Host ('|' + (Format-TuiPad -Text ("  " + $Subtitle) -Width $w) + '|') -ForegroundColor DarkCyan
    Write-Host $div -ForegroundColor Cyan

    $privStr = if ($IsAdmin) { '[ADMIN: Full BIOS/BitLocker/SMART]' } else { '[STANDARD USER: Limited WMI]' }
    $privCol = if ($IsAdmin) { 'Green' } else { 'Yellow' }
    $hostStr = ("  Host: {0}  |  PS: v{1}  |  Mode: " -f $env:COMPUTERNAME, $PSVersionTable.PSVersion.Major)
    $rem = [Math]::Max(0, $w - $hostStr.Length - $privStr.Length)

    Write-Host '|' -NoNewline -ForegroundColor Cyan
    Write-Host $hostStr -NoNewline -ForegroundColor Gray
    Write-Host $privStr -NoNewline -ForegroundColor $privCol
    Write-Host (' ' * $rem) -NoNewline
    Write-Host '|' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-TuiStepStart {
    param(
        [int]$Index,
        [int]$Total,
        [string]$Title
    )
    $pct = if ($Total -gt 0) { [int][Math]::Round((($Index - 1) / [double]$Total) * 100) } else { 0 }
    try {
        Write-Progress -Activity "$($script:ToolName) v$($script:ToolVersion)" -Status ("[$Index/$Total] $Title") -PercentComplete $pct
    } catch {}

    $script:CurrentStepRow = -1
    if (Test-InteractiveConsole) {
        try { $script:CurrentStepRow = [Console]::CursorTop } catch { $script:CurrentStepRow = -1 }
    }
    Write-Host '  ' -NoNewline
    Write-TuiStatusTag -Status 'RUN' -NoNewline
    Write-Host (" [{0}/{1}] {2}..." -f $Index, $Total, $Title) -ForegroundColor Cyan
}

function Complete-TuiStep {
    param(
        [int]$Index,
        [int]$Total,
        [string]$Title,
        [string]$Status = 'PASS',
        [string]$Summary = '',
        [double]$Seconds = 0.0
    )
    if ($script:CurrentStepRow -ge 0 -and (Test-InteractiveConsole)) {
        try {
            [Console]::SetCursorPosition(0, $script:CurrentStepRow)
            Write-Host (' ' * 76) -NoNewline
            [Console]::SetCursorPosition(0, $script:CurrentStepRow)
        } catch {}
    }

    $titlePad = Format-TuiPad -Text ("[{0}/{1}] {2}" -f $Index, $Total, $Title) -Width 31
    $sumPad   = Format-TuiPad -Text $Summary -Width 41
    $secStr   = ("{0,5:0.0}s" -f $Seconds)

    Write-Host '  ' -NoNewline
    Write-TuiStatusTag -Status $Status -NoNewline
    Write-Host (' ' + $titlePad + ' ') -NoNewline -ForegroundColor White
    Write-Host $sumPad -NoNewline -ForegroundColor Gray
    Write-Host (' ' + $secStr) -ForegroundColor DarkGray
}

function Show-TuiExecutiveSummary {
    param(
        $ReportData,
        [string]$ReportPath
    )
    $w = 88
    $top = '+' + ('=' * $w) + '+'
    $mid = '+' + ('-' * $w) + '+'
    $s    = $ReportData.Scoring
    $sys  = $ReportData.System
    $corp = $ReportData.CorporateLock
    $cpu  = $ReportData.Cpu
    $gpu  = $ReportData.Gpu
    $ram  = $ReportData.Ram
    $stor = $ReportData.Storage
    $bat  = $ReportData.Battery
    $per  = $ReportData.Peripherals

    $vColor = switch ($s.Verdict) {
        'BUY'        { 'Green' }
        'CAUTION'    { 'Yellow' }
        'DO NOT BUY' { 'Red' }
        default      { 'White' }
    }
    $vBanner = switch ($s.Verdict) {
        'BUY'        { 'APPROVED TO BUY (CLEAN & HEALTHY)' }
        'CAUTION'    { 'BUY WITH CAUTION / NEGOTIATE' }
        'DO NOT BUY' { 'DO NOT BUY - CRITICAL ISSUE' }
        default      { $s.Verdict }
    }

    Write-Host ''
    Write-Host $top -ForegroundColor Cyan
    Write-Host ('|' + (Format-TuiPad -Text ("  EXECUTIVE BUYER SCORECARD  |  {0} {1}" -f $sys.Manufacturer, $sys.Model) -Width $w) + '|') -ForegroundColor White
    Write-Host $mid -ForegroundColor Cyan

    # Verdict & Gauge line (guaranteed <= 88 chars)
    $bar = Format-TuiBar -Percent $s.Score -Width 18
    $vLineLeft = ("  VERDICT : {0}" -f $vBanner)
    $vLineRight = ("Score: {0,3}/100 {1}  " -f $s.Score, $bar)
    $gap1 = [Math]::Max(1, $w - $vLineLeft.Length - $vLineRight.Length)
    Write-Host '|' -NoNewline -ForegroundColor Cyan
    Write-Host $vLineLeft -NoNewline -ForegroundColor $vColor
    Write-Host (' ' * $gap1) -NoNewline
    Write-Host $vLineRight -NoNewline -ForegroundColor White
    Write-Host '|' -ForegroundColor Cyan

    $idLine = ("  Serial  : {0}  |  BIOS: {1} ({2})  |  Scan: {3}s" -f $sys.SerialNumber, $sys.BiosVersion, $sys.BiosDate, $ReportData.Meta.DurationSeconds)
    Write-Host ('|' + (Format-TuiPad -Text $idLine -Width $w) + '|') -ForegroundColor Gray
    Write-Host $mid -ForegroundColor Cyan

    # Section A: Corporate Lock 8-Point Matrix
    $lockTitle = if ($corp.ConfirmedCorporateLock) { '  CORPORATE LOCK AUDIT : [LOCKED / MANAGED - HIGH RISK]' } else { '  CORPORATE LOCK AUDIT : [NO LOCAL LOCK DETECTED]' }
    $lockCol   = if ($corp.ConfirmedCorporateLock) { 'Red' } else { 'Green' }
    Write-Host ('|' + (Format-TuiPad -Text $lockTitle -Width $w) + '|') -ForegroundColor $lockCol

    $cRow1 = ("    Autopilot : {0,-11} | Entra/AD Join : {1,-11} | Intune/MDM : {2,-11}" -f $corp.Autopilot.Status, $corp.DomainJoinStatus, $corp.Mdm.Status)
    $cRow2 = ("    Computrace: {0,-11} | BIOS Password : {1,-11} | BitLocker  : {2,-11}" -f $corp.Computrace.Status, $corp.BiosSecurity.Status, $corp.BitLocker.Status)
    $cRow3 = ("    RMM / EDR : {0,-11} | Win License   : {1,-18} | OEM Key : {2}" -f $corp.RmmEdr.Status, ("{0} ({1})" -f $corp.Activation.LicenseStatus, $corp.Activation.Channel), $(if ($corp.Activation.HasOemFirmwareKey) { 'Present' } else { 'None' }))
    Write-Host ('|' + (Format-TuiPad -Text $cRow1 -Width $w) + '|') -ForegroundColor Gray
    Write-Host ('|' + (Format-TuiPad -Text $cRow2 -Width $w) + '|') -ForegroundColor Gray
    Write-Host ('|' + (Format-TuiPad -Text $cRow3 -Width $w) + '|') -ForegroundColor Gray
    Write-Host $mid -ForegroundColor Cyan

    # Section B: Hardware Summary
    Write-Host ('|' + (Format-TuiPad -Text '  HARDWARE & BENCHMARK TELEMETRY' -Width $w) + '|') -ForegroundColor Cyan

    $cpuStressTxt = if ($cpu.StressSkipped) { 'Stress=Skipped' } elseif ($cpu.VerificationPassed) { "Int+FP=PASS ($($cpu.IntOpsPerSec)/s)" } else { 'Int+FP=FAIL!' }
    $cpuTempTxt   = if ($null -ne $cpu.PeakTempC) { "Peak=$($cpu.PeakTempC)C" } else { 'Temp=N/A' }
    $hwCpu = ("    CPU     : {0} ({1}C/{2}T) | {3} | {4}" -f $cpu.CpuName, $cpu.PhysicalCores, $cpu.LogicalProcessors, $cpuStressTxt, $cpuTempTxt)

    $gpuNames = @($gpu.Gpus | Sort-Object { $_.Type -ne 'Discrete GPU' } | ForEach-Object { "$($_.Name) [$($_.VramGB)GB$(if ($_.ErrorCode -ne 0) { ", Err=$($_.ErrorCode)" })]" }) -join '; '
    $hwGpu = ("    GPU     : {0}" -f $(if ($gpuNames) { $gpuNames } else { 'None' }))

    $ramUp = if ($ram.FreeSlots -gt 0) { "$($ram.FreeSlots) free slot(s)" } elseif ($ram.SolderedDetected) { 'Soldered' } else { '0 free slots' }
    $hwRam = ("    RAM     : {0} GB ({1}/{2} slots, {3}) | 128MB Pattern: {4}" -f $ram.TotalGB, $ram.UsedSlots, $ram.TotalSlots, $ramUp, $ram.PatternTest.Status)

    $diskList = @($stor.Disks | Where-Object { -not $_.IsExternal } | ForEach-Object {
        $wStr = if ($null -ne $_.WearPercent) { "Wear=$($_.WearPercent)%" } else { 'Wear=N/A' }
        "$($_.FriendlyName) ($($_.SizeGB)GB, $($_.HealthStatus), $wStr)"
    }) -join '; '
    $benchTxt = if ($stor.Benchmark -and $stor.Benchmark.SeqReadMBs) { "R:$($stor.Benchmark.SeqReadMBs) W:$($stor.Benchmark.SeqWriteMBs) MB/s" } else { 'Bench=Skipped' }
    $hwDisk = ("    Storage : {0} | {1}" -f $(if ($diskList) { $diskList } else { 'None' }), $benchTxt)

    $batTxt = if ($bat.BatteryCount -eq 0) {
        $bat.Condition
    } else {
        ("{0}% Health ({1}) | Cycles: {2} | Charge: {3}% | AC: {4}" -f $bat.OverallHealthPercent, $bat.Condition, $(if ($null -ne $bat.MaxCycleCount) { $bat.MaxCycleCount } else { 'N/A' }), $bat.CurrentChargePercent, $(if ($bat.AcOnline) { 'Online' } else { 'Battery' }))
    }
    $hwBat = ("    Battery : {0}" -f $batTxt)

    $actErrCount = @($per.DeviceErrors | Where-Object { -not $_.IsDisabled }).Count
    $gwTxt = if ($per.Network.GatewayIp) { "$($per.Network.GatewayIp) ($(if ($per.Network.GatewayReachable) { "$($per.Network.GatewayLatencyMs)ms" } else { 'Unreachable' }))" } else { 'No Gateway' }
    $hwPer = ("    Network : {0} | Gateway: {1} | DevMgr Errors: {2}" -f $per.Network.WifiGeneration, $gwTxt, $actErrCount)

    foreach ($row in @($hwCpu, $hwGpu, $hwRam, $hwDisk, $hwBat, $hwPer)) {
        Write-Host ('|' + (Format-TuiPad -Text $row -Width $w) + '|') -ForegroundColor White
    }

    if ($s.CriticalFlags.Count -gt 0) {
        Write-Host $mid -ForegroundColor Cyan
        Write-Host ('|' + (Format-TuiPad -Text '  CRITICAL REASONS TO REJECT:' -Width $w) + '|') -ForegroundColor Red
        foreach ($cf in $s.CriticalFlags) {
            Write-Host ('|' + (Format-TuiPad -Text ("    [X] " + $cf) -Width $w) + '|') -ForegroundColor Red
        }
    }
    if ($s.Warnings.Count -gt 0) {
        Write-Host $mid -ForegroundColor Cyan
        Write-Host ('|' + (Format-TuiPad -Text '  WARNINGS / NEGOTIATION POINTS:' -Width $w) + '|') -ForegroundColor Yellow
        foreach ($wn in $s.Warnings) {
            Write-Host ('|' + (Format-TuiPad -Text ("    [!] " + $wn) -Width $w) + '|') -ForegroundColor Yellow
        }
    }

    Write-Host $mid -ForegroundColor Cyan
    Write-Host ('|' + (Format-TuiPad -Text ("  Report  : " + (Split-Path -Leaf $ReportPath)) -Width $w) + '|') -ForegroundColor Cyan
    Write-Host ('|' + (Format-TuiPad -Text ("  Folder  : " + (Split-Path -Parent $ReportPath)) -Width $w) + '|') -ForegroundColor DarkGray
    Write-Host $top -ForegroundColor Cyan
}

function Build-PlainTextSummaryFromPs {
    param($ReportData)
    $s   = $ReportData.Scoring
    $sys = $ReportData.System
    $corp = $ReportData.CorporateLock
    $cpu = $ReportData.Cpu
    $gpu = $ReportData.Gpu
    $ram = $ReportData.Ram
    $stor = $ReportData.Storage
    $bat = $ReportData.Battery

    $lines = @()
    $lines += "=== LAPTOP INSPECT v$($ReportData.Meta.ToolVersion) REPORT ==="
    $lines += "Verdict: $($s.Verdict) ($($s.Score)/100)"
    $lines += "Model: $($sys.Manufacturer) $($sys.Model) | Serial: $($sys.SerialNumber)"
    $lines += "Corporate Lock: $(if ($corp.ConfirmedCorporateLock) { 'LOCKED / MANAGED' } else { 'No Local Lock' }) (Autopilot=$($corp.Autopilot.Status), MDM=$($corp.Mdm.Status), Computrace=$($corp.Computrace.Status), BIOS-Pwd=$($corp.BiosSecurity.Status), BitLocker=$($corp.BitLocker.Status))"
    $lines += "CPU: $($cpu.CpuName) ($($cpu.PhysicalCores)C/$($cpu.LogicalProcessors)T)"
    $lines += "GPU: " + ((@($gpu.Gpus | ForEach-Object { "$($_.Name) ($($_.VramGB)GB)" })) -join '; ')
    $lines += "RAM: $($ram.TotalGB) GB ($($ram.UsedSlots)/$($ram.TotalSlots) slots)"
    $lines += "Storage: " + ((@($stor.Disks | Where-Object { -not $_.IsExternal } | ForEach-Object { "$($_.FriendlyName) $($_.SizeGB)GB [$($_.HealthStatus)]" })) -join '; ')
    $lines += "Battery: $(if ($bat.BatteryCount -gt 0) { "$($bat.OverallHealthPercent)% ($($bat.Condition), Cycles=$($bat.MaxCycleCount))" } else { $bat.Condition })"
    if ($s.CriticalFlags.Count -gt 0) { $lines += "CRITICAL: " + ($s.CriticalFlags -join ' | ') }
    if ($s.Warnings.Count -gt 0) { $lines += "WARNINGS: " + ($s.Warnings -join ' | ') }
    return ($lines -join "`r`n")
}

function Invoke-TuiSilentInstallerMenu {
    if (-not (Test-InteractiveConsole)) { return }
    $presets = @(Get-AppPresets)
    $catalog = @(Get-AppCatalog)
    $wg = Get-WingetInfo

    while ($true) {
        try { Clear-Host } catch {}
        Show-TuiHeader -Subtitle 'Silent Zero-Prompt Software Installer (Ninite / WinUtil Style)'
        $wgTxt = if ($wg.Available) { "Winget Ready ($($wg.Version))" } else { 'Winget Not Found (Will Auto-Bootstrap on Install)' }
        Write-Host ("  Engine : {0}  |  Flags: --silent --accept-package-agreements --disable-interactivity" -f $wgTxt) -ForegroundColor Gray
        Write-Host ''
        Write-Host '  ONE-CLICK PRESETS (Instant Zero-Prompt Install):' -ForegroundColor Cyan
        for ($i = 0; $i -lt $presets.Count; $i++) {
            $p = $presets[$i]
            Write-Host ("    [{0}] {1,-22} - {2} ({3})" -f ($i + 1), $p.Name, $p.Desc, ($p.Apps -join ', ')) -ForegroundColor White
        }
        Write-Host ''
        Write-Host '  CUSTOM & MAINTENANCE:' -ForegroundColor Cyan
        Write-Host '    [5] Interactive App Checklist (Toggle any of the 39 apps with Spacebar)' -ForegroundColor White
        Write-Host '    [6] Enter Custom Winget Package IDs or Short Keys' -ForegroundColor White
        Write-Host '    [7] Upgrade All Currently Installed Apps Silently (winget upgrade --all)' -ForegroundColor White
        Write-Host '    [D] Dry-Run Preview Mode (Test commands without installing)' -ForegroundColor DarkCyan
        Write-Host '    [B] Back / Exit Installer Menu' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Select option [1-7, D, B]: ' -NoNewline -ForegroundColor Cyan

        $k = [Console]::ReadKey($true)
        $ch = $k.KeyChar.ToString().ToUpperInvariant()
        Write-Host $ch

        if ($ch -eq 'B' -or $k.Key -eq [ConsoleKey]::Escape) {
            return
        } elseif ($ch -in @('1','2','3','4')) {
            $pIdx = [int]$ch - 1
            $chosenPreset = $presets[$pIdx]
            $targets = @(Resolve-InstallTargets -Preset $chosenPreset.Key)
            Write-Host ''
            Write-Host ("  [+] Starting Silent Preset '{0}' ({1} packages)..." -f $chosenPreset.Name, $targets.Count) -ForegroundColor Green
            $res = @(Invoke-SilentAppInstallBatch -Targets $targets -ConsoleOutput)
            Write-Host ''
            foreach ($r in $res) {
                Write-Host '    ' -NoNewline
                Write-TuiStatusTag -Status $(if ($r.Success) { 'OK' } else { 'FAIL' }) -NoNewline
                Write-Host (" {0} ({1}) -> {2}" -f $r.Name, $r.WingetId, $r.Status)
            }
            Write-Host ''
            Read-Host '  Press Enter to return to Installer Menu' | Out-Null
        } elseif ($ch -eq 'D') {
            $targets = @(Resolve-InstallTargets -Preset 'essentials')
            Write-Host ''
            Write-Host '  [+] Running Dry-Run Preview for Resale Essentials...' -ForegroundColor Cyan
            [void](Invoke-SilentAppInstallBatch -Targets $targets -DryRun -ConsoleOutput)
            Write-Host ''
            Read-Host '  Press Enter to return to Installer Menu' | Out-Null
        } elseif ($ch -eq '6') {
            Write-Host ''
            $rawInput = Read-Host '  Enter short keys or Winget IDs (comma-separated, e.g. chrome,vlc,7zip)'
            if (-not [string]::IsNullOrWhiteSpace($rawInput)) {
                try {
                    $targets = @(Resolve-InstallTargets -KeysOrIds @($rawInput))
                    if ($targets.Count -gt 0) {
                        $res = @(Invoke-SilentAppInstallBatch -Targets $targets -ConsoleOutput)
                        Write-Host ''
                        foreach ($r in $res) {
                            Write-Host '    ' -NoNewline
                            Write-TuiStatusTag -Status $(if ($r.Success) { 'OK' } else { 'FAIL' }) -NoNewline
                            Write-Host (" {0} -> {1}" -f $r.Name, $r.Status)
                        }
                    }
                } catch {
                    Write-Host ("  [!] " + $_.Exception.Message) -ForegroundColor Red
                }
                Read-Host '  Press Enter to continue' | Out-Null
            }
        } elseif ($ch -eq '7') {
            Write-Host ''
            Write-Host '  [+] Running silent winget upgrade --all...' -ForegroundColor Green
            $res = @(Invoke-SilentAppInstallBatch -UpgradeAll -ConsoleOutput)
            Read-Host '  Press Enter to continue' | Out-Null
        } elseif ($ch -eq '5') {
            Invoke-TuiAppChecklistPicker -Catalog $catalog
        }
    }
}

function Invoke-TuiAppChecklistPicker {
    param([array]$Catalog)
    $selected = @{}
    $cursor = 0
    $pageSize = 15
    $total = $Catalog.Count

    while ($true) {
        try { Clear-Host } catch {}
        $selCount = @($selected.Keys | Where-Object { $selected[$_] }).Count
        Show-TuiHeader -Subtitle ("Interactive App Picker  |  Selected: $selCount / $total apps")
        Write-Host '  Controls: [Up/Down] Move  [Space] Toggle  [E] Essentials  [C] Clear  [Enter] Install  [Esc] Back' -ForegroundColor Yellow
        Write-Host ''

        $startIdx = [Math]::Floor($cursor / $pageSize) * $pageSize
        $endIdx = [Math]::Min($total - 1, $startIdx + $pageSize - 1)
        $pageNum = [int]([Math]::Floor($cursor / $pageSize) + 1)
        $totalPages = [int][Math]::Ceiling($total / [double]$pageSize)

        Write-Host ("  Page {0}/{1}:" -f $pageNum, $totalPages) -ForegroundColor DarkCyan
        for ($i = $startIdx; $i -le $endIdx; $i++) {
            $app = $Catalog[$i]
            $isCur = ($i -eq $cursor)
            $isChk = [bool]$selected[$app.Key]
            $box = if ($isChk) { '[X]' } else { '[ ]' }
            $ptr = if ($isCur) { ' > ' } else { '   ' }
            $line = ("{0}{1} {2,-22} [{3,-22}] {4}" -f $ptr, $box, $app.Name, $app.Category, $app.Desc)
            if ($isCur) {
                Write-Host (Format-TuiPad -Text $line -Width 76) -ForegroundColor Black -BackgroundColor Cyan
            } elseif ($isChk) {
                Write-Host $line -ForegroundColor Green
            } else {
                Write-Host $line -ForegroundColor Gray
            }
        }

        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Escape -or $key.KeyChar -eq 'b' -or $key.KeyChar -eq 'B') {
            return
        } elseif ($key.Key -eq [ConsoleKey]::UpArrow) {
            $cursor = ($cursor - 1 + $total) % $total
        } elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
            $cursor = ($cursor + 1) % $total
        } elseif ($key.Key -eq [ConsoleKey]::PageDown) {
            $cursor = [Math]::Min($total - 1, $cursor + $pageSize)
        } elseif ($key.Key -eq [ConsoleKey]::PageUp) {
            $cursor = [Math]::Max(0, $cursor - $pageSize)
        } elseif ($key.Key -eq [ConsoleKey]::Spacebar) {
            $k = $Catalog[$cursor].Key
            $selected[$k] = -not [bool]$selected[$k]
        } elseif ($key.KeyChar -eq 'c' -or $key.KeyChar -eq 'C') {
            $selected = @{}
        } elseif ($key.KeyChar -eq 'e' -or $key.KeyChar -eq 'E') {
            $selected = @{}
            foreach ($ak in @('chrome','vlc','7zip','sumatra','vcredist64','vcredist86','dotnet8','directx')) { $selected[$ak] = $true }
        } elseif ($key.Key -eq [ConsoleKey]::Enter) {
            $pickedKeys = @($selected.Keys | Where-Object { $selected[$_] })
            if ($pickedKeys.Count -eq 0) {
                continue
            }
            Write-Host ''
            $targets = @(Resolve-InstallTargets -KeysOrIds $pickedKeys)
            Write-Host ("  [+] Installing {0} selected app(s) silently..." -f $targets.Count) -ForegroundColor Green
            $res = @(Invoke-SilentAppInstallBatch -Targets $targets -ConsoleOutput)
            Write-Host ''
            foreach ($r in $res) {
                Write-Host '    ' -NoNewline
                Write-TuiStatusTag -Status $(if ($r.Success) { 'OK' } else { 'FAIL' }) -NoNewline
                Write-Host (" {0} -> {1}" -f $r.Name, $r.Status)
            }
            Write-Host ''
            Read-Host '  Press Enter to return' | Out-Null
            return
        }
    }
}

function Invoke-TuiBatteryDrainMenu {
    if (-not (Test-InteractiveConsole)) { return }
    $modes = @('everyday', 'light', 'heavy')
    $modeIdx = 0
    $cutoff = 10

    while ($true) {
        $curMode = $modes[$modeIdx]
        $curSamp = Get-BatteryDischargeSample -ElapsedSec 0
        try { Clear-Host } catch {}
        Show-TuiHeader -Subtitle 'Real Timed Battery Endurance & Everyday Load Simulator'

        if ($null -eq $curSamp.ChargePct) {
            Write-Host ''
            Write-Host '  [!] No battery detected on this system.' -ForegroundColor Red
            Write-Host ''
            Read-Host '  Press Enter to return to Main Menu' | Out-Null
            return
        }

        $acState = if ($curSamp.PowerOnline) { 'Plugged In (Unplug AC before starting)' } else { 'On Battery (Ready)' }
        $acCol = if ($curSamp.PowerOnline) { 'Yellow' } else { 'Green' }
        Write-Host ("  Battery Now : {0}%  |  Voltage: {1} mV  |  AC: " -f $curSamp.ChargePct, $(if ($curSamp.VoltageMv) { $curSamp.VoltageMv } else { 'N/A' })) -NoNewline -ForegroundColor White
        Write-Host $acState -ForegroundColor $acCol
        Write-Host ("  Load Profile: {0}  |  Safety Cutoff: {1}%  ([M]=Cycle Load)" -f $curMode.ToUpperInvariant(), $cutoff) -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  SELECT TIMER DURATION:' -ForegroundColor Cyan
        Write-Host '    [1]  5 min  - Quick Buyer Cell-Drop Check' -ForegroundColor White
        Write-Host '    [2] 15 min  - Standard Everyday Endurance Check' -ForegroundColor White
        Write-Host '    [3] 30 min  - Extended Everyday Use Test' -ForegroundColor White
        Write-Host '    [4] 60 min  - Deep Endurance Test' -ForegroundColor White
        Write-Host ("    [5] Full Drain - Run until {0}% safety cutoff" -f $cutoff) -ForegroundColor White
        Write-Host '    [6] Custom Minutes (1..240 min)' -ForegroundColor White
        Write-Host '    [M] Switch Load Profile (everyday / light / heavy)' -ForegroundColor DarkCyan
        Write-Host '    [B] Back to Main Menu' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Select option [1-6, M, B]: ' -NoNewline -ForegroundColor Cyan

        $k = [Console]::ReadKey($true)
        $ch = $k.KeyChar.ToString().ToUpperInvariant()
        Write-Host $ch

        if ($ch -eq 'B' -or $k.Key -eq [ConsoleKey]::Escape) {
            return
        } elseif ($ch -eq 'M') {
            $modeIdx = ($modeIdx + 1) % $modes.Count
            continue
        }

        $mins = 0
        switch ($ch) {
            '1' { $mins = 5 }
            '2' { $mins = 15 }
            '3' { $mins = 30 }
            '4' { $mins = 60 }
            '5' { $mins = -1 }
            '6' {
                $rawM = Read-Host '  Enter minutes (1..240)'
                if ($rawM -match '^\d+$') { $mins = [int]$rawM }
            }
        }
        if ($mins -eq 0) { continue }

        Write-Host ''
        Write-Host ("  [+] Starting Timed Battery Drain ({0} mode, cutoff {1}%)..." -f $curMode, $cutoff) -ForegroundColor Green
        $sum = Invoke-TimedBatteryDrainTest -Minutes $mins -CutoffPct $cutoff -LoadMode $curMode -ConsoleLive
        Write-Host ''
        Write-Host '  === Battery Endurance Summary ===' -ForegroundColor Cyan
        Write-Host '  Status       : ' -NoNewline
        Write-TuiStatusTag -Status $sum.Status -NoNewline
        Write-Host (" ({0})" -f $sum.StopReason)
        Write-Host ("  Elapsed      : {0} min ({1} samples)" -f $sum.ElapsedMinutes, $sum.SampleCount) -ForegroundColor White
        Write-Host ("  Charge Drop  : {0}% -> {1}% (-{2}%)" -f $sum.StartPct, $sum.EndPct, $sum.DropPct) -ForegroundColor White
        $avgWStr = if ($null -ne $sum.AvgDischargeWatts) { "$($sum.AvgDischargeWatts) W (Peak $($sum.PeakDischargeWatts) W)" } else { 'N/A' }
        Write-Host ("  Power Draw   : {0}  |  Min Voltage: {1} mV (Sag {2}%)" -f $avgWStr, $(if ($sum.MinVoltageMv) { $sum.MinVoltageMv } else { 'N/A' }), $sum.VoltageSagPct) -ForegroundColor White
        $estStr = if ($null -ne $sum.EstimatedRuntimeFrom100Minutes) { ("~{0} min ({1} hrs)" -f $sum.EstimatedRuntimeFrom100Minutes, [Math]::Round($sum.EstimatedRuntimeFrom100Minutes / 60.0, 1)) } else { 'Need >=1% drop or WMI rate' }
        Write-Host ("  Est. 100->0% : {0}" -f $estStr) -ForegroundColor Green
        if ($sum.SuddenDropDetected) {
            Write-Host ("  [X] DEAD CELL ALERT: Sudden drop {0}" -f $sum.SuddenDropDetail) -ForegroundColor Red
        }
        Write-Host ''
        Read-Host '  Press Enter to return' | Out-Null
    }
}

function Show-TuiMainMenu {
    param([bool]$IsAdmin = (Test-IsAdmin))

    $options = @(
        [PSCustomObject]@{ Key='1'; Action='FullAudit';    Title='[1] Full Pre-Purchase Audit + Interactive Report'; Desc='Recommended: Corporate Locks + 10s Stress + Browser Wizard (~20s)' },
        [PSCustomObject]@{ Key='2'; Action='QuickAudit';   Title='[2] Quick Audit + Interactive Report';             Desc='Fast: Skips CPU/RAM/Disk Stress Benchmarks (~7s)' },
        [PSCustomObject]@{ Key='3'; Action='TerminalOnly'; Title='[3] Terminal-Only Quick Scorecard (No Browser)';   Desc='Headless: Fast Corporate Lock + Hardware Scorecard in Console' },
        [PSCustomObject]@{ Key='4'; Action='InstallerTui'; Title='[4] Silent App Installer TUI (Ninite / WinUtil)';  Desc='Zero Prompts: Pick Presets or 39 Apps with Arrow Keys & Spacebar' },
        [PSCustomObject]@{ Key='5'; Action='AuditAndEss';  Title='[5] Full Audit + Auto-Install Resale Essentials';  Desc='All-in-One: Inspect Laptop & Silently Install 8 Buyer Essentials' },
        [PSCustomObject]@{ Key='6'; Action='UpgradeAll';   Title='[6] Silent Upgrade All Existing Apps';             Desc='Runs winget upgrade --all with zero Next/Accept prompts' },
        [PSCustomObject]@{ Key='7'; Action='BatteryTui';   Title='[7] Timed Battery Drain Test (Everyday Load + Timer)'; Desc='Real Unplugged Endurance: 5m..60m or Full Drain w/ Live Chart & Timer' }
    )
    if (-not $IsAdmin) {
        $options += [PSCustomObject]@{ Key='E'; Action='Elevate'; Title='[E] Relaunch as Administrator (Recommended)'; Desc='Unlocks Vendor BIOS WMI, BitLocker, MDM CIM, and SSD SMART Wear' }
    }
    $options += [PSCustomObject]@{ Key='0'; Action='Exit'; Title='[0] Exit LaptopInspect'; Desc='Close without running' }

    $idx = 0
    while ($true) {
        try { Clear-Host } catch {}
        Show-TuiHeader -IsAdmin $IsAdmin
        Write-Host '  Use [Up/Down] Arrows + [Enter], or press hotkey [1-7, E, 0]:' -ForegroundColor Yellow
        Write-Host ''

        for ($i = 0; $i -lt $options.Count; $i++) {
            $opt = $options[$i]
            if ($i -eq $idx) {
                $barLine = Format-TuiPad -Text ("  > " + $opt.Title) -Width 90
                Write-Host $barLine -ForegroundColor Black -BackgroundColor Cyan
                Write-Host ("      " + $opt.Desc) -ForegroundColor Cyan
            } else {
                Write-Host ("    " + $opt.Title) -ForegroundColor White
                Write-Host ("      " + $opt.Desc) -ForegroundColor DarkGray
            }
            Write-Host ''
        }

        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::UpArrow) {
            $idx = ($idx - 1 + $options.Count) % $options.Count
        } elseif ($k.Key -eq [ConsoleKey]::DownArrow) {
            $idx = ($idx + 1) % $options.Count
        } elseif ($k.Key -eq [ConsoleKey]::Enter) {
            return $options[$idx].Action
        } elseif ($k.Key -eq [ConsoleKey]::Escape) {
            return 'Exit'
        } else {
            $ch = $k.KeyChar.ToString().ToUpperInvariant()
            $matched = $options | Where-Object { $_.Key -eq $ch } | Select-Object -First 1
            if ($matched) { return $matched.Action }
        }
    }
}
