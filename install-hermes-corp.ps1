<# 
One-click wrapper for the isolated enterprise Windows Hermes installer.

Run from this folder:
  powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1

The install root defaults to the current PowerShell directory. Run `cd` into
the target folder first, or pass -Root explicitly.

All arguments are forwarded to scripts\install-hermes-corp-windows.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardedArgs
)

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "scripts\install-hermes-corp-windows.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Installer not found: $scriptPath"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @ForwardedArgs
exit $LASTEXITCODE
