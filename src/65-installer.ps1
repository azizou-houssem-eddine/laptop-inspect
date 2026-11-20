function Get-AppCatalog {
    return @(
        # Browsers
        [PSCustomObject]@{ Key='chrome';  Name='Google Chrome';   WingetId='Google.Chrome';   Source='winget'; Category='Browsers'; Desc='Popular fast web browser' },
        [PSCustomObject]@{ Key='firefox'; Name='Mozilla Firefox'; WingetId='Mozilla.Firefox'; Source='winget'; Category='Browsers'; Desc='Open-source privacy browser' },
        [PSCustomObject]@{ Key='brave';   Name='Brave Browser';   WingetId='Brave.Brave';     Source='winget'; Category='Browsers'; Desc='Ad-blocking Chromium browser' },

        # Essentials & Office
        [PSCustomObject]@{ Key='7zip';        Name='7-Zip';           WingetId='7zip.7zip';                         Source='winget'; Category='Essentials & Office'; Desc='Open-source archive extractor' },
        [PSCustomObject]@{ Key='winrar';      Name='WinRAR';          WingetId='RARLab.WinRAR';                     Source='winget'; Category='Essentials & Office'; Desc='RAR/ZIP archiver' },
        [PSCustomObject]@{ Key='acrobat';     Name='Adobe Acrobat';   WingetId='Adobe.Acrobat.Reader.64-bit';       Source='winget'; Category='Essentials & Office'; Desc='Standard PDF reader (64-bit)' },
        [PSCustomObject]@{ Key='sumatra';     Name='SumatraPDF';      WingetId='SumatraPDF.SumatraPDF';             Source='winget'; Category='Essentials & Office'; Desc='Ultra-fast lightweight PDF viewer' },
        [PSCustomObject]@{ Key='libreoffice'; Name='LibreOffice';     WingetId='TheDocumentFoundation.LibreOffice'; Source='winget'; Category='Essentials & Office'; Desc='Free full Office suite' },
        [PSCustomObject]@{ Key='notepadpp';   Name='Notepad++';       WingetId='Notepad++.Notepad++';               Source='winget'; Category='Essentials & Office'; Desc='Fast code and text editor' },

        # Media & Codecs
        [PSCustomObject]@{ Key='vlc';     Name='VLC Media Player';   WingetId='VideoLAN.VLC';                      Source='winget'; Category='Media & Codecs'; Desc='Plays almost any video or audio' },
        [PSCustomObject]@{ Key='klite';   Name='K-Lite Codec Pack';  WingetId='CodecGuide.K-LiteCodecPack.Standard'; Source='winget'; Category='Media & Codecs'; Desc='Complete Windows video/audio codecs' },
        [PSCustomObject]@{ Key='spotify'; Name='Spotify';            WingetId='Spotify.Spotify';                   Source='winget'; Category='Media & Codecs'; Desc='Music streaming desktop client' },

        # Runtimes
        [PSCustomObject]@{ Key='vcredist64'; Name='VC++ Redist (x64)';    WingetId='Microsoft.VCRedist.2015+.x64';    Source='winget'; Category='Runtimes'; Desc='Visual C++ 2015-2022 64-bit runtime' },
        [PSCustomObject]@{ Key='vcredist86'; Name='VC++ Redist (x86)';    WingetId='Microsoft.VCRedist.2015+.x86';    Source='winget'; Category='Runtimes'; Desc='Visual C++ 2015-2022 32-bit runtime' },
        [PSCustomObject]@{ Key='dotnet8';    Name='.NET 8 Desktop';       WingetId='Microsoft.DotNet.DesktopRuntime.8'; Source='winget'; Category='Runtimes'; Desc='.NET 8 WPF/WinForms runtime' },
        [PSCustomObject]@{ Key='directx';    Name='DirectX Runtime';      WingetId='Microsoft.DirectX';               Source='winget'; Category='Runtimes'; Desc='Legacy DirectX end-user libraries' },
        [PSCustomObject]@{ Key='java';       Name='Java Runtime (JRE)';   WingetId='Oracle.JavaRuntimeEnvironment';   Source='winget'; Category='Runtimes'; Desc='Oracle Java runtime environment' },

        # Hardware Bench
        [PSCustomObject]@{ Key='hwinfo';          Name='HWiNFO';          WingetId='REALiX.HWiNFO';                  Source='winget'; Category='Hardware Bench'; Desc='Deep hardware sensor & clock telemetry' },
        [PSCustomObject]@{ Key='crystaldiskinfo'; Name='CrystalDiskInfo'; WingetId='CrystalDewWorld.CrystalDiskInfo'; Source='winget'; Category='Hardware Bench'; Desc='Detailed SSD/HDD SMART attributes' },
        [PSCustomObject]@{ Key='crystaldiskmark'; Name='CrystalDiskMark'; WingetId='CrystalDewWorld.CrystalDiskMark'; Source='winget'; Category='Hardware Bench'; Desc='Storage sequential & 4K benchmark' },
        [PSCustomObject]@{ Key='cpuz';            Name='CPU-Z';           WingetId='CPUID.CPU-Z';                    Source='winget'; Category='Hardware Bench'; Desc='CPU, cache, and memory SPD inspector' },
        [PSCustomObject]@{ Key='gpuz';            Name='GPU-Z';           WingetId='TechPowerUp.GPU-Z';              Source='winget'; Category='Hardware Bench'; Desc='GPU ROPs, shaders, VBIOS & bus check' },
        [PSCustomObject]@{ Key='occt';            Name='OCCT';            WingetId='OCBase.OCCT.Personal';           Source='winget'; Category='Hardware Bench'; Desc='Combined CPU/GPU/VRAM stability stress' },
        [PSCustomObject]@{ Key='bleachbit';       Name='BleachBit';       WingetId='BleachBit.BleachBit';            Source='winget'; Category='Hardware Bench'; Desc='Open-source disk & privacy cleaner' },

        # Communication & Remote
        [PSCustomObject]@{ Key='whatsapp';   Name='WhatsApp';   WingetId='9NKSQGP7F2NH';              Source='msstore'; Category='Communication & Remote'; Desc='Official WhatsApp Desktop (MS Store)' },
        [PSCustomObject]@{ Key='zoom';       Name='Zoom';       WingetId='Zoom.Zoom';                 Source='winget';  Category='Communication & Remote'; Desc='Video meetings & screen sharing' },
        [PSCustomObject]@{ Key='discord';    Name='Discord';    WingetId='Discord.Discord';           Source='winget';  Category='Communication & Remote'; Desc='Voice, video, and text chat' },
        [PSCustomObject]@{ Key='telegram';   Name='Telegram';   WingetId='Telegram.TelegramDesktop';  Source='winget';  Category='Communication & Remote'; Desc='Fast desktop messaging client' },
        [PSCustomObject]@{ Key='anydesk';    Name='AnyDesk';    WingetId='AnyDesk.AnyDesk';           Source='winget';  Category='Communication & Remote'; Desc='Lightweight remote desktop support' },
        [PSCustomObject]@{ Key='teamviewer'; Name='TeamViewer'; WingetId='TeamViewer.TeamViewer';     Source='winget';  Category='Communication & Remote'; Desc='Remote access & support client' },

        # Utilities & Dev
        [PSCustomObject]@{ Key='everything';  Name='Everything Search'; WingetId='voidtools.Everything';       Source='winget'; Category='Utilities & Dev'; Desc='Instant NTFS file search' },
        [PSCustomObject]@{ Key='sharex';      Name='ShareX';            WingetId='ShareX.ShareX';              Source='winget'; Category='Utilities & Dev'; Desc='Open-source screenshot & recorder' },
        [PSCustomObject]@{ Key='greenshot';   Name='Greenshot';         WingetId='Greenshot.Greenshot';        Source='winget'; Category='Utilities & Dev'; Desc='Quick annotated screenshot tool' },
        [PSCustomObject]@{ Key='powertoys';   Name='MS PowerToys';      WingetId='Microsoft.PowerToys';        Source='winget'; Category='Utilities & Dev'; Desc='Windows power-user utilities' },
        [PSCustomObject]@{ Key='qbittorrent'; Name='qBittorrent';       WingetId='qBittorrent.qBittorrent';    Source='winget'; Category='Utilities & Dev'; Desc='Open-source ad-free torrent client' },
        [PSCustomObject]@{ Key='vscode';      Name='VS Code';           WingetId='Microsoft.VisualStudioCode'; Source='winget'; Category='Utilities & Dev'; Desc='Code editor & IDE' },
        [PSCustomObject]@{ Key='git';         Name='Git';               WingetId='Git.Git';                    Source='winget'; Category='Utilities & Dev'; Desc='Distributed version control' },
        [PSCustomObject]@{ Key='python';      Name='Python 3.12';       WingetId='Python.Python.3.12';         Source='winget'; Category='Utilities & Dev'; Desc='Python 3.12 runtime & pip' },
        [PSCustomObject]@{ Key='steam';       Name='Steam';             WingetId='Valve.Steam';                Source='winget'; Category='Utilities & Dev'; Desc='PC gaming storefront & launcher' }
    )
}

