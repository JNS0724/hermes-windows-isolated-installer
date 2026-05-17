<#
.SYNOPSIS
Uninstall the isolated native Windows Hermes Agent layout.

.DESCRIPTION
This mirrors the upstream Hermes Windows uninstall intent for this repository's
isolated layout:
- remove generated launchers and code/runtime directories
- optionally remove local HERMES_HOME data
- best-effort cleanup of scheduled tasks and Startup shortcuts that point into
  this install root
- best-effort cleanup of User environment variables only when they point into
  this install root

It deliberately does not remove the repository root itself.

Run:
  cd <installed-hermes-root>
  powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1

Use -RemoveHome to remove local config, auth, sessions, skills and logs too.
#>

[CmdletBinding()]
param(
    [string]$Root = "",
    [switch]$RemoveHome,
    [switch]$RemoveSandbox,
    [switch]$StopProcesses,
    [switch]$CleanUserEnvironment,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:RootPath = $null

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Resolve-FullPath {
    param([string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $expanded))
}

function Assert-UnderRoot {
    param(
        [string]$Path,
        [string]$Purpose
    )

    $full = Resolve-FullPath $Path
    $root = Resolve-FullPath $script:RootPath
    $rootWithSlash = $root.TrimEnd('\') + '\'
    $fullLower = $full.ToLowerInvariant()
    $rootLower = $root.ToLowerInvariant()
    $rootSlashLower = $rootWithSlash.ToLowerInvariant()

    if (($fullLower -eq $rootLower) -or (-not $fullLower.StartsWith($rootSlashLower))) {
        throw "$Purpose must be a child of root '$root'. Got: $full"
    }
    return $full
}

function Initialize-Root {
    if ($Root.Trim()) {
        $script:RootPath = Resolve-FullPath $Root
    } else {
        $script:RootPath = Resolve-FullPath (Get-Location).ProviderPath
    }
}

function Test-PathInsideRoot {
    param([string]$Path)

    if (-not $Path) {
        return $false
    }

    try {
        $full = Resolve-FullPath $Path
    } catch {
        return $false
    }

    $root = Resolve-FullPath $script:RootPath
    $rootWithSlash = $root.TrimEnd('\') + '\'
    $fullLower = $full.ToLowerInvariant()
    return $fullLower.StartsWith($rootWithSlash.ToLowerInvariant())
}

function Stop-InstallProcesses {
    $root = Resolve-FullPath $script:RootPath
    $rootLower = $root.ToLowerInvariant()
    $currentPid = $PID

    Write-Info "Checking for Hermes processes under $root"
    $matches = @()
    try {
        $matches = Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $currentPid -and
                $_.CommandLine -and
                $_.CommandLine.ToLowerInvariant().Contains($rootLower)
            } |
            Select-Object ProcessId, Name, CommandLine
    } catch {
        Write-Warn "Could not inspect process command lines: $($_.Exception.Message)"
        return
    }

    if (-not $matches) {
        Write-Ok "No matching Hermes processes found"
        return
    }

    foreach ($proc in $matches) {
        if ($DryRun) {
            Write-Host "       dry-run: would stop $($proc.Name) PID $($proc.ProcessId)"
            continue
        }
        Write-Warn "Stopping $($proc.Name) PID $($proc.ProcessId)"
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Remove-GeneratedDirectory {
    param(
        [string]$RelativePath,
        [string]$Label
    )

    $path = Assert-UnderRoot (Join-Path $script:RootPath $RelativePath) $Label
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Ok "$Label not present: $path"
        return
    }

    if ($DryRun) {
        Write-Host "       dry-run: would remove $path"
        return
    }

    Write-Info "Removing ${Label}: $path"
    Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $_.Attributes = [System.IO.FileAttributes]::Normal
            } catch {
                # Best effort; Remove-Item below will report real failures.
            }
        }
    Remove-Item -LiteralPath $path -Recurse -Force
    Write-Ok "Removed $Label"
}

function Remove-MatchingScheduledTasks {
    Write-Info "Checking scheduled tasks"

    $tasks = @()
    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop
    } catch {
        Write-Warn "Scheduled task inspection skipped: $($_.Exception.Message)"
        return
    }

    $matches = @()
    foreach ($task in $tasks) {
        $actionsText = ($task.Actions | ForEach-Object {
            $executeProp = $_.PSObject.Properties["Execute"]
            $argumentsProp = $_.PSObject.Properties["Arguments"]
            $execute = ""
            $arguments = ""
            if ($executeProp) {
                $execute = [string]$executeProp.Value
            }
            if ($argumentsProp) {
                $arguments = [string]$argumentsProp.Value
            }
            "$execute $arguments"
        }) -join " "
        if ($actionsText -and $actionsText.ToLowerInvariant().Contains($script:RootPath.ToLowerInvariant())) {
            $matches += $task
        }
    }

    if (-not $matches) {
        Write-Ok "No scheduled tasks point into this install root"
        return
    }

    foreach ($task in $matches) {
        $taskName = $task.TaskName
        $taskPath = $task.TaskPath
        if ($DryRun) {
            Write-Host "       dry-run: would unregister scheduled task $taskPath$taskName"
            continue
        }
        Write-Warn "Unregistering scheduled task $taskPath$taskName"
        Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Remove-MatchingStartupShortcuts {
    Write-Info "Checking Startup folder shortcuts"

    $startup = [Environment]::GetFolderPath("Startup")
    if (-not $startup -or -not (Test-Path -LiteralPath $startup)) {
        Write-Ok "Startup folder not found"
        return
    }

    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
    } catch {
        Write-Warn "Startup shortcut inspection skipped: $($_.Exception.Message)"
        return
    }

    $matches = @()
    foreach ($link in Get-ChildItem -LiteralPath $startup -Filter "*.lnk" -File -ErrorAction SilentlyContinue) {
        try {
            $shortcut = $shell.CreateShortcut($link.FullName)
            $text = "$($shortcut.TargetPath) $($shortcut.Arguments)"
            if ($text.ToLowerInvariant().Contains($script:RootPath.ToLowerInvariant())) {
                $matches += $link
            }
        } catch {
            Write-Warn "Could not inspect shortcut $($link.FullName): $($_.Exception.Message)"
        }
    }

    if (-not $matches) {
        Write-Ok "No Startup shortcuts point into this install root"
        return
    }

    foreach ($link in $matches) {
        if ($DryRun) {
            Write-Host "       dry-run: would remove Startup shortcut $($link.FullName)"
            continue
        }
        Write-Warn "Removing Startup shortcut $($link.FullName)"
        Remove-Item -LiteralPath $link.FullName -Force
    }
}

function Remove-PathEntries {
    param(
        [string]$PathValue,
        [string[]]$RemoveEntries
    )

    if ($null -eq $PathValue) {
        return $null
    }

    $removeSet = @{}
    foreach ($entry in $RemoveEntries) {
        if ($entry) {
            $removeSet[(Resolve-FullPath $entry).TrimEnd('\').ToLowerInvariant()] = $true
        }
    }

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ($PathValue -split ';')) {
        if (-not $entry.Trim()) {
            continue
        }
        try {
            $normalized = (Resolve-FullPath $entry).TrimEnd('\').ToLowerInvariant()
        } catch {
            $normalized = $entry.TrimEnd('\').ToLowerInvariant()
        }
        if (-not $removeSet.ContainsKey($normalized)) {
            $kept.Add($entry)
        }
    }

    return ($kept -join ';')
}

function Clean-UserEnvironment {
    Write-Info "Checking User environment variables"

    $pathEntries = @(
        (Join-Path $script:RootPath "bin"),
        (Join-Path $script:RootPath "runtime\node22"),
        (Join-Path $script:RootPath "app\hermes-agent\venv\Scripts")
    )

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $newUserPath = Remove-PathEntries -PathValue $userPath -RemoveEntries $pathEntries
    if ($newUserPath -ne $userPath) {
        if ($DryRun) {
            Write-Host "       dry-run: would trim User PATH entries under this install root"
        } else {
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Write-Ok "Trimmed User PATH"
        }
    } else {
        Write-Ok "User PATH has no entries under this install root"
    }

    $vars = @(
        "HERMES_HOME",
        "HERMES_GIT_BASH_PATH",
        "UV_CACHE_DIR",
        "UV_PYTHON_INSTALL_DIR",
        "UV_PROJECT_ENVIRONMENT",
        "npm_config_registry"
    )

    foreach ($name in $vars) {
        $value = [Environment]::GetEnvironmentVariable($name, "User")
        if ($value -and (Test-PathInsideRoot $value)) {
            if ($DryRun) {
                Write-Host "       dry-run: would clear User $name=$value"
            } else {
                [Environment]::SetEnvironmentVariable($name, $null, "User")
                Write-Ok "Cleared User $name"
            }
        }
    }
}

function Test-UninstallResult {
    Write-Info "Verifying uninstall result"
    $remaining = @()
    $checks = @("app", "runtime", "uv-cache", "bin")
    if ($RemoveHome) {
        $checks += "home"
    }
    if ($RemoveSandbox) {
        $checks += ".sandbox"
    }

    foreach ($rel in $checks) {
        $path = Join-Path $script:RootPath $rel
        if (Test-Path -LiteralPath $path) {
            $remaining += $path
        }
    }

    if ($remaining.Count -gt 0) {
        throw "Uninstall incomplete. Remaining paths: $($remaining -join ', ')"
    }
    Write-Ok "Generated install paths removed"
}

function Main {
    Initialize-Root

    Write-Host ""
    Write-Host "Hermes Agent native Windows isolated uninstaller" -ForegroundColor Magenta
    Write-Host "Root:       $script:RootPath"
    Write-Host "RemoveHome: $RemoveHome"
    Write-Host ""

    if ($StopProcesses) {
        Stop-InstallProcesses
    }

    Remove-MatchingScheduledTasks
    Remove-MatchingStartupShortcuts

    Remove-GeneratedDirectory -RelativePath "app" -Label "Hermes source and venv"
    Remove-GeneratedDirectory -RelativePath "runtime" -Label "managed runtime"
    Remove-GeneratedDirectory -RelativePath "uv-cache" -Label "uv cache"
    Remove-GeneratedDirectory -RelativePath "bin" -Label "launcher directory"

    if ($RemoveHome) {
        Remove-GeneratedDirectory -RelativePath "home" -Label "Hermes home data"
    } else {
        Write-Warn "Preserving home directory. Pass -RemoveHome to remove config, auth, sessions, skills and logs."
    }

    if ($RemoveSandbox) {
        Remove-GeneratedDirectory -RelativePath ".sandbox" -Label "local sandbox output"
    }

    if ($CleanUserEnvironment) {
        Clean-UserEnvironment
    }

    if (-not $DryRun) {
        Test-UninstallResult
    } else {
        Write-Ok "Dry-run complete. No files were changed."
    }
}

try {
    Main
} catch {
    Write-Host ""
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
