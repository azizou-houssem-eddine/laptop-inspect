# --- BEGIN 00-header.ps1 ---
<#
.SYNOPSIS
    LaptopInspect - Complete Windows Laptop Pre-Purchase Diagnostic & Corporate Lock Audit Suite.
.DESCRIPTION
    Zero-dependency PowerShell diagnostic toolkit for laptop buyers and refurbishers.
    Combines deep corporate lock detection (Autopilot, MDM/Intune, Computrace/Absolute,
    BIOS passwords, BitLocker, RMM/EDR agents, OEM licensing) with hardware health/stress
    tests and a localhost-served interactive HTML5 verification suite.
#>
[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$SkipStress,
    [int]$StressSeconds = 10,
    [switch]$NoBrowser,
    [switch]$NoServer,
    [switch]$NoElevate,
    [switch]$JsonOnly,
    [string]$OutDir = '',
    [string]$CleanupTempPath = ''
)

$ErrorActionPreference = 'Continue'
$script:SelfSource = $MyInvocation.MyCommand.Definition
$script:ToolName = 'LaptopInspect'
$script:ToolVersion = '1.0.0'
$script:RepoUrl = 'https://github.com/azizou-houssem-eddine/laptop-inspect'
$script:ScriptStartTime = Get-Date

# Support environment variable overrides for one-liner irm | iex usage
if ($env:LI_QUICK -eq '1') { $Quick = $true }
if ($env:LI_SKIP_STRESS -eq '1') { $SkipStress = $true }
if ($env:LI_NO_ELEVATE -eq '1') { $NoElevate = $true }
if ($env:LI_NO_BROWSER -eq '1') { $NoBrowser = $true }
if ($env:LI_NO_SERVER -eq '1') { $NoServer = $true }
if ($env:LI_JSON_ONLY -eq '1') { $JsonOnly = $true }
if ($env:LI_STRESS_SECONDS -match '^\d+$') { $StressSeconds = [int]$env:LI_STRESS_SECONDS }
if ([string]::IsNullOrWhiteSpace($OutDir) -and -not [string]::IsNullOrWhiteSpace($env:LI_OUTDIR)) {
    $OutDir = $env:LI_OUTDIR
}

if ($Quick) { $SkipStress = $true; $StressSeconds = 0 }
if ($StressSeconds -lt 0) { $StressSeconds = 0 }
if ($StressSeconds -gt 60) { $StressSeconds = 60 }

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Invoke-SafeCim {
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Namespace = 'root\cimv2',
        [string]$Filter = ''
    )
    try {
        $params = @{
            ClassName   = $ClassName
            Namespace   = $Namespace
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($Filter)) {
            $params['Filter'] = $Filter
        }
        $res = Get-CimInstance @params
        if ($null -eq $res) { return @() }
        return @($res)
    } catch {
        return @()
    }
}

function Get-SafeRegValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $Default }
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        $val = $item.$Name
        if ($null -eq $val) { return $Default }
        return $val
    } catch {
        return $Default
    }
}

function Write-Step {
    param(
        [int]$Index,
        [int]$Total,
        [string]$Title
    )
    $pct = if ($Total -gt 0) { [int][Math]::Round(($Index / [double]$Total) * 100) } else { 0 }
    Write-Host ("[{0}/{1}] {2}" -f $Index, $Total, $Title) -ForegroundColor Cyan
    try {
        Write-Progress -Activity "$($script:ToolName) v$($script:ToolVersion)" -Status $Title -PercentComplete $pct
    } catch {
        # Ignore progress host errors
    }
}

function ConvertTo-SafeArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    return @($Value)
}

function Get-DefaultOutputDirectory {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        try {
            if (-not (Test-Path -LiteralPath $Requested)) {
                New-Item -ItemType Directory -Path $Requested -Force | Out-Null
            }
            return (Resolve-Path -LiteralPath $Requested).Path
        } catch {
            # Fallback below
        }
    }
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not [string]::IsNullOrWhiteSpace($desktop) -and (Test-Path -LiteralPath $desktop)) {
            return $desktop
        }
    } catch {
        # Fallback to TEMP
    }
    return $env:TEMP
}

function Request-OptionalElevation {
    param(
        [switch]$QuickFlag,
        [switch]$SkipStressFlag,
        [int]$StressSec,
        [switch]$NoBrowserFlag,
        [switch]$NoServerFlag,
        [switch]$JsonOnlyFlag,
        [string]$TargetOutDir
    )
    if (Test-IsAdmin) { return $false }
    if ($NoElevate) { return $false }
    if ($env:LAPTOP_INSPECT_IMPORT_ONLY -eq '1') { return $false }
    try {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
    } catch {
        return $false
    }

    Write-Host ""
    Write-Host "[!] Standard (non-Admin) session detected." -ForegroundColor Yellow
    Write-Host "    Admin privileges unlock Vendor BIOS WMI, BitLocker status, MDM CIM, and Storage SMART wear." -ForegroundColor Gray
    $ans = Read-Host "    Elevate to Administrator now? [Y/n] (default Y)"
    if (-not [string]::IsNullOrWhiteSpace($ans) -and $ans.Trim().ToLower().StartsWith('n')) {
        Write-Host "    Continuing in Standard mode..." -ForegroundColor Gray
        return $false
    }

    $tempPath = ''
    $launchFile = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($launchFile) -or -not (Test-Path -LiteralPath $launchFile)) {
        if ([string]::IsNullOrWhiteSpace($script:SelfSource)) {
            Write-Host "    Could not capture script source for elevation. Continuing in Standard mode." -ForegroundColor Yellow
            return $false
        }
        $tempPath = Join-Path $env:TEMP ("LaptopInspect_elevated_{0}.ps1" -f $PID)
        Set-Content -LiteralPath $tempPath -Value $script:SelfSource -Encoding Ascii -Force
        $launchFile = $tempPath
    }

    $argParts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $launchFile), '-NoElevate')
    if ($QuickFlag) { $argParts += '-Quick' }
    if ($SkipStressFlag) { $argParts += '-SkipStress' }
    if ($StressSec -ne 10) { $argParts += ('-StressSeconds {0}' -f $StressSec) }
    if ($NoBrowserFlag) { $argParts += '-NoBrowser' }
    if ($NoServerFlag) { $argParts += '-NoServer' }
    if ($JsonOnlyFlag) { $argParts += '-JsonOnly' }
    if (-not [string]::IsNullOrWhiteSpace($TargetOutDir)) { $argParts += ('-OutDir "{0}"' -f $TargetOutDir) }
    if (-not [string]::IsNullOrWhiteSpace($tempPath)) { $argParts += ('-CleanupTempPath "{0}"' -f $tempPath) }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ($argParts -join ' ') -Verb RunAs | Out-Null
        return $true
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($tempPath) -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        Write-Host "    UAC canceled or blocked. Continuing in Standard mode..." -ForegroundColor Yellow
        return $false
    }
}
# --- END 00-header.ps1 ---

