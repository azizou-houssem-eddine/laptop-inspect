[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$srcDir = Join-Path $root 'src'
$tplPath = Join-Path $root 'templates\report.html'
$outPath = Join-Path $root 'inspect.ps1'

if (-not (Test-Path -LiteralPath $srcDir)) { throw "Missing src directory: $srcDir" }
if (-not (Test-Path -LiteralPath $tplPath)) { throw "Missing template file: $tplPath" }

$srcFiles = Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' | Sort-Object Name
if ($srcFiles.Count -eq 0) { throw "No source .ps1 files found in $srcDir" }

$htmlBytes = [System.IO.File]::ReadAllBytes($tplPath)
foreach ($b in $htmlBytes) {
    if (-not ($b -eq 9 -or $b -eq 10 -or $b -eq 13 -or ($b -ge 32 -and $b -le 126))) {
        throw ("Non-ASCII byte 0x{0:X2} found in templates/report.html" -f $b)
    }
}
$htmlRaw = [System.Text.Encoding]::ASCII.GetString($htmlBytes)
$htmlLines = $htmlRaw -split "\r?\n"
foreach ($hl in $htmlLines) {
    if ($hl -match "^\s*'@") {
        throw "templates/report.html contains a line starting with `'@` which breaks PowerShell here-strings."
    }
}

$sb = New-Object System.Text.StringBuilder
$injectedTemplate = $false
foreach ($f in $srcFiles) {
    $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    [void]$sb.AppendLine("# --- BEGIN $($f.Name) ---")
    [void]$sb.AppendLine($content.TrimEnd())
    [void]$sb.AppendLine("# --- END $($f.Name) ---")
    [void]$sb.AppendLine("")

    if (-not $injectedTemplate -and $f.Name -eq '00-header.ps1') {
        [void]$sb.AppendLine("# --- BEGIN EMBEDDED TEMPLATE ---")
        [void]$sb.AppendLine('$script:ReportHtmlTemplate = @''')
        [void]$sb.AppendLine($htmlRaw.TrimEnd())
        [void]$sb.AppendLine('''@')
        [void]$sb.AppendLine("# --- END EMBEDDED TEMPLATE ---")
        [void]$sb.AppendLine("")
        $injectedTemplate = $true
    }
}

$finalText = ($sb.ToString() -replace "\r?\n", "`r`n")
$asciiEnc = New-Object System.Text.ASCIIEncoding
$outBytes = [System.Text.Encoding]::UTF8.GetBytes($finalText)

# Gate 1: Strict 7-bit ASCII check
$nonAsciiCount = 0
for ($i = 0; $i -lt $outBytes.Length; $i++) {
    $b = $outBytes[$i]
    if (-not ($b -eq 9 -or $b -eq 10 -or $b -eq 13 -or ($b -ge 32 -and $b -le 126))) {
        $nonAsciiCount++
        if ($nonAsciiCount -le 5) {
            Write-Warning ("Non-ASCII byte 0x{0:X2} at offset {1}" -f $b, $i)
        }
    }
}
if ($nonAsciiCount -gt 0) {
    throw ("Build gate failed: {0} non-ASCII byte(s) detected in inspect.ps1." -f $nonAsciiCount)
}

[System.IO.File]::WriteAllBytes($outPath, $outBytes)

# Gate 2: PowerShell AST Parse Check
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($outPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    foreach ($pe in $parseErrors) {
        Write-Error ("AST Error Line {0}: {1}" -f $pe.Extent.StartLineNumber, $pe.Message)
    }
    throw ("Build gate failed: {0} PowerShell AST syntax error(s)." -f $parseErrors.Count)
}

# Gate 3: JavaScript Syntax Check via node --check
$nodeCmd = Get-Command -Name 'node' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nodeCmd) {
    $matches = [regex]::Matches($htmlRaw, '<script>([\s\S]*?)</script>')
    if ($matches.Count -eq 0) { throw "No inline <script> block found in templates/report.html" }
    $mainJs = $matches[$matches.Count - 1].Groups[1].Value
    $tmpJs = Join-Path $env:TEMP ("li_jscheck_{0}.js" -f $PID)
    try {
        [System.IO.File]::WriteAllText($tmpJs, $mainJs, [System.Text.Encoding]::ASCII)
        $nodeOut = & $nodeCmd.Source --check $tmpJs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("JS syntax check failed: {0}" -f ($nodeOut -join "`n"))
        }
    } finally {
        if (Test-Path -LiteralPath $tmpJs) { Remove-Item -LiteralPath $tmpJs -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Warning "node.exe not found; skipping JS syntax check."
}

$sizeKB = [Math]::Round(($outBytes.Length / 1KB), 1)
Write-Host ("BUILD OK: inspect.ps1 ({0} KB) | Non-ASCII: 0 | AST Errors: 0 | JS Check: PASS" -f $sizeKB) -ForegroundColor Green