function Get-AppPresets {
    return @(
        [PSCustomObject]@{
            Key   = 'essentials'
            Name  = 'Resale Essentials'
            Desc  = 'Ready-to-deliver Windows buyer baseline'
            Apps  = @('chrome', 'vlc', '7zip', 'sumatra', 'vcredist64', 'vcredist86', 'dotnet8', 'directx')
        },
        [PSCustomObject]@{
            Key   = 'office'
            Name  = 'Office & Student'
            Desc  = 'Productivity, PDF, meetings, and messaging'
            Apps  = @('chrome', 'vlc', '7zip', 'acrobat', 'libreoffice', 'zoom', 'whatsapp', 'vcredist64')
        },
        [PSCustomObject]@{
            Key   = 'tech'
            Name  = 'Technician Bench'
            Desc  = 'Deep sensor, SMART, CPU/GPU, and stress tools'
            Apps  = @('hwinfo', 'crystaldiskinfo', 'crystaldiskmark', 'cpuz', 'gpuz', 'occt', '7zip', 'notepadpp', 'everything')
        },
        [PSCustomObject]@{
            Key   = 'dev'
            Name  = 'Developer Pack'
            Desc  = 'Coding, Git, Python, and power utilities'
            Apps  = @('chrome', 'vscode', 'git', 'python', '7zip', 'notepadpp', 'powertoys', 'everything')
        }
    )
}