# --- BEGIN EMBEDDED TEMPLATE ---
$script:ReportHtmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>LaptopInspect - Pre-Purchase Diagnostic &amp; Corporate Lock Report</title>
<style>
:root {
  --bg: #f4f6f9;
  --surface: #ffffff;
  --surface-2: #f8fafc;
  --border: #dfe4ec;
  --text: #151b26;
  --muted: #5b6577;
  --accent: #1d4ed8;
  --accent-soft: #dbeafe;
  --pass: #15803d;
  --pass-bg: #dcfce7;
  --warn: #b45309;
  --warn-bg: #fef3c7;
  --fail: #b91c1c;
  --fail-bg: #fee2e2;
  --unavail: #475569;
  --unavail-bg: #e2e8f0;
  --shadow: 0 2px 8px rgba(15, 23, 42, 0.06);
  --radius: 10px;
}
html[data-theme="dark"] {
  --bg: #0d1117;
  --surface: #161b22;
  --surface-2: #1f2630;
  --border: #2e3744;
  --text: #e6edf3;
  --muted: #8b949e;
  --accent: #3b82f6;
  --accent-soft: #1e3a5f;
  --pass: #4ade80;
  --pass-bg: #123522;
  --warn: #fbbf24;
  --warn-bg: #3b2a10;
  --fail: #f87171;
  --fail-bg: #3d1619;
  --unavail: #94a3b8;
  --unavail-bg: #262f3b;
  --shadow: 0 2px 10px rgba(0, 0, 0, 0.35);
}
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: system-ui, -apple-system, 'Segoe UI', Roboto, Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  line-height: 1.45;
  font-size: 14px;
}
.container { max-width: 1220px; margin: 0 auto; padding: 16px; }
.topbar {
  position: sticky; top: 0; z-index: 50;
  background: var(--surface);
  border-bottom: 1px solid var(--border);
  box-shadow: var(--shadow);
}
.topbar-inner {
  max-width: 1220px; margin: 0 auto; padding: 10px 16px;
  display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px;
}
.brand { display: flex; align-items: center; gap: 10px; }
.brand-title { font-weight: 700; font-size: 16px; letter-spacing: -0.2px; }
.brand-sub { font-size: 12px; color: var(--muted); }
.btn-row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.btn {
  appearance: none; border: 1px solid var(--border); background: var(--surface-2);
  color: var(--text); padding: 7px 12px; border-radius: 7px; cursor: pointer;
  font-size: 13px; font-weight: 600; text-decoration: none; display: inline-flex; align-items: center; gap: 6px;
}
.btn:hover { border-color: var(--accent); }
.btn-primary { background: var(--accent); color: #fff; border-color: var(--accent); }
.btn-primary:hover { filter: brightness(1.08); }
.btn-pass { background: var(--pass); color: #fff; border-color: var(--pass); }
.btn-fail { background: var(--fail); color: #fff; border-color: var(--fail); }
.btn-warn { background: var(--warn); color: #fff; border-color: var(--warn); }
.btn-sm { padding: 5px 9px; font-size: 12px; }

.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow);
  padding: 16px; margin-bottom: 16px;
}
.card h2 { margin: 0 0 12px 0; font-size: 16px; display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.card h3 { margin: 12px 0 8px 0; font-size: 14px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.4px; }

.badge {
  display: inline-block; padding: 3px 9px; border-radius: 999px;
  font-size: 11px; font-weight: 700; letter-spacing: 0.3px; text-transform: uppercase;
}
.b-pass { background: var(--pass-bg); color: var(--pass); }
.b-warn { background: var(--warn-bg); color: var(--warn); }
.b-fail { background: var(--fail-bg); color: var(--fail); }
.b-unavail { background: var(--unavail-bg); color: var(--unavail); }
.b-info { background: var(--accent-soft); color: var(--accent); }

.verdict-banner {
  display: grid; grid-template-columns: 1.4fr 1fr 1fr 1fr; gap: 12px; margin-bottom: 16px;
}
@media (max-width: 900px) { .verdict-banner { grid-template-columns: 1fr 1fr; } }
@media (max-width: 560px) { .verdict-banner { grid-template-columns: 1fr; } }

.kpi {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
  padding: 14px; box-shadow: var(--shadow);
}
.kpi-label { font-size: 11px; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
.kpi-val { font-size: 22px; font-weight: 800; margin-top: 4px; }
.kpi-sub { font-size: 12px; color: var(--muted); margin-top: 4px; }

.grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.grid-3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
.grid-4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; }
@media (max-width: 900px) { .grid-2, .grid-3, .grid-4 { grid-template-columns: 1fr; } }

.lock-tile {
  border: 1px solid var(--border); background: var(--surface-2); border-radius: 8px;
  padding: 11px; display: flex; flex-direction: column; gap: 6px;
}
.lock-tile-top { display: flex; align-items: center; justify-content: space-between; gap: 6px; font-weight: 700; font-size: 13px; }
.lock-tile-detail { font-size: 12px; color: var(--muted); word-break: break-word; }

table { width: 100%; border-collapse: collapse; font-size: 13px; }
th, td { text-align: left; padding: 7px 9px; border-bottom: 1px solid var(--border); vertical-align: top; }
th { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.4px; font-weight: 700; }

.alert { padding: 10px 12px; border-radius: 8px; font-size: 13px; margin-bottom: 10px; border: 1px solid transparent; }
.alert-fail { background: var(--fail-bg); color: var(--fail); border-color: var(--fail); }
.alert-warn { background: var(--warn-bg); color: var(--warn); border-color: var(--warn); }
.alert-info { background: var(--accent-soft); color: var(--accent); border-color: var(--accent); }
.alert ul { margin: 4px 0 0 18px; padding: 0; }

/* Wizard */
.step-pills { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
.step-pill {
  padding: 6px 10px; border-radius: 7px; border: 1px solid var(--border);
  background: var(--surface-2); color: var(--text); font-size: 12px; font-weight: 600;
  cursor: pointer; display: inline-flex; align-items: center; gap: 6px;
}
.step-pill.active { border-color: var(--accent); background: var(--accent-soft); color: var(--accent); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--unavail); display: inline-block; }
.dot.pass { background: var(--pass); }
.dot.fail { background: var(--fail); }
.dot.na { background: var(--warn); }

.step-panel { display: none; border-top: 1px solid var(--border); padding-top: 14px; }
.step-panel.active { display: block; }
.step-footer {
  margin-top: 16px; padding-top: 12px; border-top: 1px solid var(--border);
  display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 10px;
}

/* Keyboard Matrix */
.kb-wrap { overflow-x: auto; padding: 8px 0; }
.kb-board { display: inline-flex; gap: 14px; background: var(--surface-2); padding: 12px; border-radius: 8px; border: 1px solid var(--border); }
.kb-main, .kb-nav, .kb-num { display: flex; flex-direction: column; gap: 4px; }
.kb-row { display: flex; gap: 4px; }
.k {
  min-width: 34px; height: 34px; padding: 0 5px; border-radius: 5px;
  border: 1px solid var(--border); background: var(--surface); color: var(--text);
  font-size: 11px; font-weight: 600; display: inline-flex; align-items: center; justify-content: center;
  user-select: none;
}
.k.w15 { min-width: 52px; }
.k.w175 { min-width: 62px; }
.k.w2 { min-width: 72px; }
.k.w225 { min-width: 82px; }
.k.w6 { min-width: 215px; }
.k.gap { visibility: hidden; min-width: 18px; }
.k.hit { background: var(--pass); color: #fff; border-color: var(--pass); }
.k.chatter { background: var(--warn); color: #000; border-color: var(--warn); }

/* Canvases & Media */
canvas.test-canvas {
  width: 100%; max-width: 820px; height: 320px; background: #0f172a;
  border: 2px solid var(--border); border-radius: 8px; display: block; touch-action: none;
}
video.cam-preview {
  width: 100%; max-width: 520px; min-height: 240px; background: #000;
  border-radius: 8px; border: 1px solid var(--border); display: block;
}
.meter-bar { width: 100%; max-width: 520px; height: 14px; background: var(--surface-2); border: 1px solid var(--border); border-radius: 999px; overflow: hidden; }
.meter-fill { height: 100%; width: 0%; background: var(--pass); transition: width 0.05s; }

/* Fullscreen Screen Overlay */
#screen-overlay {
  display: none; position: fixed; inset: 0; z-index: 9999; cursor: pointer;
  user-select: none; align-items: center; justify-content: center;
}
#screen-overlay.active { display: flex; }
#screen-hud {
  position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
  background: rgba(15, 23, 42, 0.85); color: #fff; padding: 8px 14px;
  border-radius: 8px; font-size: 13px; pointer-events: none; text-align: center;
}
#screen-motion-canvas { position: fixed; inset: 0; width: 100%; height: 100%; display: none; }

.form-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
@media (max-width: 800px) { .form-grid { grid-template-columns: 1fr; } }
label.field { display: flex; flex-direction: column; gap: 4px; font-size: 12px; font-weight: 600; color: var(--muted); }
input[type="text"], input[type="number"], select, textarea {
  padding: 7px 9px; border-radius: 6px; border: 1px solid var(--border);
  background: var(--surface-2); color: var(--text); font-family: inherit; font-size: 13px;
}
.toast {
  position: fixed; right: 18px; bottom: 18px; z-index: 500;
  background: #111827; color: #fff; padding: 10px 14px; border-radius: 8px;
  font-size: 13px; font-weight: 600; display: none; box-shadow: 0 6px 18px rgba(0,0,0,0.3);
}
.print-only { display: none; }
.log-box {
  background: #0b1220; color: #d1fae5; font-family: Consolas, monospace; font-size: 12px;
  padding: 10px; border-radius: 7px; max-height: 180px; overflow-y: auto; border: 1px solid var(--border);
}

@media print {
  body { background: #fff !important; color: #000 !important; font-size: 11px; }
  .topbar, .no-print, .step-pills, .step-panel, .step-footer, #screen-overlay { display: none !important; }
  .print-only { display: block !important; }
  .card, .kpi { box-shadow: none !important; break-inside: avoid; border: 1px solid #bbb !important; }
  .container { max-width: 100%; padding: 0; }
}
</style>
</head>
<body>
<div class="topbar no-print">
  <div class="topbar-inner">
    <div class="brand">
      <div>
        <div class="brand-title">LaptopInspect &mdash; Pre-Purchase Audit Suite</div>
        <div class="brand-sub" id="top-subtitle">Loading machine info...</div>
      </div>
    </div>
    <div class="btn-row">
      <button class="btn btn-primary btn-sm" onclick="scrollToWizard()">Start Guided Tests</button>
      <button class="btn btn-pass btn-sm" id="btn-save-report" onclick="saveCompletedReport()">Save Completed Report</button>
      <button class="btn btn-sm" onclick="window.print()">Print / Save PDF</button>
      <button class="btn btn-sm" onclick="copyTextSummary()">Copy Text / WhatsApp</button>
      <button class="btn btn-sm" onclick="exportTxtSummary()">Export .TXT</button>
      <button class="btn btn-sm" onclick="exportJsonFile()">Export .JSON</button>
      <button class="btn btn-sm" onclick="toggleTheme()">Theme</button>
      <button class="btn btn-warn btn-sm" id="btn-shutdown-srv" style="display:none;" onclick="shutdownServer()">Finish &amp; Close Server</button>
    </div>
  </div>
</div>

<div class="container">
  <div class="print-only" style="margin-bottom:10px; border-bottom:2px solid #000; padding-bottom:6px;">
    <strong>LaptopInspect Pre-Purchase Diagnostic &amp; Corporate Lock Certificate</strong>
    <div id="print-meta" style="font-size:11px; color:#333;"></div>
  </div>

  <!-- Executive KPI Row -->
  <div class="verdict-banner">
    <div class="kpi">
      <div class="kpi-label">Overall Buyer Verdict</div>
      <div class="kpi-val" id="kpi-verdict">--</div>
      <div class="kpi-sub" id="kpi-verdict-sub">Evaluating...</div>
    </div>
    <div class="kpi">
      <div class="kpi-label">Corporate Lock Audit</div>
      <div class="kpi-val" id="kpi-corplock">--</div>
      <div class="kpi-sub" id="kpi-corplock-sub">--</div>
    </div>
    <div class="kpi">
      <div class="kpi-label">Hardware Health Score</div>
      <div class="kpi-val" id="kpi-score">-- / 100</div>
      <div class="kpi-sub" id="kpi-score-sub">--</div>
    </div>
    <div class="kpi">
      <div class="kpi-label">Guided Verification</div>
      <div class="kpi-val" id="kpi-manual">0 / 10</div>
      <div class="kpi-sub" id="kpi-manual-sub">Interactive buyer checks pending</div>
    </div>
  </div>

  <div id="alerts-box"></div>

  <!-- Section 1: Corporate Lock & Ownership Audit -->
  <div class="card">
    <h2>
      <span>1. Corporate Lock &amp; Ownership Audit</span>
      <span class="badge b-info" id="corp-admin-badge">Session</span>
    </h2>
    <div id="corp-advisory"></div>
    <div class="grid-4" id="corp-grid"></div>
  </div>

  <!-- Section 2: Complete Automated Hardware Telemetry -->
  <div class="card">
    <h2><span>2. Automated Hardware &amp; Thermal Telemetry</span><span class="badge b-info" id="meta-duration"></span></h2>
    <div class="grid-2">
      <div>
        <h3>System Identity</h3>
        <table id="tbl-system"></table>
        <h3>Battery &amp; Power Load Stability</h3>
        <table id="tbl-battery"></table>
        <h3>CPU, Verified Workload &amp; Thermals</h3>
        <table id="tbl-cpu"></table>
      </div>
      <div>
        <h3>Graphics Adapters (GPU)</h3>
        <table id="tbl-gpu"></table>
        <h3>Memory (RAM) &amp; Upgradeability</h3>
        <table id="tbl-ram"></table>
        <h3>Storage SMART &amp; Benchmark</h3>
        <table id="tbl-storage"></table>
      </div>
    </div>
    <div class="grid-2" style="margin-top:12px;">
      <div>
        <h3>Display (EDID) &amp; Built-in Peripherals</h3>
        <table id="tbl-display-periph"></table>
      </div>
      <div>
        <h3>Network, Wi-Fi &amp; Device Manager Errors</h3>
        <table id="tbl-network-errors"></table>
      </div>
    </div>
  </div>

  <!-- Printable Manual Summary Table -->
  <div class="card print-only" id="print-manual-card">
    <h2>Guided Buyer Inspection &amp; Cosmetic Summary</h2>
    <table id="tbl-print-manual"></table>
  </div>

  <!-- Section 3: Guided 10-Step Interactive Verification Wizard -->
  <div class="card no-print" id="wizard-card">
    <h2>
      <span>3. Guided 10-Step Buyer Verification Suite</span>
      <span class="badge b-info" id="wizard-step-label">Step 1 of 10</span>
    </h2>
    <div class="step-pills" id="step-pills"></div>

    <!-- Step 1: Keyboard -->
    <div class="step-panel active" id="step-1">
      <p><strong>Keyboard &amp; Backlight Test:</strong> Press every physical key on the laptop. Tested keys turn green; keys bouncing faster than 15ms highlight amber as chatter.</p>
      <div class="btn-row" style="margin-bottom:8px;">
        <span class="badge b-info" id="kb-count">0 keys pressed</span>
        <span class="badge b-pass" id="kb-chatter">Chatter: 0</span>
        <button class="btn btn-sm" onclick="resetKeyboard()">Reset Keyboard</button>
        <label style="font-size:12px; margin-left:8px;">Backlight:
          <select id="kb-backlight" onchange="updateField('kbBacklight', this.value)">
            <option value="">Not Checked</option>
            <option value="PASS">Working (Pass)</option>
            <option value="FAIL">Dead / Flickering (Fail)</option>
            <option value="NA">No Backlight (N/A)</option>
          </select>
        </label>
      </div>
      <div class="kb-wrap"><div class="kb-board" id="kb-board"></div></div>
      <p style="font-size:12px; color:var(--muted);">Note: Hardware <code>Fn</code> and OS-reserved shortcuts (<code>Win+L</code>, <code>Ctrl+Alt+Del</code>, <code>PrtSc</code>) may be intercepted by Windows before reaching the browser.</p>
    </div>

    <!-- Step 2: Touchpad & Touchscreen -->
    <div class="step-panel" id="step-2">
      <p><strong>Touchpad, Clicks, Scroll &amp; Touchscreen:</strong> Move across the pad, draw while dragging, test Left/Right/Middle clicks and two-finger scroll.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <span class="badge b-unavail" id="tp-move">Move: Pending</span>
        <span class="badge b-unavail" id="tp-left">Left Click: Pending</span>
        <span class="badge b-unavail" id="tp-right">Right Click: Pending</span>
        <span class="badge b-unavail" id="tp-middle">Middle Click: Pending</span>
        <span class="badge b-unavail" id="tp-scroll">Scroll: Pending</span>
        <span class="badge b-unavail" id="tp-drag">Drag: Pending</span>
        <span class="badge b-unavail" id="tp-touch">Touch/Pen: Pending</span>
        <button class="btn btn-sm" onclick="clearTouchpadCanvas()">Clear Canvas</button>
      </div>
      <canvas id="tp-canvas" class="test-canvas" width="820" height="320"></canvas>
    </div>

    <!-- Step 3: Screen & Display Quality -->
    <div class="step-panel" id="step-3">
      <p><strong>Screen &amp; Dead Pixel / Uniformity / Refresh Rate Test:</strong> Launch fullscreen mode and inspect for dead pixels, backlight bleed, yellowing, banding, or flicker. Click or press Space/Arrows to advance, Escape to exit.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <button class="btn btn-primary" onclick="startScreenTest(0)">Launch Fullscreen Cycle (10 Modes)</button>
        <button class="btn btn-sm" onclick="startScreenTest(0)">Black (Bleed)</button>
        <button class="btn btn-sm" onclick="startScreenTest(1)">White (Uniformity)</button>
        <button class="btn btn-sm" onclick="startScreenTest(2)">Red</button>
        <button class="btn btn-sm" onclick="startScreenTest(3)">Green</button>
        <button class="btn btn-sm" onclick="startScreenTest(4)">Blue</button>
        <button class="btn btn-sm" onclick="startScreenTest(5)">50% Gray</button>
        <button class="btn btn-sm" onclick="startScreenTest(6)">Gradient</button>
        <button class="btn btn-sm" onclick="startScreenTest(7)">Checkerboard</button>
        <button class="btn btn-sm" onclick="startScreenTest(8)">Grid</button>
        <button class="btn btn-sm" onclick="startScreenTest(9)">Motion / Hz (<span id="screen-hz-label">Measure</span>)</button>
      </div>
      <div id="screen-test-info" class="kpi-sub">Click any pattern above to inspect the full panel.</div>
    </div>

    <!-- Step 4: Speakers & Audio -->
    <div class="step-panel" id="step-4">
      <p><strong>Speakers &amp; Audio Channel Test:</strong> Verify left speaker, right speaker, stereo balance, and high-volume rattle sweep. Also plug in 3.5mm headphones if equipped.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <button class="btn btn-primary btn-sm" onclick="playTone('left')">Left Speaker Only</button>
        <button class="btn btn-primary btn-sm" onclick="playTone('right')">Right Speaker Only</button>
        <button class="btn btn-primary btn-sm" onclick="playTone('both')">Stereo Both</button>
        <button class="btn btn-sm" onclick="playSweep()">Sweep 120Hz &rarr; 6000Hz (Rattle Check)</button>
        <button class="btn btn-fail btn-sm" onclick="stopAudio()">Stop Sound</button>
        <a class="btn btn-sm" href="ms-settings:sound">Open Windows Sound Settings</a>
      </div>
      <label style="font-size:13px;">Headphone 3.5mm Jack:
        <select id="audio-jack" onchange="updateField('audioJack', this.value)">
          <option value="">Not Tested</option>
          <option value="PASS">Working (Pass)</option>
          <option value="FAIL">No Sound / Static (Fail)</option>
          <option value="NA">No Jack / Not Needed (N/A)</option>
        </select>
      </label>
    </div>

    <!-- Step 5: Webcam -->
    <div class="step-panel" id="step-5">
      <p><strong>Webcam Verification:</strong> Start camera to check focus, color, exposure, and privacy shutter. Stream stops automatically when leaving this step.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <button class="btn btn-primary btn-sm" onclick="startWebcam()">Start Webcam Preview</button>
        <button class="btn btn-fail btn-sm" onclick="stopWebcam()">Stop Camera</button>
        <span class="badge b-info" id="cam-res">Not Started</span>
        <a class="btn btn-sm" href="ms-settings:privacy-webcam">Windows Camera Privacy</a>
      </div>
      <video id="cam-video" class="cam-preview" autoplay playsinline muted></video>
      <div id="cam-msg" class="kpi-sub"></div>
    </div>

    <!-- Step 6: Microphone -->
    <div class="step-panel" id="step-6">
      <p><strong>Microphone Input &amp; Recording Test:</strong> Speak into the laptop microphone, check live level meter, and play back a 3-second sample. Recordings stay local and are never saved inside the HTML report.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <button class="btn btn-primary btn-sm" onclick="startMic()">Start Live Mic Monitor</button>
        <button class="btn btn-warn btn-sm" onclick="recordMicSample()">Record 3s Sample</button>
        <button class="btn btn-fail btn-sm" onclick="stopMic()">Stop Mic</button>
        <button class="btn btn-sm" id="btn-dl-wav" style="display:none;" onclick="downloadLastWav()">Download .WAV</button>
      </div>
      <div class="meter-bar" style="margin-bottom:8px;"><div class="meter-fill" id="mic-meter"></div></div>
      <canvas id="mic-canvas" class="test-canvas" style="height:120px; max-width:520px;" width="520" height="120"></canvas>
      <div style="margin-top:8px;"><audio id="mic-playback" controls style="display:none; width:100%; max-width:520px;"></audio></div>
      <div id="mic-msg" class="kpi-sub"></div>
    </div>

    <!-- Step 7: Ports, Charging & Wireless -->
    <div class="step-panel" id="step-7">
      <p><strong>Physical Ports, Charging &amp; Wireless Hot-Plug Test:</strong> Plug a USB stick, charger, HDMI/USB-C display, or Ethernet cable into each physical port to verify live OS detection.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <button class="btn btn-primary btn-sm" id="btn-port-watch" onclick="togglePortWatcher()">Start Live Port Watcher</button>
        <a class="btn btn-sm" href="ms-settings:bluetooth">Bluetooth Settings</a>
        <a class="btn btn-sm" href="ms-settings:network-wifi">Wi-Fi Settings</a>
      </div>
      <div id="port-watch-status" class="kpi-sub" style="margin-bottom:8px;"></div>
      <div class="log-box" id="port-log">Waiting for port watcher...</div>
      <div class="grid-3" style="margin-top:12px;">
        <label><input type="checkbox" id="chk-usba" onchange="togglePortCheck('usba', this.checked)"> USB-A Ports Verified</label>
        <label><input type="checkbox" id="chk-usbc" onchange="togglePortCheck('usbc', this.checked)"> USB-C / Thunderbolt Verified</label>
        <label><input type="checkbox" id="chk-pd" onchange="togglePortCheck('pd', this.checked)"> AC / USB-C Charging Verified</label>
        <label><input type="checkbox" id="chk-hdmi" onchange="togglePortCheck('hdmi', this.checked)"> HDMI / Display Output Verified</label>
        <label><input type="checkbox" id="chk-eth" onchange="togglePortCheck('eth', this.checked)"> Ethernet / Card Reader Verified</label>
        <label><input type="checkbox" id="chk-bt" onchange="togglePortCheck('bt', this.checked)"> Wi-Fi &amp; Bluetooth Paired</label>
      </div>
    </div>

    <!-- Step 8: GPU 3D WebGL2 Stress -->
    <div class="step-panel" id="step-8">
      <p><strong>GPU 3D WebGL2 Stress &amp; Artifact Test:</strong> Exercises the GPU 3D pipeline to expose screen corruption, flickering triangles, driver crashes, or severe overheating.</p>
      <div class="btn-row" style="margin-bottom:10px;">
        <button class="btn btn-primary btn-sm" onclick="startGpuStress(30)">Start 30s 3D Stress</button>
        <button class="btn btn-fail btn-sm" onclick="stopGpuStress()">Stop 3D Test</button>
        <label style="font-size:12px;">Load:
          <select id="gpu-load" onchange="setGpuLoad(this.value)">
            <option value="300">Normal (300 objects)</option>
            <option value="1500" selected>Heavy (1,500 objects)</option>
            <option value="4000">Extreme (4,000 objects)</option>
          </select>
        </label>
        <span class="badge b-info" id="gpu-fps">FPS: --</span>
        <span class="badge b-info" id="gpu-ft">Frame: -- ms</span>
        <span class="badge b-info" id="gpu-timer">Timer: 30s</span>
      </div>
      <div id="gpu-renderer" class="kpi-sub" style="margin-bottom:8px;">Renderer: Not started</div>
      <canvas id="gpu-canvas" class="test-canvas" width="820" height="300"></canvas>
    </div>

    <!-- Step 9: BIOS / UEFI Manual Verification -->
    <div class="step-panel" id="step-9">
      <p><strong>BIOS / UEFI Setup Lock Check:</strong> If Vendor BIOS WMI was unavailable or you want 100% certainty, reboot and enter BIOS Setup (F1 / F2 / F10 / Del) to verify no hidden locks exist.</p>
      <div id="bios-manual-summary" class="alert alert-info"></div>
      <div class="grid-3">
        <label><input type="checkbox" id="chk-bios-pwd" onchange="togglePortCheck('biosNoPwd', this.checked)"> Confirmed NO BIOS Supervisor / Admin Password</label>
        <label><input type="checkbox" id="chk-bios-comp" onchange="togglePortCheck('biosNoComputrace', this.checked)"> Confirmed Computrace / Absolute Disabled</label>
        <label><input type="checkbox" id="chk-bios-oobe" onchange="togglePortCheck('oobeChecked', this.checked)"> Confirmed Clean Online Windows OOBE (No Org Login)</label>
      </div>
    </div>

    <!-- Step 10: Cosmetic Grade & Purchase Info -->
    <div class="step-panel" id="step-10">
      <p><strong>Cosmetic Condition &amp; Purchase Details:</strong> Record physical condition, charger originality, seller info, and notes before saving the final Purchase Certificate.</p>
      <div class="form-grid">
        <label class="field">Chassis Grade
          <select id="grade-chassis" onchange="updateField('chassisGrade', this.value)">
            <option value="">Select...</option>
            <option value="A+ (Mint)">A+ (Mint)</option>
            <option value="A (Light Wear)">A (Light Wear)</option>
            <option value="B (Visible Scratches)">B (Visible Scratches)</option>
            <option value="C (Dents / Cracks)">C (Dents / Cracks)</option>
          </select>
        </label>
        <label class="field">Screen Glass Condition
          <select id="grade-screen" onchange="updateField('screenGrade', this.value)">
            <option value="">Select...</option>
            <option value="Clean / Spotless">Clean / Spotless</option>
            <option value="Light Keyboard Imprints">Light Keyboard Imprints</option>
            <option value="Scratches / White Pressure Spots">Scratches / White Pressure Spots</option>
            <option value="Cracked / Delaminating">Cracked / Delaminating</option>
          </select>
        </label>
        <label class="field">Hinges &amp; Lid Stability
          <select id="grade-hinges" onchange="updateField('hingesGrade', this.value)">
            <option value="">Select...</option>
            <option value="Tight &amp; Smooth">Tight &amp; Smooth</option>
            <option value="Slightly Loose">Slightly Loose</option>
            <option value="Damaged / Wobbling">Damaged / Wobbling</option>
          </select>
        </label>
        <label class="field">Charger Included
          <select id="grade-charger" onchange="updateField('chargerType', this.value)">
            <option value="">Select...</option>
            <option value="Original OEM">Original OEM</option>
            <option value="Third-Party">Third-Party</option>
            <option value="None Included">None Included</option>
          </select>
        </label>
        <label class="field">Seller Name / Shop
          <input type="text" id="meta-seller" placeholder="e.g. TechResale" oninput="updateField('sellerName', this.value)">
        </label>
        <label class="field">Asking Price
          <input type="text" id="meta-price" placeholder="e.g. $450 / 85,000 DZD" oninput="updateField('askingPrice', this.value)">
        </label>
      </div>
      <label class="field" style="margin-top:10px;">Buyer Inspection Notes
        <textarea id="meta-notes" rows="3" placeholder="Any cosmetic scuffs, missing screws, battery notes, or agreed warranty..." oninput="updateField('notes', this.value)"></textarea>
      </label>
      <p style="font-size:12px; color:var(--muted); margin-top:10px;">Diagnostic Scope Disclaimer: Hardware metrics and short load checks reflect observed state at test time and do not guarantee long-term component lifespan.</p>
    </div>

    <div class="step-footer">
      <div class="btn-row">
        <button class="btn btn-sm" onclick="prevStep()">&larr; Previous</button>
        <button class="btn btn-sm" onclick="nextStep()">Next &rarr;</button>
      </div>
      <div class="btn-row" id="step-rating-bar">
        <span style="font-size:12px; color:var(--muted);">Mark this step:</span>
        <button class="btn btn-pass btn-sm" onclick="setStepResult('PASS')">PASS</button>
        <button class="btn btn-fail btn-sm" onclick="setStepResult('FAIL')">FAIL</button>
        <button class="btn btn-sm" onclick="setStepResult('NA')">N/A</button>
      </div>
    </div>
  </div>
</div>

<!-- Fullscreen Screen Inspection Overlay -->
<div id="screen-overlay" onclick="nextScreenMode()">
  <canvas id="screen-motion-canvas"></canvas>
  <div id="screen-hud">Mode</div>
</div>

<div class="toast" id="toast"></div>

<script id="li-report-data" type="application/json">__LI_REPORT_DATA_JSON__</script>
<script id="li-manual-state" type="application/json">__LI_MANUAL_STATE_JSON__</script>
<script>window.__LI_SERVER__ = __LI_SERVER_FLAG__;</script>
<script>
(function () {
  'use strict';

  function toArr(v) {
    if (v === null || v === undefined) return [];
    return Array.isArray(v) ? v : [v];
  }

  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function parseJsonBlock(id) {
    try {
      var el = document.getElementById(id);
      if (!el || !el.textContent) return {};
      return JSON.parse(el.textContent);
    } catch (e) {
      return {};
    }
  }

  var reportData = parseJsonBlock('li-report-data');
  var rawManual = parseJsonBlock('li-manual-state');
  var manualState = Object.assign({
    results: {},
    checks: {},
    kbTestedCount: 0,
    kbChatterCount: 0,
    kbBacklight: '',
    audioJack: '',
    chassisGrade: '',
    screenGrade: '',
    hingesGrade: '',
    chargerType: '',
    sellerName: '',
    askingPrice: '',
    notes: ''
  }, rawManual || {});
  if (!manualState.results) manualState.results = {};
  if (!manualState.checks) manualState.checks = {};

  var STEPS = [
    { id: 'keyboard', label: '1. Keyboard' },
    { id: 'touchpad', label: '2. Touchpad' },
    { id: 'screen',   label: '3. Screen' },
    { id: 'speakers', label: '4. Speakers' },
    { id: 'webcam',   label: '5. Webcam' },
    { id: 'mic',      label: '6. Microphone' },
    { id: 'ports',    label: '7. Ports & Wi-Fi' },
    { id: 'gpu3d',    label: '8. GPU 3D' },
    { id: 'bios',     label: '9. BIOS Lock' },
    { id: 'cosmetic', label: '10. Grade & Info' }
  ];
  var currentStepIdx = 0;

  function showToast(msg) {
    var t = document.getElementById('toast');
    t.textContent = msg;
    t.style.display = 'block';
    clearTimeout(t._timer);
    t._timer = setTimeout(function () { t.style.display = 'none'; }, 3500);
  }

  function badgeHtml(status, customLabel) {
    var s = String(status || 'UNAVAILABLE').toUpperCase();
    var cls = 'b-unavail';
    if (s === 'PASS' || s === 'BUY' || s === 'CLEAN' || s === 'OK' || s === 'HEALTHY') cls = 'b-pass';
    else if (s === 'WARN' || s === 'CAUTION' || s === 'NA') cls = 'b-warn';
    else if (s === 'FAIL' || s === 'DO NOT BUY' || s === 'LOCKED') cls = 'b-fail';
    return '<span class="badge ' + cls + '">' + esc(customLabel || s) + '</span>';
  }

  function kvRow(k, v) {
    return '<tr><th style="width:38%;">' + esc(k) + '</th><td>' + v + '</td></tr>';
  }

  function computeLiveVerdict() {
    var auto = reportData.Scoring || {};
    var crit = toArr(auto.CriticalFlags).slice();
    var warns = toArr(auto.Warnings).slice();
    var adv = toArr(auto.Advisories).slice();
    var score = (typeof auto.Score === 'number') ? auto.Score : 100;

    for (var i = 0; i < STEPS.length; i++) {
      var st = STEPS[i];
      var r = manualState.results[st.id];
      if (r === 'FAIL') {
        crit.push('Manual Test FAILED: ' + st.label);
        score = Math.max(0, score - 20);
      }
    }
    if (manualState.kbBacklight === 'FAIL') warns.push('Keyboard backlight failed manual check');
    if (manualState.audioJack === 'FAIL') warns.push('3.5mm audio jack failed manual check');

    var verdict = 'BUY';
    if (crit.length > 0) verdict = 'DO NOT BUY';
    else if (warns.length > 0 || score < 80) verdict = 'CAUTION';

    return { verdict: verdict, score: score, crit: crit, warns: warns, adv: adv };
  }

  function renderTopAndScoring() {
    var sys = reportData.System || {};
    var meta = reportData.Meta || {};
    var corp = reportData.CorporateLock || {};
    var live = computeLiveVerdict();

    document.getElementById('top-subtitle').textContent =
      (sys.Manufacturer || '') + ' ' + (sys.Model || 'Laptop') + ' | S/N: ' + (sys.SerialNumber || 'Unknown') + ' | Generated ' + (meta.GeneratedAt || '');
    document.getElementById('print-meta').textContent =
      (sys.Manufacturer || '') + ' ' + (sys.Model || '') + ' | Serial: ' + (sys.SerialNumber || '') + ' | Run: ' + (meta.GeneratedAt || '');
    document.getElementById('meta-duration').textContent = 'Scan: ' + (meta.DurationSeconds || 0) + 's';

    var kv = document.getElementById('kpi-verdict');
    kv.innerHTML = badgeHtml(live.verdict, live.verdict === 'BUY' ? 'APPROVED TO BUY' : (live.verdict === 'CAUTION' ? 'BUY WITH CAUTION' : 'DO NOT BUY'));
    document.getElementById('kpi-verdict-sub').textContent =
      live.crit.length + ' critical flag(s), ' + live.warns.length + ' warning(s)';

    var kcl = document.getElementById('kpi-corplock');
    kcl.innerHTML = corp.ConfirmedCorporateLock ? badgeHtml('FAIL', 'LOCKED / MANAGED') : badgeHtml('PASS', 'NO LOCAL LOCK');
    var biosStat = (corp.BiosSecurity && corp.BiosSecurity.WmiChecked) ? ('BIOS WMI: ' + corp.BiosSecurity.VendorProvider) : 'BIOS WMI unavailable (check UEFI manually)';
    document.getElementById('kpi-corplock-sub').textContent = biosStat;

    document.getElementById('kpi-score').textContent = live.score + ' / 100';
    var deds = toArr((reportData.Scoring || {}).Deductions);
    document.getElementById('kpi-score-sub').textContent = deds.length ? deds.join(' | ') : 'No automated deductions';

    var doneCount = 0;
    for (var i = 0; i < STEPS.length; i++) {
      if (manualState.results[STEPS[i].id]) doneCount++;
    }
    document.getElementById('kpi-manual').textContent = doneCount + ' / ' + STEPS.length;
    document.getElementById('kpi-manual-sub').textContent = doneCount === STEPS.length ? 'All guided steps recorded' : 'Complete steps below and click Save';

    var ab = document.getElementById('alerts-box');
    var html = '';
    if (live.crit.length > 0) {
      html += '<div class="alert alert-fail"><strong>CRITICAL REASONS TO REJECT:</strong><ul>' +
        live.crit.map(function (c) { return '<li>' + esc(c) + '</li>'; }).join('') + '</ul></div>';
    }
    if (live.warns.length > 0) {
      html += '<div class="alert alert-warn"><strong>WARNINGS / NEGOTIATION POINTS:</strong><ul>' +
        live.warns.map(function (w) { return '<li>' + esc(w) + '</li>'; }).join('') + '</ul></div>';
    }
    ab.innerHTML = html;

    renderPrintManualSummary(live);
  }

  function renderCorporateLock() {
    var c = reportData.CorporateLock || {};
    var adminBadge = document.getElementById('corp-admin-badge');
    adminBadge.className = 'badge ' + (c.IsAdminSession ? 'b-pass' : 'b-warn');
    adminBadge.textContent = c.IsAdminSession ? 'Administrator Telemetry' : 'Standard User (Limited WMI)';

    var advHtml = '';
    if (c.Autopilot && c.Autopilot.Advisory) {
      advHtml = '<div class="alert alert-info"><strong>Buyer Verification Note:</strong> ' + esc(c.Autopilot.Advisory) + '</div>';
    }
    document.getElementById('corp-advisory').innerHTML = advHtml;

    var ds = c.Dsreg || {};
    var ap = c.Autopilot || {};
    var mdm = c.Mdm || {};
    var comp = c.Computrace || {};
    var bios = c.BiosSecurity || {};
    var bl = c.BitLocker || {};
    var rmm = c.RmmEdr || {};
    var act = c.Activation || {};

    var tiles = [
      {
        title: 'Windows Autopilot',
        status: ap.Status,
        detail: ap.Assigned
          ? ('Assigned Tenant: ' + (ap.TenantDomain || ap.TenantId || 'Detected') + '. ' + toArr(ap.Evidence).join('; '))
          : ('No local Autopilot profile. HW Hash: ' + (ap.HardwareHashSummary || 'N/A'))
      },
      {
        title: 'Entra ID / AD Domain',
        status: c.DomainJoinStatus,
        detail: ds.Available
          ? ('AzureAD=' + ds.AzureAdJoined + ', Domain=' + ds.DomainJoined + ', Enterprise=' + ds.EnterpriseJoined + ', Workplace=' + ds.WorkplaceJoined + (ds.TenantName ? ' (' + ds.TenantName + ')' : ''))
          : 'dsregcmd unavailable'
      },
      {
        title: 'Intune / MDM Enrollment',
        status: mdm.Status,
        detail: mdm.Detected
          ? ('Active enrollment(s): ' + toArr(mdm.Entries).map(function (e) { return e.ProviderID || e.UPN || e.EnrollmentId; }).join(', ') + ' PPKG=' + toArr(mdm.PpkgFiles).length)
          : 'No active MDM enrollments or provisioning packages found'
      },
      {
        title: 'Computrace / Absolute',
        status: comp.Status,
        detail: comp.OsEvidence && toArr(comp.OsEvidence).length
          ? toArr(comp.OsEvidence).join('; ')
          : (comp.BiosWmiChecked ? ('BIOS WMI checked (' + comp.BiosVendor + '): not active') : 'No OS agent found; vendor BIOS WMI unavailable - verify in UEFI Setup')
      },
      {
        title: 'BIOS Password & vPro',
        status: bios.Status,
        detail: (bios.WmiChecked ? ('Provider: ' + bios.VendorProvider + '; PasswordSet=' + bios.PasswordSet) : 'Vendor BIOS WMI unavailable - verify in UEFI Setup') +
          ' | SecureBoot=' + (bios.SecureBoot || 'UNAVAILABLE') +
          ' | TPM=' + (bios.Tpm && bios.Tpm.Available ? ('Present=' + bios.Tpm.TpmPresent + ',Ready=' + bios.Tpm.TpmReady) : 'UNAVAILABLE') +
          (bios.IntelAmtActive ? ' | Intel AMT/vPro Present' : '')
      },
      {
        title: 'BitLocker Encryption',
        status: bl.Status,
        detail: bl.Checked
          ? (toArr(bl.Volumes).map(function (v) { return (v.MountPoint || 'Vol') + ': ' + v.ProtectionStatus; }).join(', ') || 'No protected volumes')
          : 'BitLocker check unavailable (Admin required or Home edition)'
      },
      {
        title: 'Corporate RMM / EDR',
        status: rmm.Status,
        detail: rmm.Detected ? toArr(rmm.Findings).join('; ') : 'No known corporate RMM or enterprise EDR agents running'
      },
      {
        title: 'Windows OEM License',
        status: act.Status,
        detail: 'Status=' + (act.LicenseStatus || 'Unknown') + ' | Channel=' + (act.Channel || 'Unknown') +
          ' | BIOS OEM Key=' + (act.HasOemFirmwareKey ? ('Yes (' + act.MaskedOemKey + ')') : 'Not Found')
      }
    ];

    document.getElementById('corp-grid').innerHTML = tiles.map(function (t) {
      return '<div class="lock-tile"><div class="lock-tile-top"><span>' + esc(t.title) + '</span>' + badgeHtml(t.status) +
        '</div><div class="lock-tile-detail">' + esc(t.detail) + '</div></div>';
    }).join('');
  }

  function renderTelemetryTables() {
    var sys = reportData.System || {};
    document.getElementById('tbl-system').innerHTML =
      kvRow('Model / SKU', esc((sys.Manufacturer || '') + ' ' + (sys.Model || '') + (sys.SystemSku ? ' [' + sys.SystemSku + ']' : ''))) +
      kvRow('Serial Number', '<code>' + esc(sys.SerialNumber || 'Unknown') + '</code>') +
      kvRow('BIOS / Board', esc((sys.BiosVendor || '') + ' ' + (sys.BiosVersion || '') + ' (' + (sys.BiosDate || '') + ') | ' + (sys.BaseBoard || ''))) +
      kvRow('OS / Uptime', esc((sys.OsCaption || '') + ' Build ' + (sys.OsBuild || '') + ' | Installed: ' + (sys.OsInstallDate || 'N/A') + ' | Uptime: ' + (sys.UptimeHours !== null && sys.UptimeHours !== undefined ? sys.UptimeHours + 'h' : 'N/A')));

    var bat = reportData.Battery || {};
    var batRows = kvRow('Status / Condition', badgeHtml(bat.Status) + ' ' + esc(bat.Condition || '')) +
      kvRow('Health / Cycles', (bat.OverallHealthPercent !== null && bat.OverallHealthPercent !== undefined ? '<strong>' + bat.OverallHealthPercent + '%</strong>' : 'UNAVAILABLE') + ' | Max Cycles: ' + esc(bat.MaxCycleCount !== null && bat.MaxCycleCount !== undefined ? bat.MaxCycleCount : 'N/A')) +
      kvRow('Live Power', 'Charge: ' + esc(bat.CurrentChargePercent !== null && bat.CurrentChargePercent !== undefined ? bat.CurrentChargePercent + '%' : 'N/A') +
        ' | AC Online: ' + esc(bat.AcOnline) + ' | Voltage: ' + esc(bat.VoltageMv ? bat.VoltageMv + ' mV' : 'N/A')) +
      kvRow('AC Load Stability', (bat.AcFlickerDetected || bat.VoltageDroopDetected)
        ? badgeHtml('WARN', 'Flicker/Droop Detected (' + bat.VoltageDroopPct + '%)')
        : badgeHtml('PASS', 'Stable (Droop ' + (bat.VoltageDroopPct || 0) + '%)'));
    toArr(bat.Batteries).forEach(function (b, idx) {
      batRows += kvRow('Battery #' + (idx + 1), esc((b.Manufacturer || '') + ' ' + (b.Id || '') + ' | Design: ' + b.DesignCapacityMWh + ' mWh | Full: ' + b.FullChargeMWh + ' mWh (' + (b.HealthPercent || '?') + '%) | Cycles: ' + (b.CycleCount !== null && b.CycleCount !== undefined ? b.CycleCount : 'N/A')));
    });
    document.getElementById('tbl-battery').innerHTML = batRows;

    var cpu = reportData.Cpu || {};
    document.getElementById('tbl-cpu').innerHTML =
      kvRow('Processor', esc((cpu.CpuName || '') + ' (' + cpu.PhysicalCores + 'C / ' + cpu.LogicalProcessors + 'T @ ' + cpu.MaxClockMHz + ' MHz)')) +
      kvRow('Verified Workload', cpu.StressSkipped
        ? badgeHtml('UNAVAILABLE', 'Skipped')
        : (badgeHtml(cpu.VerificationPassed ? 'PASS' : 'FAIL', cpu.VerificationPassed ? 'Int+FP Checksum PASS' : 'Checksum FAIL') +
          ' Int: ' + esc(cpu.IntOpsPerSec) + '/s | FP: ' + esc(cpu.FpOpsPerSec) + '/s')) +
      kvRow('Thermals', badgeHtml(cpu.ThermalStatus) + ' Idle: ' + (cpu.IdleTempC !== null && cpu.IdleTempC !== undefined ? cpu.IdleTempC + ' &deg;C' : 'N/A') +
        ' | Peak: ' + (cpu.PeakTempC !== null && cpu.PeakTempC !== undefined ? cpu.PeakTempC + ' &deg;C' : 'UNAVAILABLE') +
        (cpu.PeakGpuTempC !== null && cpu.PeakGpuTempC !== undefined ? ' | dGPU Peak: ' + cpu.PeakGpuTempC + ' &deg;C' : ''));

    var gpu = reportData.Gpu || {};
    var gpuRows = '';
    toArr(gpu.Gpus).forEach(function (g, idx) {
      gpuRows += kvRow('GPU #' + (idx + 1) + ' (' + (g.Type || '') + ')',
        '<strong>' + esc(g.Name) + '</strong> | VRAM: ' + esc(g.VramGB) + ' GB (' + esc(g.VramMB) + ' MB) | Driver: ' + esc(g.DriverVersion) +
        ' | ' + badgeHtml(g.ErrorCode === 0 ? 'PASS' : 'FAIL', 'ErrCode=' + g.ErrorCode));
    });
    toArr(gpu.NvidiaTelemetry).forEach(function (nv) {
      gpuRows += kvRow('NVIDIA Telemetry', esc(nv.Name + ' | VBIOS ' + nv.VbiosVersion + ' | Temp ' + nv.TempC + ' C | Power ' + nv.PowerDrawW + '/' + nv.PowerLimitW + 'W | PCIe Gen' + nv.PcieGen + ' x' + nv.PcieWidth));
    });
    document.getElementById('tbl-gpu').innerHTML = gpuRows || kvRow('GPU', 'None detected');

    var ram = reportData.Ram || {};
    var ramRows = kvRow('Capacity & Slots', '<strong>' + esc(ram.TotalGB) + ' GB</strong> | Used ' + esc(ram.UsedSlots) + ' / ' + esc(ram.TotalSlots) + ' slots | Free: ' + esc(ram.FreeSlots) + (ram.SolderedDetected ? ' (Soldered/LPDDR)' : '')) +
      kvRow('Pattern Check (128MB)', badgeHtml((ram.PatternTest || {}).Status) + ' ' + esc((ram.PatternTest || {}).Detail || ''));
    toArr(ram.Dimms).forEach(function (d, idx) {
      ramRows += kvRow('DIMM #' + (idx + 1), esc(d.CapacityGB + ' GB ' + d.MemoryType + ' @ ' + (d.ConfiguredClockMTs || d.SpeedMTs) + ' MT/s | ' + d.FormFactor + ' | ' + d.Manufacturer + ' ' + d.PartNumber));
    });
    document.getElementById('tbl-ram').innerHTML = ramRows;

    var stor = reportData.Storage || {};
    var storRows = kvRow('Storage Status', badgeHtml(stor.Status) + (stor.Benchmark && stor.Benchmark.SeqReadMBs ? (' | Seq Read: <strong>' + stor.Benchmark.SeqReadMBs + ' MB/s</strong>, Write: <strong>' + stor.Benchmark.SeqWriteMBs + ' MB/s</strong>') : (' | ' + esc((stor.Benchmark || {}).Note || ''))));
    toArr(stor.Disks).forEach(function (dk) {
      var wearStr = (dk.WearPercent !== null && dk.WearPercent !== undefined) ? (dk.WearPercent + '% wear') : 'Wear N/A';
      var tempStr = (dk.TemperatureC !== null && dk.TemperatureC !== undefined) ? (dk.TemperatureC + ' &deg;C') : 'Temp N/A';
      var pohStr = (dk.PowerOnHours !== null && dk.PowerOnHours !== undefined) ? (dk.PowerOnHours + ' hrs') : 'POH N/A';
      storRows += kvRow((dk.IsExternal ? 'External (' + dk.BusType + ')' : 'Internal (' + dk.BusType + ')'),
        esc(dk.FriendlyName + ' (' + dk.SizeGB + ' GB) | ') + badgeHtml(dk.HealthStatus === 'Healthy' ? 'PASS' : 'FAIL', dk.HealthStatus) + ' | ' + wearStr + ' | ' + tempStr + ' | ' + esc(pohStr));
    });
    document.getElementById('tbl-storage').innerHTML = storRows;

    var per = reportData.Peripherals || {};
    var disp = per.Display || {};
    var dRows = '';
    toArr(disp.Panels).forEach(function (p, i) {
      dRows += kvRow('Panel #' + (i + 1), esc((p.Manufacturer || '') + ' ' + (p.Model || '') + ' | ' + (p.DiagonalIn ? p.DiagonalIn + ' in' : '') + ' | ' + (p.Resolution || disp.PrimaryRes) + ' @ ' + (p.RefreshRateHz || disp.PrimaryHz) + ' Hz | Mfg ' + (p.Year || '?') + '-W' + (p.Week || '?')));
    });
    dRows += kvRow('Touchscreen', disp.Touchscreen ? 'Detected' : 'Not Detected');
    dRows += kvRow('Cameras / Hello IR', toArr(per.Cameras).map(function (cm) { return esc(cm.Name + ' [' + cm.Status + ']'); }).join('<br>') || 'None detected');
    dRows += kvRow('Fingerprint / Biometrics', toArr(per.Biometrics).map(function (b) { return esc(b.Name + ' [' + b.Status + ']'); }).join('<br>') || 'None detected');
    dRows += kvRow('Audio Devices', toArr(per.AudioDevices).map(function (a) { return esc(a.Name + ' [' + a.Status + ']'); }).join('<br>') || 'None');
    dRows += kvRow('Port Controllers', toArr(per.Ports).map(esc).join(', ') || 'Standard USB');
    document.getElementById('tbl-display-periph').innerHTML = dRows;

    var net = per.Network || {};
    var nRows = kvRow('Wi-Fi Capability', esc((net.WifiGeneration || 'Unknown') + (net.WifiSsid ? (' | SSID: ' + net.WifiSsid + ' (' + net.WifiSignalPct + '%)') : ' | Not connected'))) +
      kvRow('Local Gateway Ping', net.GatewayIp
        ? (esc(net.GatewayIp) + ' -> ' + (net.GatewayReachable ? badgeHtml('PASS', 'Reachable (' + net.GatewayLatencyMs + ' ms)') : badgeHtml('WARN', 'Unreachable')))
        : 'No default gateway') +
      kvRow('Bluetooth', toArr(per.Bluetooth).map(function (bt) { return esc(bt.Name + ' [' + bt.Status + ']'); }).join(', ') || 'None detected');

    var errs = toArr(per.DeviceErrors);
    nRows += kvRow('Device Manager Errors', errs.length === 0
      ? badgeHtml('PASS', '0 Errors')
      : (badgeHtml('WARN', errs.length + ' Issue(s)') + '<br>' + errs.map(function (e) { return esc(e.Name + ' (Code ' + e.ErrorCode + ': ' + e.Description + ')'); }).join('<br>')));
    document.getElementById('tbl-network-errors').innerHTML = nRows;

    var bios = (reportData.CorporateLock || {}).BiosSecurity || {};
    document.getElementById('bios-manual-summary').innerHTML = bios.WmiChecked
      ? ('Vendor BIOS WMI checked via <strong>' + esc(bios.VendorProvider) + '</strong>. PasswordSet=' + esc(bios.PasswordSet) + '. Details: ' + esc(toArr(((reportData.CorporateLock || {}).Computrace || {}).BiosSettings).join(' | ')))
      : 'Vendor BIOS WMI is <strong>UNAVAILABLE</strong> on this system. Please reboot and enter BIOS/UEFI Setup manually to verify Supervisor Password and Computrace status.';
  }

  function renderWizardPills() {
    var box = document.getElementById('step-pills');
    box.innerHTML = STEPS.map(function (st, idx) {
      var res = manualState.results[st.id];
      var dotCls = res === 'PASS' ? 'pass' : (res === 'FAIL' ? 'fail' : (res === 'NA' ? 'na' : ''));
      return '<button class="step-pill ' + (idx === currentStepIdx ? 'active' : '') + '" onclick="goToStep(' + idx + ')">' +
        '<span class="dot ' + dotCls + '"></span>' + esc(st.label) + '</button>';
    }).join('');
    document.getElementById('wizard-step-label').textContent = 'Step ' + (currentStepIdx + 1) + ' of ' + STEPS.length;
  }

  function cleanupActiveStepMedia(leavingIdx) {
    if (leavingIdx === 3) stopAudio();
    if (leavingIdx === 4) stopWebcam();
    if (leavingIdx === 5) stopMic();
    if (leavingIdx === 6) stopPortWatcher();
    if (leavingIdx === 7) stopGpuStress();
  }

  window.goToStep = function (idx) {
    if (idx < 0 || idx >= STEPS.length) return;
    if (idx !== currentStepIdx) {
      cleanupActiveStepMedia(currentStepIdx);
    }
    var panels = document.querySelectorAll('.step-panel');
    for (var i = 0; i < panels.length; i++) panels[i].classList.remove('active');
    currentStepIdx = idx;
    document.getElementById('step-' + (idx + 1)).classList.add('active');
    renderWizardPills();
    if (idx === 6 && window.__LI_SERVER__ === true) {
      startPortWatcher();
    }
  };
  window.nextStep = function () { window.goToStep((currentStepIdx + 1) % STEPS.length); };
  window.prevStep = function () { window.goToStep((currentStepIdx - 1 + STEPS.length) % STEPS.length); };
  window.scrollToWizard = function () { document.getElementById('wizard-card').scrollIntoView({ behavior: 'smooth' }); };

  window.setStepResult = function (val) {
    var st = STEPS[currentStepIdx];
    manualState.results[st.id] = val;
    renderWizardPills();
    renderTopAndScoring();
    showToast(st.label + ' marked ' + val);
  };

  window.updateField = function (k, v) {
    manualState[k] = v;
    renderTopAndScoring();
  };

  window.togglePortCheck = function (k, checked) {
    manualState.checks[k] = !!checked;
    renderPrintManualSummary(computeLiveVerdict());
  };

  function renderPrintManualSummary(live) {
    var rows = '';
    STEPS.forEach(function (st) {
      var r = manualState.results[st.id] || 'Pending';
      rows += kvRow(st.label, badgeHtml(r === 'PASS' ? 'PASS' : (r === 'FAIL' ? 'FAIL' : (r === 'NA' ? 'WARN' : 'UNAVAILABLE')), r));
    });
    rows += kvRow('Cosmetic Grade', esc('Chassis: ' + (manualState.chassisGrade || '-') + ' | Screen: ' + (manualState.screenGrade || '-') + ' | Hinges: ' + (manualState.hingesGrade || '-') + ' | Charger: ' + (manualState.chargerType || '-')));
    rows += kvRow('Seller / Price / Notes', esc('Seller: ' + (manualState.sellerName || '-') + ' | Price: ' + (manualState.askingPrice || '-') + ' | Notes: ' + (manualState.notes || '-')));
    rows += kvRow('Final Combined Verdict', badgeHtml(live.verdict) + ' (' + live.score + '/100)');
    document.getElementById('tbl-print-manual').innerHTML = rows;
  }

  function restoreManualInputs() {
    if (manualState.kbBacklight) document.getElementById('kb-backlight').value = manualState.kbBacklight;
    if (manualState.audioJack) document.getElementById('audio-jack').value = manualState.audioJack;
    if (manualState.chassisGrade) document.getElementById('grade-chassis').value = manualState.chassisGrade;
    if (manualState.screenGrade) document.getElementById('grade-screen').value = manualState.screenGrade;
    if (manualState.hingesGrade) document.getElementById('grade-hinges').value = manualState.hingesGrade;
    if (manualState.chargerType) document.getElementById('grade-charger').value = manualState.chargerType;
    if (manualState.sellerName) document.getElementById('meta-seller').value = manualState.sellerName;
    if (manualState.askingPrice) document.getElementById('meta-price').value = manualState.askingPrice;
    if (manualState.notes) document.getElementById('meta-notes').value = manualState.notes;

    var cMap = {
      usba: 'chk-usba', usbc: 'chk-usbc', pd: 'chk-pd', hdmi: 'chk-hdmi', eth: 'chk-eth', bt: 'chk-bt',
      biosNoPwd: 'chk-bios-pwd', biosNoComputrace: 'chk-bios-comp', oobeChecked: 'chk-bios-oobe'
    };
    Object.keys(cMap).forEach(function (k) {
      var el = document.getElementById(cMap[k]);
      if (el && manualState.checks[k]) el.checked = true;
    });
  }

  // ---- Step 1: Keyboard Matrix ----
  var KB_MAIN = [
    [['Escape','Esc'],['gap',''],['F1','F1'],['F2','F2'],['F3','F3'],['F4','F4'],['gap',''],['F5','F5'],['F6','F6'],['F7','F7'],['F8','F8'],['gap',''],['F9','F9'],['F10','F10'],['F11','F11'],['F12','F12']],
    [['Backquote','`'],['Digit1','1'],['Digit2','2'],['Digit3','3'],['Digit4','4'],['Digit5','5'],['Digit6','6'],['Digit7','7'],['Digit8','8'],['Digit9','9'],['Digit0','0'],['Minus','-'],['Equal','='],['Backspace','Back','w2']],
    [['Tab','Tab','w15'],['KeyQ','Q'],['KeyW','W'],['KeyE','E'],['KeyR','R'],['KeyT','T'],['KeyY','Y'],['KeyU','U'],['KeyI','I'],['KeyO','O'],['KeyP','P'],['BracketLeft','['],['BracketRight',']'],['Backslash','\\','w15']],
    [['CapsLock','Caps','w175'],['KeyA','A'],['KeyS','S'],['KeyD','D'],['KeyF','F'],['KeyG','G'],['KeyH','H'],['KeyJ','J'],['KeyK','K'],['KeyL','L'],['Semicolon',';'],['Quote',"'"],['Enter','Enter','w225']],
    [['ShiftLeft','Shift','w225'],['KeyZ','Z'],['KeyX','X'],['KeyC','C'],['KeyV','V'],['KeyB','B'],['KeyN','N'],['KeyM','M'],['Comma',','],['Period','.'],['Slash','/'],['ShiftRight','Shift','w225']],
    [['ControlLeft','Ctrl','w15'],['MetaLeft','Win'],['AltLeft','Alt'],['Space','Space','w6'],['AltRight','Alt'],['ContextMenu','Menu'],['ControlRight','Ctrl','w15']]
  ];
  var KB_NAV = [
    [['PrintScreen','PrtSc'],['ScrollLock','ScrLk'],['Pause','Pause']],
    [['Insert','Ins'],['Home','Home'],['PageUp','PgUp']],
    [['Delete','Del'],['End','End'],['PageDown','PgDn']],
    [['gap',''],['gap',''],['gap','']],
    [['gap',''],['ArrowUp','Up'],['gap','']],
    [['ArrowLeft','Left'],['ArrowDown','Dn'],['ArrowRight','Right']]
  ];
  var KB_NUM = [
    [['gap',''],['gap',''],['gap',''],['gap','']],
    [['NumLock','Num'],['NumpadDivide','/'],['NumpadMultiply','*'],['NumpadSubtract','-']],
    [['Numpad7','7'],['Numpad8','8'],['Numpad9','9'],['NumpadAdd','+']],
    [['Numpad4','4'],['Numpad5','5'],['Numpad6','6'],['gap','']],
    [['Numpad1','1'],['Numpad2','2'],['Numpad3','3'],['NumpadEnter','Ent']],
    [['Numpad0','0','w2'],['NumpadDecimal','.'],['gap','']]
  ];

  function renderKbBlock(rows) {
    return rows.map(function (row) {
      return '<div class="kb-row">' + row.map(function (item) {
        var code = item[0], label = item[1], cls = item[2] || '';
        if (code === 'gap') return '<div class="k gap"></div>';
        return '<div class="k ' + cls + '" data-code="' + esc(code) + '">' + esc(label) + '</div>';
      }).join('') + '</div>';
    }).join('');
  }
  document.getElementById('kb-board').innerHTML =
    '<div class="kb-main">' + renderKbBlock(KB_MAIN) + '</div>' +
    '<div class="kb-nav">' + renderKbBlock(KB_NAV) + '</div>' +
    '<div class="kb-num">' + renderKbBlock(KB_NUM) + '</div>';

  var kbHits = {};
  var kbLastDown = {};
  var kbChatter = 0;

  window.resetKeyboard = function () {
    kbHits = {}; kbLastDown = {}; kbChatter = 0;
    manualState.kbTestedCount = 0;
    manualState.kbChatterCount = 0;
    var els = document.querySelectorAll('#kb-board .k');
    for (var i = 0; i < els.length; i++) els[i].classList.remove('hit', 'chatter');
    document.getElementById('kb-count').textContent = '0 keys pressed';
    document.getElementById('kb-chatter').textContent = 'Chatter: 0';
    document.getElementById('kb-chatter').className = 'badge b-pass';
  };

  document.addEventListener('keydown', function (e) {
    if (document.getElementById('screen-overlay').classList.contains('active')) {
      if (e.key === 'Escape') { exitScreenTest(); return; }
      if (e.key === ' ' || e.key === 'ArrowRight') { e.preventDefault(); nextScreenMode(); return; }
      if (e.key === 'ArrowLeft') { e.preventDefault(); prevScreenMode(); return; }
    }
    var tag = (e.target && e.target.tagName) ? e.target.tagName.toUpperCase() : '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (currentStepIdx !== 0) return;

    e.preventDefault();
    var code = e.code || e.key;
    var now = performance.now();
    var el = document.querySelector('#kb-board .k[data-code="' + CSS.escape(code) + '"]');
    if (!e.repeat && kbLastDown[code] && (now - kbLastDown[code]) < 15) {
      kbChatter++;
      manualState.kbChatterCount = kbChatter;
      document.getElementById('kb-chatter').textContent = 'Chatter: ' + kbChatter;
      document.getElementById('kb-chatter').className = 'badge b-warn';
      if (el) el.classList.add('chatter');
    }
    if (!e.repeat) kbLastDown[code] = now;
    if (!kbHits[code]) {
      kbHits[code] = true;
      manualState.kbTestedCount = Object.keys(kbHits).length;
      document.getElementById('kb-count').textContent = manualState.kbTestedCount + ' keys pressed';
    }
    if (el) el.classList.add('hit');
  });

  // ---- Step 2: Touchpad & Touchscreen ----
  var tpCanvas = document.getElementById('tp-canvas');
  var tpCtx = tpCanvas.getContext('2d');
  var tpDrawing = false;
  var tpMovedOnDown = false;
  var tpBadges = {};

  function markTp(id, label) {
    if (tpBadges[id]) return;
    tpBadges[id] = true;
    var el = document.getElementById(id);
    if (el) { el.className = 'badge b-pass'; el.textContent = label + ': OK'; }
  }
  window.clearTouchpadCanvas = function () {
    tpCtx.clearRect(0, 0, tpCanvas.width, tpCanvas.height);
  };
  tpCanvas.addEventListener('contextmenu', function (e) { e.preventDefault(); markTp('tp-right', 'Right Click'); });
  tpCanvas.addEventListener('pointerdown', function (e) {
    tpDrawing = true;
    tpMovedOnDown = false;
    var rect = tpCanvas.getBoundingClientRect();
    var x = (e.clientX - rect.left) * (tpCanvas.width / rect.width);
    var y = (e.clientY - rect.top) * (tpCanvas.height / rect.height);
    tpCtx.beginPath();
    tpCtx.moveTo(x, y);
    if (e.button === 0) markTp('tp-left', 'Left Click');
    else if (e.button === 1) markTp('tp-middle', 'Middle Click');
    else if (e.button === 2) markTp('tp-right', 'Right Click');
    if (e.pointerType === 'touch' || e.pointerType === 'pen') markTp('tp-touch', 'Touch/Pen');
  });
  tpCanvas.addEventListener('pointermove', function (e) {
    markTp('tp-move', 'Move');
    if (!tpDrawing) return;
    tpMovedOnDown = true;
    markTp('tp-drag', 'Drag');
    var rect = tpCanvas.getBoundingClientRect();
    var x = (e.clientX - rect.left) * (tpCanvas.width / rect.width);
    var y = (e.clientY - rect.top) * (tpCanvas.height / rect.height);
    tpCtx.strokeStyle = '#38bdf8';
    tpCtx.lineWidth = 3;
    tpCtx.lineCap = 'round';
    tpCtx.lineTo(x, y);
    tpCtx.stroke();
  });
  window.addEventListener('pointerup', function () { tpDrawing = false; });
  tpCanvas.addEventListener('wheel', function (e) { e.preventDefault(); markTp('tp-scroll', 'Scroll'); }, { passive: false });

  // ---- Step 3: Screen 10-Mode Fullscreen Inspector ----
  var SCREEN_MODES = [
    { name: 'Solid Black (Backlight Bleed)', bg: '#000000' },
    { name: 'Solid White (Uniformity / Yellowing)', bg: '#ffffff' },
    { name: 'Pure Red (Subpixels)', bg: '#ff0000' },
    { name: 'Pure Green (Subpixels)', bg: '#00ff00' },
    { name: 'Pure Blue (Subpixels)', bg: '#0000ff' },
    { name: '50% Neutral Gray (Burn-In / Uniformity)', bg: '#808080' },
    { name: 'RGB Color Gradient (Banding)', bg: 'linear-gradient(90deg,#000,#f00,#0f0,#00f,#fff)' },
    { name: 'Checkerboard (Contrast / Pixel Inversion)', bg: 'repeating-conic-gradient(#000 0% 25%, #fff 0% 50%) 50% / 32px 32px' },
    { name: 'Alignment Grid', bg: '#000 linear-gradient(#2c3e50 1px, transparent 1px), linear-gradient(90deg, #2c3e50 1px, transparent 1px)' },
    { name: 'Motion & Refresh Rate Test', motion: true }
  ];
  var screenModeIdx = 0;
  var motionRaf = null;

  function applyScreenMode() {
    var ov = document.getElementById('screen-overlay');
    var mc = document.getElementById('screen-motion-canvas');
    var hud = document.getElementById('screen-hud');
    var m = SCREEN_MODES[screenModeIdx];

    if (motionRaf) { cancelAnimationFrame(motionRaf); motionRaf = null; }
    ov.style.backgroundSize = '';

    if (m.motion) {
      mc.style.display = 'block';
      mc.width = window.innerWidth;
      mc.height = window.innerHeight;
      var ctx = mc.getContext('2d');
      var x = 0;
      var frames = 0;
      var lastTs = performance.now();
      var measuredHz = 60;
      var loop = function (ts) {
        if (!ov.classList.contains('active') || !SCREEN_MODES[screenModeIdx].motion) return;
        frames++;
        if (ts - lastTs >= 500) {
          measuredHz = Math.round((frames * 1000) / (ts - lastTs));
          document.getElementById('screen-hz-label').textContent = measuredHz + ' Hz';
          hud.textContent = (screenModeIdx + 1) + '/10: ' + m.name + ' (' + measuredHz + ' Hz) | Click/Space=Next | Esc=Exit';
          frames = 0; lastTs = ts;
        }
        ctx.fillStyle = '#0b1020';
        ctx.fillRect(0, 0, mc.width, mc.height);
        for (var r = 0; r < 5; r++) {
          var speed = (r + 1) * 4;
          var rx = (x * speed) % (mc.width + 120) - 120;
          ctx.fillStyle = ['#38bdf8', '#4ade80', '#fbbf24', '#f87171', '#ffffff'][r];
          ctx.fillRect(rx, 80 + r * ((mc.height - 160) / 5), 110, 48);
        }
        x += 1;
        motionRaf = requestAnimationFrame(loop);
      };
      hud.textContent = (screenModeIdx + 1) + '/10: ' + m.name + ' | Measuring Hz... | Esc=Exit';
      motionRaf = requestAnimationFrame(loop);
    } else {
      mc.style.display = 'none';
      if (m.name.indexOf('Alignment Grid') === 0) {
        ov.style.background = '#05080f';
        ov.style.backgroundImage = 'linear-gradient(rgba(56,189,248,0.45) 1px, transparent 1px), linear-gradient(90deg, rgba(56,189,248,0.45) 1px, transparent 1px)';
        ov.style.backgroundSize = '40px 40px';
      } else {
        ov.style.background = m.bg;
      }
      hud.textContent = (screenModeIdx + 1) + '/10: ' + m.name + ' | Click/Space=Next | Esc=Exit';
    }
  }

  window.startScreenTest = function (idx) {
    screenModeIdx = idx || 0;
    var ov = document.getElementById('screen-overlay');
    ov.classList.add('active');
    applyScreenMode();
    if (ov.requestFullscreen) { ov.requestFullscreen().catch(function () {}); }
  };
  window.nextScreenMode = function () {
    if (screenModeIdx + 1 >= SCREEN_MODES.length) { exitScreenTest(); return; }
    screenModeIdx++;
    applyScreenMode();
  };
  window.prevScreenMode = function () {
    screenModeIdx = (screenModeIdx - 1 + SCREEN_MODES.length) % SCREEN_MODES.length;
    applyScreenMode();
  };
  function exitScreenTest() {
    if (motionRaf) { cancelAnimationFrame(motionRaf); motionRaf = null; }
    var ov = document.getElementById('screen-overlay');
    ov.classList.remove('active');
    if (document.fullscreenElement && document.exitFullscreen) {
      document.exitFullscreen().catch(function () {});
    }
  }

  // ---- Step 4: Speakers & Audio ----
  var audioCtx = null;
  var activeOsc = null;
  function getAC() {
    if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === 'suspended') audioCtx.resume();
    return audioCtx;
  }
  window.stopAudio = function () {
    if (activeOsc) { try { activeOsc.stop(); activeOsc.disconnect(); } catch (e) {} activeOsc = null; }
  };
  window.playTone = function (panMode) {
    window.stopAudio();
    var ctx = getAC();
    var osc = ctx.createOscillator();
    var gain = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.value = 440;
    gain.gain.value = 0.25;
    if (ctx.createStereoPanner) {
      var pan = ctx.createStereoPanner();
      pan.pan.value = panMode === 'left' ? -1 : (panMode === 'right' ? 1 : 0);
      osc.connect(gain).connect(pan).connect(ctx.destination);
    } else {
      osc.connect(gain).connect(ctx.destination);
    }
    osc.start();
    activeOsc = osc;
  };
  window.playSweep = function () {
    window.stopAudio();
    var ctx = getAC();
    var osc = ctx.createOscillator();
    var gain = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(120, ctx.currentTime);
    osc.frequency.exponentialRampToValueAtTime(6000, ctx.currentTime + 4.0);
    gain.gain.value = 0.22;
    osc.connect(gain).connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + 4.1);
    activeOsc = osc;
  };

  // ---- Step 5: Webcam ----
  var camStream = null;
  window.startWebcam = function () {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      document.getElementById('cam-msg').textContent = 'Camera API unavailable (run via localhost server instead of file://).';
      return;
    }
    navigator.mediaDevices.getUserMedia({ video: true }).then(function (stream) {
      camStream = stream;
      var v = document.getElementById('cam-video');
      v.srcObject = stream;
      v.onloadedmetadata = function () {
        document.getElementById('cam-res').textContent = v.videoWidth + 'x' + v.videoHeight;
      };
      document.getElementById('cam-msg').textContent = 'Camera active. Tracks auto-stop when leaving this step.';
    }).catch(function (err) {
      document.getElementById('cam-msg').textContent = 'Webcam error: ' + err.message;
    });
  };
  window.stopWebcam = function () {
    if (camStream) {
      camStream.getTracks().forEach(function (t) { t.stop(); });
      camStream = null;
    }
    var v = document.getElementById('cam-video');
    if (v) v.srcObject = null;
  };

  // ---- Step 6: Microphone & WAV ----
  var micStream = null;
  var micRaf = null;
  var micAudioCtx = null;
  var lastWavBlob = null;

  function encodeWavFromAudioBuffer(abuf) {
    var numCh = 1;
    var data = abuf.getChannelData(0);
    var sampleRate = abuf.sampleRate;
    var buffer = new ArrayBuffer(44 + data.length * 2);
    var view = new DataView(buffer);
    function ws(off, str) { for (var i = 0; i < str.length; i++) view.setUint8(off + i, str.charCodeAt(i)); }
    ws(0, 'RIFF'); view.setUint32(4, 36 + data.length * 2, true);
    ws(8, 'WAVE'); ws(12, 'fmt '); view.setUint32(16, 16, true);
    view.setUint16(20, 1, true); view.setUint16(22, numCh, true);
    view.setUint32(24, sampleRate, true); view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    ws(36, 'data'); view.setUint32(40, data.length * 2, true);
    var offset = 44;
    for (var i = 0; i < data.length; i++, offset += 2) {
      var s = Math.max(-1, Math.min(1, data[i]));
      view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
    return new Blob([buffer], { type: 'audio/wav' });
  }

  window.startMic = function () {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      document.getElementById('mic-msg').textContent = 'Microphone API unavailable (run via localhost server instead of file://).';
      return;
    }
    navigator.mediaDevices.getUserMedia({ audio: true }).then(function (stream) {
      micStream = stream;
      micAudioCtx = new (window.AudioContext || window.webkitAudioContext)();
      var src = micAudioCtx.createMediaStreamSource(stream);
      var analyser = micAudioCtx.createAnalyser();
      analyser.fftSize = 512;
      src.connect(analyser);
      var buf = new Uint8Array(analyser.frequencyBinCount);
      var cv = document.getElementById('mic-canvas');
      var ctx = cv.getContext('2d');
      var draw = function () {
        if (!micStream) return;
        analyser.getByteTimeDomainData(buf);
        var peak = 0;
        ctx.fillStyle = '#0b1220';
        ctx.fillRect(0, 0, cv.width, cv.height);
        ctx.strokeStyle = '#4ade80';
        ctx.lineWidth = 2;
        ctx.beginPath();
        for (var i = 0; i < buf.length; i++) {
          var v = (buf[i] - 128) / 128;
          if (Math.abs(v) > peak) peak = Math.abs(v);
          var x = (i / buf.length) * cv.width;
          var y = (cv.height / 2) + v * (cv.height / 2);
          if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        }
        ctx.stroke();
        document.getElementById('mic-meter').style.width = Math.min(100, Math.round(peak * 180)) + '%';
        micRaf = requestAnimationFrame(draw);
      };
      draw();
      document.getElementById('mic-msg').textContent = 'Listening... Speak near microphone.';
    }).catch(function (err) {
      document.getElementById('mic-msg').textContent = 'Microphone error: ' + err.message;
    });
  };
  window.recordMicSample = function () {
    if (!micStream) { window.startMic(); setTimeout(window.recordMicSample, 450); return; }
    if (typeof MediaRecorder === 'undefined') {
      document.getElementById('mic-msg').textContent = 'MediaRecorder unsupported in this browser.';
      return;
    }
    var chunks = [];
    var mr = new MediaRecorder(micStream);
    mr.ondataavailable = function (e) { if (e.data.size > 0) chunks.push(e.data); };
    mr.onstop = function () {
      var blob = new Blob(chunks, { type: mr.mimeType || 'audio/webm' });
      var au = document.getElementById('mic-playback');
      au.src = URL.createObjectURL(blob);
      au.style.display = 'block';
      document.getElementById('mic-msg').textContent = '3s recording ready for playback.';
      blob.arrayBuffer().then(function (ab) {
        return getAC().decodeAudioData(ab);
      }).then(function (decoded) {
        lastWavBlob = encodeWavFromAudioBuffer(decoded);
        document.getElementById('btn-dl-wav').style.display = 'inline-flex';
      }).catch(function () {});
    };
    document.getElementById('mic-msg').textContent = 'Recording 3 seconds...';
    mr.start();
    setTimeout(function () { if (mr.state === 'recording') mr.stop(); }, 3000);
  };
  window.downloadLastWav = function () {
    if (!lastWavBlob) return;
    var a = document.createElement('a');
    a.href = URL.createObjectURL(lastWavBlob);
    a.download = 'LaptopInspect_MicCheck.wav';
    a.click();
  };
  window.stopMic = function () {
    if (micRaf) { cancelAnimationFrame(micRaf); micRaf = null; }
    if (micStream) { micStream.getTracks().forEach(function (t) { t.stop(); }); micStream = null; }
    if (micAudioCtx) { try { micAudioCtx.close(); } catch (e) {} micAudioCtx = null; }
  };

  // ---- Step 7: Live Hot-Plug Port Watcher ----
  var portTimer = null;
  var prevSnap = reportData.InitialPorts || null;

  function snapSet(arr, keyFn) {
    var m = {};
    toArr(arr).forEach(function (x) { m[keyFn(x)] = true; });
    return m;
  }
  function appendPortLog(msg) {
    var box = document.getElementById('port-log');
    var line = document.createElement('div');
    line.textContent = msg;
    box.appendChild(line);
    box.scrollTop = box.scrollHeight;
  }
  function diffSnapshots(oldS, newS) {
    if (!oldS) return;
    var ts = newS.Timestamp || '';
    if (oldS.AcOnline !== newS.AcOnline) {
      appendPortLog('[' + ts + '] AC Power changed: ' + (newS.AcOnline ? 'PLUGGED IN' : 'UNPLUGGED'));
    }
    var oldUsb = snapSet(oldS.UsbDevices, function (u) { return u.DeviceID || u.Name; });
    var newUsb = snapSet(newS.UsbDevices, function (u) { return u.DeviceID || u.Name; });
    toArr(newS.UsbDevices).forEach(function (u) { if (!oldUsb[u.DeviceID || u.Name]) appendPortLog('[' + ts + '] + USB CONNECTED: ' + u.Name); });
    toArr(oldS.UsbDevices).forEach(function (u) { if (!newUsb[u.DeviceID || u.Name]) appendPortLog('[' + ts + '] - USB REMOVED: ' + u.Name); });

    var oldMon = snapSet(oldS.Monitors, function (m) { return m; });
    var newMon = snapSet(newS.Monitors, function (m) { return m; });
    toArr(newS.Monitors).forEach(function (m) { if (!oldMon[m]) appendPortLog('[' + ts + '] + DISPLAY CONNECTED: ' + m); });
    toArr(oldS.Monitors).forEach(function (m) { if (!newMon[m]) appendPortLog('[' + ts + '] - DISPLAY REMOVED: ' + m); });

    var oldNet = snapSet(oldS.NetLinks, function (n) { return n.Name; });
    var newNet = snapSet(newS.NetLinks, function (n) { return n.Name; });
    toArr(newS.NetLinks).forEach(function (n) { if (!oldNet[n.Name]) appendPortLog('[' + ts + '] + NET LINK UP: ' + n.Name + ' (' + n.LinkSpeed + ')'); });
    toArr(oldS.NetLinks).forEach(function (n) { if (!newNet[n.Name]) appendPortLog('[' + ts + '] - NET LINK DOWN: ' + n.Name); });
  }
  function startPortWatcher() {
    if (portTimer) return;
    if (!window.__LI_SERVER__) {
      document.getElementById('port-watch-status').textContent = 'Live Port Watcher requires the local server (active automatically on run). Use manual checkboxes below.';
      return;
    }
    document.getElementById('port-watch-status').textContent = 'Live Port Watcher ACTIVE (polling every 1.5s)...';
    document.getElementById('btn-port-watch').textContent = 'Stop Port Watcher';
    document.getElementById('port-log').textContent = 'Watching ports (baseline ' + toArr((prevSnap || {}).UsbDevices).length + ' USB devices)...';
    portTimer = setInterval(function () {
      fetch('/api/ports').then(function (r) { return r.json(); }).then(function (snap) {
        diffSnapshots(prevSnap, snap);
        prevSnap = snap;
      }).catch(function () {});
    }, 1500);
  }
  function stopPortWatcher() {
    if (portTimer) { clearInterval(portTimer); portTimer = null; }
    var btn = document.getElementById('btn-port-watch');
    if (btn) btn.textContent = 'Start Live Port Watcher';
  }
  window.togglePortWatcher = function () {
    if (portTimer) stopPortWatcher(); else startPortWatcher();
  };

  // ---- Step 8: GPU 3D WebGL2 Stress Test ----
  var gpuRaf = null;
  var gpuCountdown = null;
  var gpuObjects = 1500;
  window.setGpuLoad = function (v) { gpuObjects = parseInt(v, 10) || 1500; };
  window.stopGpuStress = function () {
    if (gpuRaf) { cancelAnimationFrame(gpuRaf); gpuRaf = null; }
    if (gpuCountdown) { clearInterval(gpuCountdown); gpuCountdown = null; }
  };
  window.startGpuStress = function (sec) {
    window.stopGpuStress();
    var canvas = document.getElementById('gpu-canvas');
    var gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
    if (!gl) {
      document.getElementById('gpu-renderer').textContent = 'WebGL unavailable on this browser/driver.';
      return;
    }
    var dbg = gl.getExtension('WEBGL_debug_renderer_info');
    var rend = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    document.getElementById('gpu-renderer').textContent = 'WebGL Renderer: ' + rend;

    var vsSrc = 'attribute vec3 p; uniform mat4 m; void main(){ gl_Position = m * vec4(p, 1.0); }';
    var fsSrc = 'precision mediump float; uniform float t; void main(){ gl_FragColor = vec4(0.5+0.5*sin(t), 0.5+0.5*cos(t*1.3), 0.7, 1.0); }';
    function comp(type, src) {
      var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s;
    }
    var prog = gl.createProgram();
    gl.attachShader(prog, comp(gl.VERTEX_SHADER, vsSrc));
    gl.attachShader(prog, comp(gl.FRAGMENT_SHADER, fsSrc));
    gl.linkProgram(prog);
    gl.useProgram(prog);

    var verts = new Float32Array([
      -0.4,-0.4, 0.4,  0.4,-0.4, 0.4,  0.4, 0.4, 0.4, -0.4,-0.4, 0.4,  0.4, 0.4, 0.4, -0.4, 0.4, 0.4,
      -0.4,-0.4,-0.4, -0.4, 0.4,-0.4,  0.4, 0.4,-0.4, -0.4,-0.4,-0.4,  0.4, 0.4,-0.4,  0.4,-0.4,-0.4,
      -0.4, 0.4,-0.4, -0.4, 0.4, 0.4,  0.4, 0.4, 0.4, -0.4, 0.4,-0.4,  0.4, 0.4, 0.4,  0.4, 0.4,-0.4,
      -0.4,-0.4,-0.4,  0.4,-0.4,-0.4,  0.4,-0.4, 0.4, -0.4,-0.4,-0.4,  0.4,-0.4, 0.4, -0.4,-0.4, 0.4
    ]);
    var vb = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vb);
    gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);
    var pLoc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(pLoc);
    gl.vertexAttribPointer(pLoc, 3, gl.FLOAT, false, 0, 0);
    var mLoc = gl.getUniformLocation(prog, 'm');
    var tLoc = gl.getUniformLocation(prog, 't');

    var remaining = sec || 30;
    document.getElementById('gpu-timer').textContent = 'Timer: ' + remaining + 's';
    gpuCountdown = setInterval(function () {
      remaining--;
      document.getElementById('gpu-timer').textContent = 'Timer: ' + Math.max(0, remaining) + 's';
      if (remaining <= 0) window.stopGpuStress();
    }, 1000);

    var frames = 0;
    var fpsLast = performance.now();
    var lastFrame = fpsLast;
    var renderLoop = function (now) {
      var dt = now - lastFrame; lastFrame = now;
      frames++;
      if (now - fpsLast >= 500) {
        var fps = Math.round((frames * 1000) / (now - fpsLast));
        document.getElementById('gpu-fps').textContent = 'FPS: ' + fps;
        document.getElementById('gpu-ft').textContent = 'Frame: ' + dt.toFixed(1) + ' ms';
        frames = 0; fpsLast = now;
      }
      gl.enable(gl.DEPTH_TEST);
      gl.clearColor(0.04, 0.06, 0.12, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      var t = now * 0.002;
      for (var i = 0; i < gpuObjects; i++) {
        var a = t + (i * 0.05);
        var c = Math.cos(a), s = Math.sin(a);
        var ox = ((i % 20) - 10) * 0.08;
        var oy = (Math.floor((i / 20) % 10) - 5) * 0.14;
        var mat = new Float32Array([
          c * 0.15, 0, s * 0.15, 0,
          s * 0.08, c * 0.15, -s * 0.08, 0,
          -s * 0.15, s * 0.08, c * 0.15, 0,
          ox, oy, 0, 1
        ]);
        gl.uniformMatrix4fv(mLoc, false, mat);
        gl.uniform1f(tLoc, t + i * 0.01);
        gl.drawArrays(gl.TRIANGLES, 0, 24);
      }
      gpuRaf = requestAnimationFrame(renderLoop);
    };
    gpuRaf = requestAnimationFrame(renderLoop);
  };

  // ---- Save & Export Actions ----
  function buildPlainTextSummary() {
    var sys = reportData.System || {};
    var corp = reportData.CorporateLock || {};
    var bat = reportData.Battery || {};
    var cpu = reportData.Cpu || {};
    var ram = reportData.Ram || {};
    var stor = reportData.Storage || {};
    var gpu = reportData.Gpu || {};
    var live = computeLiveVerdict();

    var lines = [];
    lines.push('=== LAPTOP INSPECT REPORT ===');
    lines.push('Verdict: ' + live.verdict + ' (' + live.score + '/100)');
    lines.push('Model: ' + (sys.Manufacturer || '') + ' ' + (sys.Model || '') + ' | Serial: ' + (sys.SerialNumber || ''));
    lines.push('Corporate Lock: ' + (corp.ConfirmedCorporateLock ? 'LOCKED / MANAGED' : 'No Local Lock') +
      ' (Autopilot=' + ((corp.Autopilot || {}).Status || '?') + ', MDM=' + ((corp.Mdm || {}).Status || '?') + ', Computrace=' + ((corp.Computrace || {}).Status || '?') + ', BIOS-Pwd=' + ((corp.BiosSecurity || {}).Status || '?') + ')');
    lines.push('CPU: ' + (cpu.CpuName || '') + ' (' + cpu.PhysicalCores + 'C/' + cpu.LogicalProcessors + 'T)');
    lines.push('GPU: ' + toArr(gpu.Gpus).map(function (g) { return g.Name + ' (' + g.VramGB + 'GB)'; }).join('; '));
    lines.push('RAM: ' + (ram.TotalGB || '?') + ' GB (' + (ram.UsedSlots || '?') + '/' + (ram.TotalSlots || '?') + ' slots)');
    lines.push('Storage: ' + toArr(stor.Disks).filter(function (d) { return !d.IsExternal; }).map(function (d) { return d.FriendlyName + ' ' + d.SizeGB + 'GB [' + d.HealthStatus + ']'; }).join('; '));
    lines.push('Battery: ' + (bat.OverallHealthPercent !== null && bat.OverallHealthPercent !== undefined ? bat.OverallHealthPercent + '%' : bat.Condition) +
      ' (' + (bat.Condition || '') + ', Cycles=' + (bat.MaxCycleCount !== null && bat.MaxCycleCount !== undefined ? bat.MaxCycleCount : 'N/A') + ')');
    lines.push('Guided Checks: ' + STEPS.map(function (s) { return s.label.replace(/^\d+\.\s*/, '') + '=' + (manualState.results[s.id] || 'Pending'); }).join(', '));
    if (manualState.chassisGrade || manualState.askingPrice) {
      lines.push('Grade/Price: Chassis=' + (manualState.chassisGrade || '-') + ', Charger=' + (manualState.chargerType || '-') + ', Price=' + (manualState.askingPrice || '-'));
    }
    if (live.crit.length) lines.push('CRITICAL: ' + live.crit.join(' | '));
    if (live.warns.length) lines.push('WARNINGS: ' + live.warns.join(' | '));
    return lines.join('\n');
  }

  window.copyTextSummary = function () {
    var txt = buildPlainTextSummary();
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(txt).then(function () { showToast('Summary copied to clipboard'); });
    } else {
      window.prompt('Copy inspection summary:', txt);
    }
  };

  window.exportTxtSummary = function () {
    var blob = new Blob([buildPlainTextSummary()], { type: 'text/plain;charset=utf-8' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'LaptopInspect_' + ((reportData.System || {}).SerialNumber || 'Report') + '.txt';
    a.click();
  };

  window.saveCompletedReport = function () {
    if (window.__LI_SERVER__ === true) {
      fetch('/api/save', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(manualState)
      }).then(function (r) { return r.json(); }).then(function (res) {
        if (res && res.ok) showToast('Saved completed report to: ' + res.path);
        else showToast('Save failed');
      }).catch(function () { showToast('Save request failed'); });
    } else {
      var manualEl = document.getElementById('li-manual-state');
      manualEl.textContent = JSON.stringify(manualState).replace(/<\/script/gi, '<\\/script');
      var fullHtml = '<!DOCTYPE html>\n' + document.documentElement.outerHTML;
      var blob = new Blob([fullHtml], { type: 'text/html;charset=utf-8' });
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'LaptopReport_Completed_' + ((reportData.System || {}).SerialNumber || 'Report') + '.html';
      a.click();
      showToast('Downloaded updated standalone HTML report');
    }
  };

  window.exportJsonFile = function () {
    if (window.__LI_SERVER__ === true) {
      fetch('/api/export-json', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(manualState)
      }).then(function (r) { return r.json(); }).then(function (res) {
        if (res && res.ok) showToast('Exported JSON to: ' + res.path);
      }).catch(function () {});
    } else {
      var blob = new Blob([JSON.stringify({ Automated: reportData, Manual: manualState }, null, 2)], { type: 'application/json' });
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'LaptopInspect_' + ((reportData.System || {}).SerialNumber || 'Report') + '.json';
      a.click();
    }
  };

  window.shutdownServer = function () {
    if (!window.__LI_SERVER__) return;
    fetch('/api/save', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(manualState) })
      .catch(function () {})
      .finally(function () {
        fetch('/api/shutdown', { method: 'POST' }).then(function () {
          window.__LI_SERVER__ = false;
          stopPortWatcher();
          document.getElementById('btn-shutdown-srv').style.display = 'none';
          showToast('Saved and closed local server cleanly.');
        }).catch(function () {});
      });
  };

  window.toggleTheme = function () {
    var cur = document.documentElement.getAttribute('data-theme') || 'light';
    var next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('li-theme', next); } catch (e) {}
  };

  // Init
  try {
    var savedTheme = localStorage.getItem('li-theme');
    if (savedTheme === 'dark') document.documentElement.setAttribute('data-theme', 'dark');
  } catch (e) {}

  if (window.__LI_SERVER__ === true) {
    document.getElementById('btn-shutdown-srv').style.display = 'inline-flex';
  }
  renderCorporateLock();
  renderTelemetryTables();
  restoreManualInputs();
  renderWizardPills();
  renderTopAndScoring();
})();
</script>
</body>
</html>
'@
# --- END EMBEDDED TEMPLATE ---

