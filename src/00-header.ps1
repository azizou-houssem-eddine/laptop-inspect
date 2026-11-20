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