function Test-SafeWingetId {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return ($Id.Trim() -cmatch '^[A-Za-z0-9][A-Za-z0-9\.\-\+_]{1,80}$')
}

function Resolve-InstallTargets {
    param(
        [string[]]$KeysOrIds = @(),
        [string]$Preset = ''
    )

    $catalog = Get-AppCatalog
    $byKey = @{}
    $byId = @{}
    foreach ($item in $catalog) {
        $byKey[$item.Key.ToLowerInvariant()] = $item
        $byId[$item.WingetId.ToLowerInvariant()] = $item
    }

    $tokens = @()
    if (-not [string]::IsNullOrWhiteSpace($Preset)) {
        $pKey = $Preset.Trim().ToLowerInvariant()
        $presetObj = Get-AppPresets | Where-Object { $_.Key -eq $pKey } | Select-Object -First 1
        if (-not $presetObj) {
            throw ("Unknown install preset: '{0}'. Valid presets: essentials, office, tech, dev." -f $Preset)
        }
        $tokens += @($presetObj.Apps)
    }

    foreach ($raw in $KeysOrIds) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $split = $raw -split ','
        foreach ($part in $split) {
            $t = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { $tokens += $t }
        }
    }

    $seen = @{}
    $targets = @()
    foreach ($t in $tokens) {
        $low = $t.ToLowerInvariant()
        $entry = $null
        if ($byKey.ContainsKey($low)) {
            $c = $byKey[$low]
            $entry = [PSCustomObject]@{ Key = $c.Key; Name = $c.Name; WingetId = $c.WingetId; Source = $c.Source }
        } elseif ($byId.ContainsKey($low)) {
            $c = $byId[$low]
            $entry = [PSCustomObject]@{ Key = $c.Key; Name = $c.Name; WingetId = $c.WingetId; Source = $c.Source }
        } else {
            if (-not (Test-SafeWingetId -Id $t)) {
                throw ("Invalid or unsafe Winget package ID: '{0}'" -f $t)
            }
            $src = if ($t -cmatch '^9[A-Z0-9]{11}$') { 'msstore' } else { 'winget' }
            $entry = [PSCustomObject]@{ Key = $low; Name = $t; WingetId = $t; Source = $src }
        }

        $dedupe = $entry.WingetId.ToLowerInvariant()
        if (-not $seen.ContainsKey($dedupe)) {
            $seen[$dedupe] = $true
            $targets += $entry
        }
    }

    return @($targets)
}