# --- BEGIN 10-corporate-lock.ps1 ---
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
    $builtInAuthorities = @('Local Authority', 'Deploy Authority', 'Cloud Authority')
    $enrollBase = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $enrollBase) {
        $subKeys = Get-ChildItem -LiteralPath $enrollBase -ErrorAction SilentlyContinue
        foreach ($sk in $subKeys) {
            $p = $sk.PSPath
            $prov = [string](Get-SafeRegValue -Path $p -Name 'ProviderID' -Default '')
            $disc = [string](Get-SafeRegValue -Path $p -Name 'DiscoveryServiceFullURL' -Default '')
            $upn  = [string](Get-SafeRegValue -Path $p -Name 'UPN' -Default '')
            $aad  = [string](Get-SafeRegValue -Path $p -Name 'AADTenantID' -Default '')
            $state = Get-SafeRegValue -Path $p -Name 'EnrollmentState' -Default $null

            $isBuiltInLocal = ($builtInAuthorities -contains $prov.Trim()) -and
                [string]::IsNullOrWhiteSpace($disc) -and
                [string]::IsNullOrWhiteSpace($upn) -and
                [string]::IsNullOrWhiteSpace($aad)

            if ($isBuiltInLocal) { continue }

            if (-not [string]::IsNullOrWhiteSpace($prov) -or -not [string]::IsNullOrWhiteSpace($disc) -or -not [string]::IsNullOrWhiteSpace($aad) -or -not [string]::IsNullOrWhiteSpace($upn)) {
                $mdmEntries += [PSCustomObject]@{
                    EnrollmentId = $sk.PSChildName
                    ProviderID   = $prov
                    DiscoveryUrl = $disc
                    UPN          = $upn
                    AADTenantID  = $aad
                    State        = $state
                }
            }
        }
    }
    $cimMdm = if ($IsAdmin) { Invoke-SafeCim -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernManagement_Enrollment01' } else { @() }
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
# --- END 10-corporate-lock.ps1 ---

# --- BEGIN 20-system-cpu.ps1 ---
function Get-SystemIdentity {
    $cs   = Invoke-SafeCim -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    $csp  = Invoke-SafeCim -ClassName 'Win32_ComputerSystemProduct' | Select-Object -First 1
    $bios = Invoke-SafeCim -ClassName 'Win32_BIOS' | Select-Object -First 1
    $bb   = Invoke-SafeCim -ClassName 'Win32_BaseBoard' | Select-Object -First 1
    $enc  = Invoke-SafeCim -ClassName 'Win32_SystemEnclosure' | Select-Object -First 1
    $os   = Invoke-SafeCim -ClassName 'Win32_OperatingSystem' | Select-Object -First 1

    $chassisTypes = @()
    if ($enc -and $enc.ChassisTypes) { $chassisTypes = @($enc.ChassisTypes | ForEach-Object { [int]$_ }) }
    $laptopCodes = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $isLaptop = $false
    foreach ($c in $chassisTypes) {
        if ($laptopCodes -contains $c) { $isLaptop = $true; break }
    }
    if (-not $isLaptop -and $cs -and $cs.PCSystemType -eq 2) { $isLaptop = $true }

    $chassisLabel = if ($isLaptop) { 'Laptop / Portable' } elseif ($chassisTypes.Count -gt 0) { "Chassis ($($chassisTypes -join ','))" } else { 'Unknown' }

    $biosDate = ''
    if ($bios -and $bios.ReleaseDate) {
        try { $biosDate = ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } catch { $biosDate = [string]$bios.ReleaseDate }
    }
    $osInstall = ''
    $uptimeHours = $null
    if ($os) {
        if ($os.InstallDate) {
            try { $osInstall = ([datetime]$os.InstallDate).ToString('yyyy-MM-dd') } catch { $osInstall = [string]$os.InstallDate }
        }
        if ($os.LastBootUpTime) {
            try { $uptimeHours = [Math]::Round(((Get-Date) - ([datetime]$os.LastBootUpTime)).TotalHours, 1) } catch {}
        }
    }

    return [PSCustomObject]@{
        Manufacturer    = if ($cs) { [string]$cs.Manufacturer } else { 'Unknown' }
        Model           = if ($cs) { [string]$cs.Model } else { 'Unknown' }
        SystemSku       = if ($cs) { [string]$cs.SystemSKUNumber } else { '' }
        ProductVersion  = if ($csp) { [string]$csp.Version } else { '' }
        Uuid            = if ($csp) { [string]$csp.UUID } else { '' }
        SerialNumber    = if ($bios -and -not [string]::IsNullOrWhiteSpace($bios.SerialNumber)) { [string]$bios.SerialNumber } elseif ($csp) { [string]$csp.IdentifyingNumber } else { 'Unknown' }
        BiosVendor      = if ($bios) { [string]$bios.Manufacturer } else { '' }
        BiosVersion     = if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' }
        BiosDate        = $biosDate
        BaseBoard       = if ($bb) { ("{0} {1}" -f $bb.Manufacturer, $bb.Product).Trim() } else { '' }
        ChassisType     = $chassisLabel
        IsLaptop        = $isLaptop
        OsCaption       = if ($os) { [string]$os.Caption } else { 'Windows' }
        OsVersion       = if ($os) { [string]$os.Version } else { '' }
        OsBuild         = if ($os) { [string]$os.BuildNumber } else { '' }
        OsArchitecture  = if ($os) { [string]$os.OSArchitecture } else { '' }
        OsInstallDate   = $osInstall
        UptimeHours     = $uptimeHours
        ComputerName    = $env:COMPUTERNAME
    }
}

function Get-CpuTempCelsius {
    try {
        $zones = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature'
        $valid = @()
        foreach ($z in $zones) {
            if ($z.CurrentTemperature) {
                $c = ($z.CurrentTemperature / 10.0) - 273.15
                if ($c -ge 20.0 -and $c -le 120.0) { $valid += $c }
            }
        }
        if ($valid.Count -gt 0) {
            return [Math]::Round(($valid | Measure-Object -Maximum).Maximum, 1)
        }
    } catch {}

    try {
        $perfZones = Invoke-SafeCim -ClassName 'Win32_PerfFormattedData_Counters_ThermalZoneInformation'
        $valid2 = @()
        foreach ($pz in $perfZones) {
            if ($pz.Temperature -and $pz.Temperature -gt 200) {
                $c = $pz.Temperature - 273.15
                if ($c -ge 20.0 -and $c -le 120.0) { $valid2 += $c }
            }
        }
        if ($valid2.Count -gt 0) {
            return [Math]::Round(($valid2 | Measure-Object -Maximum).Maximum, 1)
        }
    } catch {}

    return $null
}

function Get-NvidiaTempQuick {
    param([string]$NvidiaSmiPath)
    if ([string]::IsNullOrWhiteSpace($NvidiaSmiPath) -or -not (Test-Path -LiteralPath $NvidiaSmiPath)) {
        return $null
    }
    try {
        $out = & $NvidiaSmiPath --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>$null
        if ($out -and $out[0] -match '^\s*(\d+(\.\d+)?)') {
            return [double]$matches[1]
        }
    } catch {}
    return $null
}

function Get-BatteryLiveSample {
    $online = $null
    $voltMv = $null
    try {
        $bs = Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStatus' | Select-Object -First 1
        if ($bs) {
            $online = [bool]$bs.PowerOnline
            if ($bs.Voltage -gt 0) { $voltMv = [int]$bs.Voltage }
        }
    } catch {}
    if ($null -eq $online) {
        $wb = Invoke-SafeCim -ClassName 'Win32_Battery' | Select-Object -First 1
        if ($wb) {
            $online = ($wb.BatteryStatus -eq 2 -or $wb.BatteryStatus -eq 6 -or $wb.BatteryStatus -eq 7 -or $wb.BatteryStatus -eq 8 -or $wb.BatteryStatus -eq 9)
            if ($wb.DesignVoltage -gt 0) { $voltMv = [int]$wb.DesignVoltage }
        }
    }
    return [PSCustomObject]@{
        PowerOnline = $online
        VoltageMv   = $voltMv
    }
}

function Get-CpuAndThermalTest {
    param(
        [int]$StressSeconds = 10,
        [string]$NvidiaSmiPath = ''
    )

    $procs = @(Invoke-SafeCim -ClassName 'Win32_Processor')
    $p0 = $procs | Select-Object -First 1
    $totalCores = 0
    $totalLogical = 0
    foreach ($p in $procs) {
        $totalCores += [int]$p.NumberOfCores
        $totalLogical += [int]$p.NumberOfLogicalProcessors
    }
    if ($totalLogical -le 0) { $totalLogical = [Environment]::ProcessorCount }

    $idleTemp = Get-CpuTempCelsius
    $loadSamples = @()

    $verificationPassed = $true
    $intOpsPerSec = 0
    $fpOpsPerSec = 0
    $peakTemp = $idleTemp
    $peakGpuTemp = Get-NvidiaTempQuick -NvidiaSmiPath $NvidiaSmiPath
    $avgClockPct = $null
    $thermalStatus = if ($null -eq $idleTemp) { 'UNAVAILABLE' } else { 'PASS' }
    $throttlingSuspected = $false
    $stressSkipped = ($StressSeconds -le 0)

    if (-not $stressSkipped) {
        # Precompute exact verification digests on main thread
        $seedBytes = [System.Text.Encoding]::ASCII.GetBytes('LaptopInspect-Verify-Seed-2026')
        $shaInit = [System.Security.Cryptography.SHA256]::Create()
        $buf = $seedBytes
        for ($r = 0; $r -lt 200; $r++) { $buf = $shaInit.ComputeHash($buf) }
        $expectedHash = [BitConverter]::ToString($buf)
        $shaInit.Dispose()

        $expectedFp = 0.0
        for ($k = 1; $k -le 1500; $k++) {
            $expectedFp += [Math]::Sqrt($k * 1.37) * [Math]::Sin($k * 0.017) + [Math]::Cos($k * 0.013)
        }

        $workerScript = {
            param($DurationSec, $ExpHash, $ExpFp)
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $seed = [System.Text.Encoding]::ASCII.GetBytes('LaptopInspect-Verify-Seed-2026')
            $intBlocks = 0L
            $fpBlocks = 0L
            $ok = $true
            try {
                while ($sw.Elapsed.TotalSeconds -lt $DurationSec) {
                    $b = $seed
                    for ($r = 0; $r -lt 200; $r++) { $b = $sha.ComputeHash($b) }
                    if ([BitConverter]::ToString($b) -ne $ExpHash) { $ok = $false; break }
                    $intBlocks++

                    $fp = 0.0
                    for ($k = 1; $k -le 1500; $k++) {
                        $fp += [Math]::Sqrt($k * 1.37) * [Math]::Sin($k * 0.017) + [Math]::Cos($k * 0.013)
                    }
                    if ([Math]::Abs($fp - $ExpFp) -gt 1e-6) { $ok = $false; break }
                    $fpBlocks++
                }
            } finally {
                $sha.Dispose()
                $sw.Stop()
            }
            return [PSCustomObject]@{
                Ok        = $ok
                IntOps    = ($intBlocks * 200)
                FpOps     = ($fpBlocks * 1500)
                ElapsedMs = $sw.Elapsed.TotalMilliseconds
            }
        }

        $pool = [RunspaceFactory]::CreateRunspacePool(1, $totalLogical)
        $pool.Open()
        $handles = @()
        try {
            for ($w = 0; $w -lt $totalLogical; $w++) {
                $ps = [PowerShell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($workerScript).AddArgument($StressSeconds).AddArgument($expectedHash).AddArgument($expectedFp)
                $async = $ps.BeginInvoke()
                $handles += [PSCustomObject]@{ Ps = $ps; Async = $async }
            }

            $clockSamples = @()
            $monitorSw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($monitorSw.Elapsed.TotalSeconds -lt ($StressSeconds + 0.3)) {
                $allDone = $true
                foreach ($h in $handles) {
                    if (-not $h.Async.IsCompleted) { $allDone = $false; break }
                }
                if ($allDone) { break }

                $tNow = Get-CpuTempCelsius
                if ($null -ne $tNow) {
                    if ($null -eq $peakTemp -or $tNow -gt $peakTemp) { $peakTemp = $tNow }
                }
                $gNow = Get-NvidiaTempQuick -NvidiaSmiPath $NvidiaSmiPath
                if ($null -ne $gNow) {
                    if ($null -eq $peakGpuTemp -or $gNow -gt $peakGpuTemp) { $peakGpuTemp = $gNow }
                }
                try {
                    $cPerf = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue
                    if ($cPerf -gt 0) { $clockSamples += [Math]::Round($cPerf, 1) }
                } catch {}

                $batNow = Get-BatteryLiveSample
                $loadSamples += [PSCustomObject]@{
                    Second      = [Math]::Round($monitorSw.Elapsed.TotalSeconds, 1)
                    TempC       = $tNow
                    GpuTempC    = $gNow
                    PowerOnline = $batNow.PowerOnline
                    VoltageMv   = $batNow.VoltageMv
                }

                Start-Sleep -Milliseconds 1000
            }
            $monitorSw.Stop()

            $totalInt = 0L
            $totalFp = 0L
            foreach ($h in $handles) {
                try {
                    $res = $h.Ps.EndInvoke($h.Async)
                    foreach ($r in $res) {
                        if (-not $r.Ok) { $verificationPassed = $false }
                        $totalInt += [long]$r.IntOps
                        $totalFp  += [long]$r.FpOps
                    }
                } catch {
                    # Ignore worker collection issue
                } finally {
                    $h.Ps.Dispose()
                }
            }

            $intOpsPerSec = [int][Math]::Round($totalInt / [double]$StressSeconds)
            $fpOpsPerSec  = [int][Math]::Round($totalFp / [double]$StressSeconds)
            if ($clockSamples.Count -gt 0) {
                $avgClockPct = [Math]::Round(($clockSamples | Measure-Object -Average).Average, 1)
            }
            if ($null -ne $peakTemp -and $peakTemp -ge 92.0) {
                $throttlingSuspected = $true
                $thermalStatus = 'WARN'
            } elseif ($null -ne $peakTemp) {
                $thermalStatus = 'PASS'
            } else {
                $thermalStatus = 'UNAVAILABLE'
            }
        } finally {
            $pool.Close()
            $pool.Dispose()
        }
    }

    return [PSCustomObject]@{
        CpuName              = if ($p0) { ([string]$p0.Name).Trim() } else { 'Unknown CPU' }
        Manufacturer         = if ($p0) { [string]$p0.Manufacturer } else { '' }
        Socket               = if ($p0) { [string]$p0.SocketDesignation } else { '' }
        PhysicalCores        = $totalCores
        LogicalProcessors    = $totalLogical
        MaxClockMHz          = if ($p0) { [int]$p0.MaxClockSpeed } else { 0 }
        L2CacheKB            = if ($p0) { [int]$p0.L2CacheSize } else { 0 }
        L3CacheKB            = if ($p0) { [int]$p0.L3CacheSize } else { 0 }
        VirtualizationReady  = if ($p0) { [bool]$p0.VirtualizationFirmwareEnabled } else { $false }
        StressSkipped        = $stressSkipped
        StressSeconds        = $StressSeconds
        VerificationPassed   = $verificationPassed
        IntOpsPerSec         = $intOpsPerSec
        FpOpsPerSec          = $fpOpsPerSec
        IdleTempC            = $idleTemp
        PeakTempC            = $peakTemp
        PeakGpuTempC         = $peakGpuTemp
        AvgClockPerfPct      = $avgClockPct
        ThermalStatus        = $thermalStatus
        ThrottlingSuspected  = $throttlingSuspected
        LoadSamples          = @($loadSamples)
    }
}
# --- END 20-system-cpu.ps1 ---

# --- BEGIN 30-gpu.ps1 ---
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
# --- END 30-gpu.ps1 ---

# --- BEGIN 40-ram-storage.ps1 ---
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
# --- END 40-ram-storage.ps1 ---

# --- BEGIN 50-battery-power.ps1 ---
function Get-BatteryDiagnostics {
    param(
        [array]$LoadSamples = @(),
        [bool]$IsLaptop = $true
    )

    $batteries = @()
    $xmlPath = Join-Path $env:TEMP ("li_bat_{0}.xml" -f $PID)

    try {
        $pInfo = New-Object System.Diagnostics.ProcessStartInfo
        $pInfo.FileName = Join-Path $env:SystemRoot 'System32\powercfg.exe'
        $pInfo.Arguments = "/batteryreport /xml /output `"$xmlPath`""
        $pInfo.RedirectStandardOutput = $true
        $pInfo.RedirectStandardError = $true
        $pInfo.UseShellExecute = $false
        $pInfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pInfo)
        $proc.WaitForExit(5000) | Out-Null

        if (Test-Path -LiteralPath $xmlPath) {
            [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
            $xmlBats = @($xml.BatteryReport.Batteries.Battery)
            foreach ($xb in $xmlBats) {
                if ($null -eq $xb) { continue }
                $design = if ($xb.DesignCapacity -match '^\d+$') { [int64]$xb.DesignCapacity } else { 0L }
                $full   = if ($xb.FullChargeCapacity -match '^\d+$') { [int64]$xb.FullChargeCapacity } else { 0L }
                $cycles = if ($xb.CycleCount -match '^\d+$') { [int]$xb.CycleCount } else { $null }

                $healthPct = if ($design -gt 0 -and $full -gt 0) {
                    [Math]::Round([Math]::Min(100.0, ($full / [double]$design) * 100.0), 1)
                } else { $null }
                $wearPct = if ($null -ne $healthPct) { [Math]::Round(100.0 - $healthPct, 1) } else { $null }

                $batteries += [PSCustomObject]@{
                    Id                 = [string]$xb.Id
                    Manufacturer       = [string]$xb.Manufacturer
                    SerialNumber       = [string]$xb.SerialNumber
                    Chemistry          = [string]$xb.Chemistry
                    DesignCapacityMWh  = $design
                    FullChargeMWh      = $full
                    CycleCount         = $cycles
                    HealthPercent      = $healthPct
                    WearPercent        = $wearPct
                }
            }
        }
    } catch {
        # Fallback to WMI below
    } finally {
        if (Test-Path -LiteralPath $xmlPath) {
            Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
        }
    }

    # WMI fallback or enrichment for CycleCount / StaticData / Live Status
    $wmiStatic = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStaticData')
    $wmiFull   = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity')
    $wmiCycles = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryCycleCount')
    $wmiStatus = @(Invoke-SafeCim -Namespace 'root\wmi' -ClassName 'BatteryStatus')
    $win32Bat  = @(Invoke-SafeCim -ClassName 'Win32_Battery')

    if ($batteries.Count -eq 0 -and ($wmiStatic.Count -gt 0 -or $win32Bat.Count -gt 0)) {
        $count = [Math]::Max($wmiStatic.Count, $win32Bat.Count)
        for ($i = 0; $i -lt $count; $i++) {
            $st = if ($i -lt $wmiStatic.Count) { $wmiStatic[$i] } else { $null }
            $fc = if ($i -lt $wmiFull.Count) { $wmiFull[$i] } else { $null }
            $cc = if ($i -lt $wmiCycles.Count) { $wmiCycles[$i] } else { $null }
            $wb = if ($i -lt $win32Bat.Count) { $win32Bat[$i] } else { $null }

            $design = if ($st -and $st.DesignedCapacity -gt 0) { [int64]$st.DesignedCapacity } elseif ($wb -and $wb.DesignCapacity -gt 0) { [int64]$wb.DesignCapacity } else { 0L }
            $full   = if ($fc -and $fc.FullChargedCapacity -gt 0) { [int64]$fc.FullChargedCapacity } elseif ($wb -and $wb.FullChargeCapacity -gt 0) { [int64]$wb.FullChargeCapacity } else { 0L }
            $cycles = if ($cc -and $null -ne $cc.CycleCount) { [int]$cc.CycleCount } else { $null }

            $healthPct = if ($design -gt 0 -and $full -gt 0) {
                [Math]::Round([Math]::Min(100.0, ($full / [double]$design) * 100.0), 1)
            } else { $null }
            $wearPct = if ($null -ne $healthPct) { [Math]::Round(100.0 - $healthPct, 1) } else { $null }

            $batteries += [PSCustomObject]@{
                Id                 = if ($wb) { [string]$wb.DeviceID } else { "BAT$i" }
                Manufacturer       = if ($st) { [string]$st.ManufactureName } else { '' }
                SerialNumber       = if ($st) { [string]$st.SerialNumber } else { '' }
                Chemistry          = if ($st) { [string]$st.Chemistry } else { '' }
                DesignCapacityMWh  = $design
                FullChargeMWh      = $full
                CycleCount         = $cycles
                HealthPercent      = $healthPct
                WearPercent        = $wearPct
            }
        }
    } elseif ($batteries.Count -gt 0 -and $wmiCycles.Count -gt 0) {
        for ($i = 0; $i -lt $batteries.Count; $i++) {
            if (($null -eq $batteries[$i].CycleCount -or $batteries[$i].CycleCount -eq 0) -and $i -lt $wmiCycles.Count -and $wmiCycles[$i].CycleCount -gt 0) {
                $batteries[$i].CycleCount = [int]$wmiCycles[$i].CycleCount
            }
        }
    }

    # Live state
    $wb0 = $win32Bat | Select-Object -First 1
    $ws0 = $wmiStatus | Select-Object -First 1

    $chargePct = if ($wb0) { [int]$wb0.EstimatedChargeRemaining } else { $null }
    $acOnline = if ($ws0) { [bool]$ws0.PowerOnline } elseif ($wb0) { ($wb0.BatteryStatus -in @(2, 6, 7, 8, 9)) } else { $null }
    $charging = if ($ws0) { [bool]$ws0.Charging } else { $false }
    $discharging = if ($ws0) { [bool]$ws0.Discharging } else { $false }
    $voltageMv = if ($ws0 -and $ws0.Voltage -gt 0) { [int]$ws0.Voltage } elseif ($wb0 -and $wb0.DesignVoltage -gt 0) { [int]$wb0.DesignVoltage } else { $null }
    $chargeRateMw = if ($ws0 -and $ws0.Charging) { [int]$ws0.ChargeRate } elseif ($ws0 -and $ws0.Discharging) { -[int]$ws0.DischargeRate } else { 0 }

    # Analyze load stability from CPU stress samples
    $acFlickerDetected = $false
    $voltageDroopDetected = $false
    $voltageDroopPct = 0.0
    if ($LoadSamples -and $LoadSamples.Count -ge 2) {
        $onlineVals = @($LoadSamples | Where-Object { $null -ne $_.PowerOnline } | Select-Object -ExpandProperty PowerOnline)
        if ($onlineVals.Count -ge 2) {
            $firstOn = $onlineVals[0]
            foreach ($ov in $onlineVals) {
                if ($ov -ne $firstOn) { $acFlickerDetected = $true; break }
            }
        }
        $volts = @($LoadSamples | Where-Object { $null -ne $_.VoltageMv -and $_.VoltageMv -gt 0 } | Select-Object -ExpandProperty VoltageMv)
        if ($volts.Count -ge 2) {
            $maxV = ($volts | Measure-Object -Maximum).Maximum
            $minV = ($volts | Measure-Object -Minimum).Minimum
            if ($maxV -gt 0) {
                $voltageDroopPct = [Math]::Round((($maxV - $minV) / [double]$maxV) * 100.0, 1)
                if ($voltageDroopPct -gt 12.0) { $voltageDroopDetected = $true }
            }
        }
    }

    # Combined health
    $validHealths = @($batteries | Where-Object { $null -ne $_.HealthPercent } | Select-Object -ExpandProperty HealthPercent)
    $overallHealth = if ($validHealths.Count -gt 0) {
        [Math]::Round(($validHealths | Measure-Object -Average).Average, 1)
    } else { $null }
    $maxCycles = $null
    $cycleVals = @($batteries | Where-Object { $null -ne $_.CycleCount } | Select-Object -ExpandProperty CycleCount)
    if ($cycleVals.Count -gt 0) { $maxCycles = ($cycleVals | Measure-Object -Maximum).Maximum }

    $condition = if ($batteries.Count -eq 0) {
        if ($IsLaptop) { 'Missing' } else { 'N/A (Desktop)' }
    } elseif ($null -eq $overallHealth) {
        'Unknown'
    } elseif ($overallHealth -ge 85) {
        'Excellent'
    } elseif ($overallHealth -ge 75) {
        'Good'
    } elseif ($overallHealth -ge 60) {
        'Fair'
    } else {
        'Poor'
    }

    $batStatus = if ($batteries.Count -eq 0) {
        if ($IsLaptop) { 'FAIL' } else { 'UNAVAILABLE' }
    } elseif ($acFlickerDetected -or $voltageDroopDetected -or ($null -ne $overallHealth -and $overallHealth -lt 75)) {
        'WARN'
    } elseif ($null -eq $overallHealth) {
        'UNAVAILABLE'
    } else {
        'PASS'
    }

    return [PSCustomObject]@{
        Status               = $batStatus
        BatteryCount         = $batteries.Count
        Condition            = $condition
        OverallHealthPercent = $overallHealth
        MaxCycleCount        = $maxCycles
        CurrentChargePercent = $chargePct
        AcOnline             = $acOnline
        Charging             = $charging
        Discharging          = $discharging
        VoltageMv            = $voltageMv
        ChargeRateMw         = $chargeRateMw
        AcFlickerDetected    = $acFlickerDetected
        VoltageDroopDetected = $voltageDroopDetected
        VoltageDroopPct      = $voltageDroopPct
        Batteries            = @($batteries)
    }
}
# --- END 50-battery-power.ps1 ---

# --- BEGIN 60-peripherals.ps1 ---
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
# --- END 60-peripherals.ps1 ---

# --- BEGIN 70-scoring.ps1 ---
function Get-BuyerVerdict {
    param(
        [Parameter(Mandatory = $true)]$ReportData
    )

    $score = 100
    $deductions = @()
    $criticalFlags = @()
    $warnings = @()
    $advisories = @()

    $corp = $ReportData.CorporateLock
    $cpu  = $ReportData.Cpu
    $gpu  = $ReportData.Gpu
    $ram  = $ReportData.Ram
    $stor = $ReportData.Storage
    $bat  = $ReportData.Battery
    $per  = $ReportData.Peripherals
    $sys  = $ReportData.System

    # 1. Corporate Lock Rules
    if ($corp) {
        if ($corp.Autopilot -and $corp.Autopilot.Assigned) {
            $td = if ($corp.Autopilot.TenantDomain) { " ($($corp.Autopilot.TenantDomain))" } else { '' }
            $criticalFlags += "Windows Autopilot tenant assigned$td"
        }
        if ($corp.Dsreg -and ($corp.Dsreg.AzureAdJoined -or $corp.Dsreg.EnterpriseJoined -or $corp.Dsreg.DomainJoined)) {
            $tn = if ($corp.Dsreg.TenantName) { " ($($corp.Dsreg.TenantName))" } else { '' }
            $criticalFlags += "Corporate Entra ID / Active Directory joined$tn"
        }
        if ($corp.Mdm -and $corp.Mdm.Detected) {
            $criticalFlags += "Active Intune / MDM management enrollment detected"
        }
        if ($corp.Computrace -and ($corp.Computrace.OsEvidence.Count -gt 0 -or $corp.Computrace.BiosActive)) {
            $criticalFlags += "Absolute Persistence / Computrace active"
        }
        if ($corp.BiosSecurity -and $corp.BiosSecurity.PasswordSet) {
            $criticalFlags += "BIOS / UEFI Administrator or Supervisor password is SET"
        }
        if ($corp.RmmEdr -and $corp.RmmEdr.Detected) {
            $criticalFlags += ("Corporate RMM / EDR agent detected: {0}" -f ($corp.RmmEdr.Findings -join '; '))
        }

        if ($corp.ConfirmedCorporateLock) {
            $score -= 45
            $deductions += '-45: Confirmed Corporate Lock / Enterprise Ownership'
        }

        if ($corp.Dsreg -and $corp.Dsreg.WorkplaceJoined) {
            $score -= 10
            $warnings += 'Workplace / BYOD account linked (WorkplaceJoined=YES)'
            $deductions += '-10: WorkplaceJoined account present'
        }
        if ($corp.BitLocker -and $corp.BitLocker.Active) {
            $score -= 15
            $warnings += 'BitLocker drive encryption is ON (ensure recovery key or clean wipe before purchase)'
            $deductions += '-15: BitLocker Protection On'
        }
        if (-not $corp.IsAdminSession) {
            $advisories += 'Run was executed without Administrator privileges; some BIOS WMI, BitLocker, and SMART telemetry may be limited.'
        }
        if ($corp.BiosSecurity -and -not $corp.BiosSecurity.WmiChecked) {
            $advisories += 'Vendor BIOS WMI unavailable; verify BIOS/UEFI Setup manually at boot for Supervisor Password and Computrace.'
        }
        if ($corp.Autopilot -and -not $corp.Autopilot.Assigned) {
            $advisories += $corp.Autopilot.Advisory
        }
        if ($corp.Activation -and $corp.Activation.LicenseStatus -ne 'Licensed') {
            $score -= 10
            $warnings += ("Windows is not activated ({0})" -f $corp.Activation.LicenseStatus)
            $deductions += '-10: Windows unlicensed'
        } elseif ($corp.Activation -and $corp.Activation.Channel -eq 'VOLUME_KMSCLIENT') {
            $score -= 10
            $warnings += 'Windows uses Corporate Volume KMS licensing (will expire without corporate server)'
            $deductions += '-10: Volume KMS license'
        }
    }

    # 2. CPU Verification & Thermals
    if ($cpu) {
        if (-not $cpu.StressSkipped -and -not $cpu.VerificationPassed) {
            $score -= 40
            $criticalFlags += 'CPU verified calculation checksum FAILED under multi-core load'
            $deductions += '-40: CPU calculation failure'
        }
        if ($cpu.ThrottlingSuspected) {
            $score -= 15
            $warnings += ("High CPU load temperature ({0} C) / potential thermal throttling" -f $cpu.PeakTempC)
            $deductions += '-15: High CPU load temperature'
        } elseif ($cpu.ThermalStatus -eq 'UNAVAILABLE') {
            $advisories += 'ACPI CPU temperature sensor is not exposed on this board (UNAVAILABLE != PASS).'
        }
    }

    # 3. GPU Rules
    if ($gpu -and $gpu.HasError) {
        $errGpus = @($gpu.Gpus | Where-Object { $_.ErrorCode -ne 0 } | ForEach-Object { "$($_.Name) (Code $($_.ErrorCode))" })
        $score -= 40
        $criticalFlags += ("GPU hardware/driver error detected: {0}" -f ($errGpus -join ', '))
        $deductions += '-40: GPU error code'
    }

    # 4. RAM Rules
    if ($ram -and $ram.PatternTest -and $ram.PatternTest.Status -eq 'FAIL') {
        $score -= 40
        $criticalFlags += 'RAM 128 MB allocation pattern verification FAILED'
        $deductions += '-40: RAM pattern failure'
    }

    # 5. Storage Rules
    if ($stor) {
        if ($stor.InternalUnhealthy -or $stor.InternalErrors) {
            $score -= 35
            $criticalFlags += 'Internal storage SMART status Unhealthy or uncorrected read/write errors reported'
            $deductions += '-35: Unhealthy internal storage'
        } elseif ($stor.HighWearDetected) {
            $score -= 15
            $warnings += 'Internal SSD wear is >= 70%'
            $deductions += '-15: High SSD wear (>=70%)'
        }
    }

    # 6. Battery & Power Rules
    if ($bat) {
        $isLap = if ($sys) { [bool]$sys.IsLaptop } else { $true }
        if ($bat.BatteryCount -eq 0 -and $isLap) {
            $score -= 30
            $criticalFlags += 'Laptop chassis detected with 0 batteries installed or detected'
            $deductions += '-30: Missing laptop battery'
        } elseif ($bat.BatteryCount -gt 0) {
            $hp = $bat.OverallHealthPercent
            if ($null -ne $hp) {
                if ($hp -lt 50) {
                    $score -= 25
                    $warnings += ("Severe battery wear ({0}% health remaining)" -f $hp)
                    $deductions += '-25: Battery < 50% health'
                } elseif ($hp -lt 75) {
                    $score -= 15
                    $warnings += ("Moderate battery wear ({0}% health remaining)" -f $hp)
                    $deductions += '-15: Battery 50-74% health'
                } elseif ($hp -lt 85) {
                    $score -= 5
                    $deductions += '-5: Battery 75-84% health'
                }
            } else {
                $advisories += 'Battery capacity telemetry unavailable from ACPI/powercfg.'
            }
            if ($null -ne $bat.MaxCycleCount -and $bat.MaxCycleCount -gt 500) {
                $score -= 5
                $warnings += ("High battery cycle count ({0} cycles)" -f $bat.MaxCycleCount)
                $deductions += '-5: Battery > 500 cycles'
            }
            if ($bat.AcFlickerDetected -or $bat.VoltageDroopDetected) {
                $score -= 15
                $warnings += 'AC adapter power flicker or >12% voltage droop observed during stress load'
                $deductions += '-15: AC/power instability under load'
            }
        }
    }

    # 7. Device Manager Errors
    if ($per -and $per.DeviceErrors) {
        $actErrs = @($per.DeviceErrors | Where-Object { -not $_.IsDisabled })
        if ($actErrs.Count -gt 0) {
            $pen = [Math]::Min(15, $actErrs.Count * 5)
            $score -= $pen
            $names = ($actErrs | Select-Object -First 4 | ForEach-Object { "$($_.Name) [Code $($_.ErrorCode)]" }) -join ', '
            $warnings += ("Device Manager hardware/driver errors ({0}): {1}" -f $actErrs.Count, $names)
            $deductions += ("-{0}: Device Manager errors ({1})" -f $pen, $actErrs.Count)
        }
    }

    if ($score -lt 0) { $score = 0 }
    if ($score -gt 100) { $score = 100 }

    $verdict = if ($criticalFlags.Count -gt 0) {
        'DO NOT BUY'
    } elseif ($warnings.Count -gt 0 -or $score -lt 80) {
        'CAUTION'
    } else {
        'BUY'
    }

    $upgradeNotes = @()
    if ($ram) {
        if ($ram.FreeSlots -gt 0) {
            $upgradeNotes += ("{0} free RAM slot(s) available ({1} of {2} used)" -f $ram.FreeSlots, $ram.UsedSlots, $ram.TotalSlots)
        } elseif ($ram.SolderedDetected) {
            $upgradeNotes += 'RAM appears soldered / non-upgradeable (0 free slots, LPDDR/chip form factor)'
        } else {
            $upgradeNotes += ("All {0} RAM slots occupied (can upgrade by replacing existing DIMMs)" -f $ram.TotalSlots)
        }
    }
    if ($stor -and $stor.Disks) {
        $intDisks = @($stor.Disks | Where-Object { -not $_.IsExternal })
        foreach ($idisk in $intDisks) {
            $upgradeNotes += ("Internal drive: {0} ({1} GB, {2})" -f $idisk.FriendlyName, $idisk.SizeGB, $idisk.BusType)
        }
    }

    return [PSCustomObject]@{
        Verdict       = $verdict
        Score         = $score
        Deductions    = @($deductions)
        CriticalFlags = @($criticalFlags)
        Warnings      = @($warnings)
        Advisories    = @($advisories)
        UpgradeNotes  = @($upgradeNotes)
    }
}
# --- END 70-scoring.ps1 ---

# --- BEGIN 80-report.ps1 ---
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
# --- END 80-report.ps1 ---

