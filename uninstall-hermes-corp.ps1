<#
One-click wrapper for the isolated enterprise Windows Hermes uninstaller.

Run from the install root:
  powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1

The uninstall root defaults to the current PowerShell directory. Run `cd` into
the installed Hermes root first, or pass -Root explicitly.

All arguments are forwarded to scripts\uninstall-hermes-corp-windows.ps1.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardedArgs
)

$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "scripts\uninstall-hermes-corp-windows.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Uninstaller not found: $scriptPath"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @ForwardedArgs
exit $LASTEXITCODE