function Get-WingetInfo {
    $path = ''
    try {
        $cmd = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $path = $cmd.Source }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($path) -and $env:LOCALAPPDATA) {
        $cand = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $cand) { $path = $cand }
    }

    if ([string]::IsNullOrWhiteSpace($path) -and $env:ProgramFiles) {
        try {
            $found = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $path = $found.FullName }
        } catch {}
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        return [PSCustomObject]@{ Available = $false; Path = ''; Version = '' }
    }

    $ver = ''
    try {
        $vOut = & $path --version 2>$null
        if ($vOut) { $ver = ($vOut | Select-Object -First 1).ToString().Trim() }
    } catch {}

    return [PSCustomObject]@{
        Available = (-not [string]::IsNullOrWhiteSpace($ver))
        Path      = $path
        Version   = $ver
    }
}

function Ensure-WingetReady {
    param([switch]$AutoBootstrap)

    $info = Get-WingetInfo
    if ($info.Available -or -not $AutoBootstrap) { return $info }

    $tmpBundle = Join-Path $env:TEMP ("Microsoft.DesktopAppInstaller_{0}.msixbundle" -f $PID)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'LaptopInspect' } -TimeoutSec 15 -ErrorAction Stop
        $asset = $rel.assets | Where-Object { $_.name -match '\.msixbundle$' } | Select-Object -First 1
        if ($asset -and $asset.browser_download_url) {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpBundle -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            Add-AppxPackage -Path $tmpBundle -ErrorAction Stop
        }
    } catch {
        # Best-effort silent bootstrap
    } finally {
        if (Test-Path -LiteralPath $tmpBundle) {
            Remove-Item -LiteralPath $tmpBundle -Force -ErrorAction SilentlyContinue
        }
    }

    return (Get-WingetInfo)
}

function Build-WingetInstallArgs {
    param(
        [Parameter(Mandatory = $true)][string]$WingetId,
        [string]$Source = 'winget'
    )
    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = 'winget' }
    return @(
        'install',
        '--id', $WingetId,
        '--exact',
        '--source', $Source,
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
}

function Build-WingetUpgradeAllArgs {
    return @(
        'upgrade',
        '--all',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
}

function ConvertTo-WingetInstallResult {
    param(
        [int]$ExitCode,
        [string[]]$OutputLines = @()
    )

    $cleanLines = @()
    foreach ($line in $OutputLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $t = $line.Trim()
        if ($t -match '^[\-\|\\/\.\s]+$' -or $t -match '^\d+\s*(KB|MB|GB)\s*/') { continue }
        $cleanLines += $t
    }
    $detail = if ($cleanLines.Count -gt 0) { $cleanLines[$cleanLines.Count - 1] } else { '' }
    if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) }

    if ($ExitCode -eq 0) {
        return [PSCustomObject]@{ Success = $true; Status = 'Installed'; Detail = $detail; ExitCode = $ExitCode }
    } elseif ($ExitCode -eq -1978335189 -or $ExitCode -eq -1978335135) {
        return [PSCustomObject]@{ Success = $true; Status = 'Already Installed'; Detail = 'Latest version already installed'; ExitCode = $ExitCode }
    } elseif ($ExitCode -eq 3010 -or $ExitCode -eq -1978335226) {
        return [PSCustomObject]@{ Success = $true; Status = 'Installed (Reboot Needed)'; Detail = $detail; ExitCode = $ExitCode }
    } else {
        return [PSCustomObject]@{ Success = $false; Status = ("Failed (Exit {0})" -f $ExitCode); Detail = $detail; ExitCode = $ExitCode }
    }
}

function Invoke-SilentAppInstallBatch {
    param(
        [array]$Targets = @(),
        [switch]$UpgradeAll,
        [switch]$DryRun,
        [hashtable]$ProgressState = $null,
        [switch]$ConsoleOutput
    )

    $addLog = {
        param([string]$Msg)
        $line = ("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Msg)
        if ($ProgressState) { [void]$ProgressState.Logs.Add($line) }
        if ($ConsoleOutput) { Write-Host ("    {0}" -f $line) -ForegroundColor Gray }
    }

    $winget = if ($DryRun) {
        $wi = Get-WingetInfo
        if (-not $wi.Available) { [PSCustomObject]@{ Available = $true; Path = 'winget.exe'; Version = 'DryRun' } } else { $wi }
    } else {
        Ensure-WingetReady -AutoBootstrap
    }

    if ($ProgressState) {
        $ProgressState.Winget = $winget
        $ProgressState.Running = $true
        $ProgressState.State = 'Running'
    }

    $jobs = @()
    foreach ($t in $Targets) {
        $jobs += [PSCustomObject]@{
            Name     = $t.Name
            WingetId = $t.WingetId
            Args     = (Build-WingetInstallArgs -WingetId $t.WingetId -Source $t.Source)
        }
    }
    if ($UpgradeAll) {
        $jobs += [PSCustomObject]@{
            Name     = 'Upgrade All Installed Apps'
            WingetId = '--all'
            Args     = (Build-WingetUpgradeAllArgs)
        }
    }

    if ($ProgressState) {
        $ProgressState.Total = $jobs.Count
        $ProgressState.CurrentIndex = 0
    }

    $results = @()
    if (-not $winget.Available -and -not $DryRun) {
        & $addLog 'ERROR: winget.exe is unavailable and auto-bootstrap failed.'
        foreach ($j in $jobs) {
            $r = [PSCustomObject]@{
                Name     = $j.Name
                WingetId = $j.WingetId
                Status   = 'Failed (Winget Unavailable)'
                Success  = $false
                Detail   = 'Install App Installer from Microsoft Store or check network'
                ExitCode = -1
            }
            $results += $r
            if ($ProgressState) { [void]$ProgressState.Results.Add($r) }
        }
        if ($ProgressState) {
            $ProgressState.Running = $false
            $ProgressState.State = 'Failed'
            $ProgressState.CurrentApp = ''
        }
        return @($results)
    }

    $idx = 0
    $canceled = $false
    foreach ($j in $jobs) {
        if ($ProgressState -and $ProgressState.CancelRequested) {
            $canceled = $true
            & $addLog 'Install queue canceled by user.'
            break
        }
        $idx++
        if ($ProgressState) {
            $ProgressState.CurrentIndex = $idx
            $ProgressState.CurrentApp = $j.Name
        }

        $argLine = ($j.Args -join ' ')
        if ($DryRun) {
            & $addLog ("[{0}/{1}] DRY RUN: {2} {3}" -f $idx, $jobs.Count, $winget.Path, $argLine)
            $r = [PSCustomObject]@{
                Name     = $j.Name
                WingetId = $j.WingetId
                Status   = 'DryRun OK'
                Success  = $true
                Detail   = ("{0} {1}" -f $winget.Path, $argLine)
                ExitCode = 0
            }
        } else {
            & $addLog ("[{0}/{1}] Installing silently: {2} ({3})..." -f $idx, $jobs.Count, $j.Name, $j.WingetId)
            $outLines = @()
            $exitCode = -1
            try {
                $argArray = $j.Args
                $rawOut = & $winget.Path @argArray 2>&1
                $exitCode = $LASTEXITCODE
                $outLines = @($rawOut | ForEach-Object { [string]$_ })
            } catch {
                $outLines = @($_.Exception.Message)
                $exitCode = -1
            }
            $parsed = ConvertTo-WingetInstallResult -ExitCode $exitCode -OutputLines $outLines
            & $addLog ("    -> {0}: {1}" -f $j.Name, $parsed.Status)
            $r = [PSCustomObject]@{
                Name     = $j.Name
                WingetId = $j.WingetId
                Status   = $parsed.Status
                Success  = $parsed.Success
                Detail   = $parsed.Detail
                ExitCode = $parsed.ExitCode
            }
        }
        $results += $r
        if ($ProgressState) { [void]$ProgressState.Results.Add($r) }
    }

    if ($ProgressState) {
        $ProgressState.Running = $false
        $ProgressState.CurrentApp = ''
        $ProgressState.State = if ($canceled) { 'Canceled' } else { 'Completed' }
    }

    return @($results)
}
