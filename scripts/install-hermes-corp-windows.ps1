<# 
.SYNOPSIS
Install Hermes Agent on native Windows without mutating global environment.

.DESCRIPTION
This installer is intended for enterprise Windows desktops where GitHub access
is allowed for the hermes-agent source repository, while Python, Node, npm and
runtime environment changes must stay isolated under a single root directory.

It deliberately does not:
- write User or Machine PATH
- write User or Machine HERMES_HOME
- run winget, choco or scoop
- run git config --global
- install packages into the system Python or global npm prefix

It does:
- clone/update hermes-agent from GitHub
- create a local uv-managed Python 3.11 virtual environment
- optionally use a local/managed Node runtime for Node-based dependencies
- create a hermes-corp.ps1 launcher that sets process-local env vars

Run:
  cd <target-hermes-root>
  powershell -ExecutionPolicy Bypass -File .\scripts\install-hermes-corp-windows.ps1

By default, the install root is the current PowerShell directory where you run
the command. You can still override it with -Root.

Enterprise mirrors:
  -PypiIndexUrl https://pypi.corp/simple
  -NpmRegistry https://npm.corp/repository/npm/
  -PythonInstallMirror https://artifacts.corp/astral/python-build-standalone

If you need completely controlled binary downloads, pre-place uv.exe and
node.exe under the runtime paths or pass -UvExe/-NodeZip.
#>

[CmdletBinding()]
param(
    [string]$Root = "",
    [string]$RepoUrl = "https://github.com/NousResearch/hermes-agent.git",
    [string]$Branch = "v2026.5.7",
    [string]$PythonVersion = "3.11",
    [string]$NodeMajorVersion = "22",
    [string]$PypiIndexUrl = "",
    [string]$NpmRegistry = "",
    [string]$PythonInstallMirror = "",
    [string]$UvExe = "",
    [string]$NodeZip = "",
    [switch]$InstallNodeDeps,
    [switch]$ForceRecreateVenv,
    [switch]$SkipDependencyInstall,
    [switch]$SkipConfigTemplate,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:RootPath = $null
$script:AppDir = $null
$script:InstallDir = $null
$script:HermesHome = $null
$script:RuntimeDir = $null
$script:UvCacheDir = $null
$script:UvBinDir = $null
$script:PythonInstallDir = $null
$script:NodeDir = $null
$script:BinDir = $null
$script:UvCmd = $null
$script:GitCmd = $null
$script:NodeCmd = $null
$script:NpmCmd = $null
$script:GitBashPath = $null

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

function Invoke-Step {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    Write-Info $Description
    if ($DryRun) {
        Write-Host "       dry-run: skipped"
        return
    }
    & $Action
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
    if (($fullLower -ne $rootLower) -and (-not $fullLower.StartsWith($rootSlashLower))) {
        throw "$Purpose must stay under root '$root'. Got: $full"
    }
    return $full
}

function Initialize-Paths {
    if ($Root.Trim()) {
        $script:RootPath = Resolve-FullPath $Root
    } else {
        $script:RootPath = Resolve-FullPath (Get-Location).ProviderPath
    }
    $script:AppDir = Join-Path $script:RootPath "app"
    $script:InstallDir = Join-Path $script:AppDir "hermes-agent"
    $script:HermesHome = Join-Path $script:RootPath "home"
    $script:RuntimeDir = Join-Path $script:RootPath "runtime"
    $script:UvCacheDir = Join-Path $script:RootPath "uv-cache"
    $script:UvBinDir = Join-Path $script:RuntimeDir "uv"
    $script:PythonInstallDir = Join-Path $script:RuntimeDir "python"
    $script:NodeDir = Join-Path $script:RuntimeDir "node$NodeMajorVersion"
    $script:BinDir = Join-Path $script:RootPath "bin"

    [void](Assert-UnderRoot $script:AppDir "AppDir")
    [void](Assert-UnderRoot $script:InstallDir "InstallDir")
    [void](Assert-UnderRoot $script:HermesHome "HermesHome")
    [void](Assert-UnderRoot $script:RuntimeDir "RuntimeDir")
    [void](Assert-UnderRoot $script:UvCacheDir "UvCacheDir")
    [void](Assert-UnderRoot $script:UvBinDir "UvBinDir")
    [void](Assert-UnderRoot $script:PythonInstallDir "PythonInstallDir")
    [void](Assert-UnderRoot $script:NodeDir "NodeDir")
    [void](Assert-UnderRoot $script:BinDir "BinDir")
}

function New-DirectoryLayout {
    foreach ($dir in @(
        $script:RootPath,
        $script:AppDir,
        $script:HermesHome,
        $script:RuntimeDir,
        $script:UvCacheDir,
        $script:UvBinDir,
        $script:PythonInstallDir,
        $script:NodeDir,
        $script:BinDir
    )) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }

    foreach ($dirName in @("cron", "sessions", "logs", "pairing", "hooks", "image_cache", "audio_cache", "memories", "skills")) {
        $dir = Join-Path $script:HermesHome $dirName
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }
}

function Set-ProcessOnlyEnvironment {
    $env:HERMES_HOME = $script:HermesHome
    $env:UV_CACHE_DIR = $script:UvCacheDir
    $env:UV_PYTHON_INSTALL_DIR = $script:PythonInstallDir
    $env:UV_PYTHON_NO_REGISTRY = "1"
    $env:UV_PYTHON_INSTALL_REGISTRY = "0"
    $env:UV_PYTHON_PREFERENCE = "managed"
    $env:UV_PROJECT_ENVIRONMENT = Join-Path $script:InstallDir "venv"
    $env:VIRTUAL_ENV = Join-Path $script:InstallDir "venv"
    $env:UV_SYSTEM_CERTS = "true"
    $env:UV_NO_MODIFY_PATH = "1"
    $env:PIP_REQUIRE_VIRTUALENV = "true"
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    $env:TERMINAL_CWD = $script:RootPath
    $env:GIT_CONFIG_COUNT = "1"
    $env:GIT_CONFIG_KEY_0 = "windows.appendAtomically"
    $env:GIT_CONFIG_VALUE_0 = "false"

    if ($PypiIndexUrl.Trim()) {
        $env:UV_DEFAULT_INDEX = $PypiIndexUrl.Trim()
        $env:PIP_INDEX_URL = $PypiIndexUrl.Trim()
    }

    if ($PythonInstallMirror.Trim()) {
        $env:UV_PYTHON_INSTALL_MIRROR = $PythonInstallMirror.Trim()
    }

    if ($NpmRegistry.Trim()) {
        $env:npm_config_registry = $NpmRegistry.Trim()
    }

    $pathParts = New-Object System.Collections.Generic.List[string]
    $pathParts.Add((Join-Path $script:InstallDir "venv\Scripts"))
    if (Test-Path -LiteralPath (Join-Path $script:NodeDir "node.exe")) {
        $pathParts.Add($script:NodeDir)
    }
    $pathParts.Add($env:PATH)
    $env:PATH = ($pathParts -join ";")
}

function Find-Executable {
    param(
        [string]$Name,
        [string[]]$Candidates = @()
    )

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-FullPath $candidate)
        }
    }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Ensure-Uv {
    $localUv = Join-Path $script:UvBinDir "uv.exe"
    $uvCandidates = @()
    if ($UvExe.Trim()) {
        $uvCandidates += (Resolve-FullPath $UvExe.Trim())
    }
    $uvCandidates += $localUv

    $found = Find-Executable -Name "uv" -Candidates $uvCandidates
    if ($found) {
        $script:UvCmd = $found
        Write-Ok "uv: $(& $script:UvCmd --version)"
        return
    }

    throw "uv.exe not found. Put uv.exe at '$localUv', pass -UvExe, or install uv on PATH. This script will not run uv's global installer."
}

function Ensure-Git {
    $found = Find-Executable -Name "git"
    if (-not $found) {
        throw "git.exe not found on PATH. GitHub access is allowed, but this installer will not install Git globally."
    }
    $script:GitCmd = $found
    Write-Ok "git: $(& $script:GitCmd --version)"
}

function Find-GitBash {
    $candidates = New-Object System.Collections.Generic.List[string]

    try {
        $gitRoot = & $script:GitCmd -c windows.appendAtomically=false rev-parse --path-format=absolute --git-path "..\.." 2>$null
        if ($gitRoot) {
            $gitRoot = Resolve-FullPath $gitRoot
            $candidates.Add((Join-Path $gitRoot "bin\bash.exe"))
            $candidates.Add((Join-Path $gitRoot "usr\bin\bash.exe"))
        }
    } catch {
        # Ignore and fall back to common locations.
    }

    $gitExeDir = Split-Path $script:GitCmd -Parent
    if ($gitExeDir) {
        $maybeRoot = Split-Path $gitExeDir -Parent
        if ($maybeRoot) {
            $candidates.Add((Join-Path $maybeRoot "bin\bash.exe"))
            $candidates.Add((Join-Path $maybeRoot "usr\bin\bash.exe"))
        }
    }

    $candidates.Add((Join-Path ${env:ProgramFiles} "Git\bin\bash.exe"))
    $pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($pf86) {
        $candidates.Add((Join-Path $pf86 "Git\bin\bash.exe"))
    }
    $candidates.Add((Join-Path ${env:LocalAppData} "Programs\Git\bin\bash.exe"))

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $script:GitBashPath = Resolve-FullPath $candidate
            Write-Ok "Git Bash: $script:GitBashPath"
            return
        }
    }

    Write-Warn "Git Bash was not found. Hermes terminal features may need HERMES_GIT_BASH_PATH in the launcher."
}

function Update-Repository {
    $repoValid = $false
    if (Test-Path -LiteralPath (Join-Path $script:InstallDir ".git")) {
        Push-Location $script:InstallDir
        try {
            $inside = & $script:GitCmd -c windows.appendAtomically=false rev-parse --is-inside-work-tree 2>$null
            if ($LASTEXITCODE -eq 0 -and $inside -match "true") {
                $repoValid = $true
            }
        } finally {
            Pop-Location
        }
    }

    if ($repoValid) {
        Write-Info "Updating existing hermes-agent repository..."
        Push-Location $script:InstallDir
        try {
            & $script:GitCmd -c windows.appendAtomically=false remote set-url origin $RepoUrl
            & $script:GitCmd -c windows.appendAtomically=false fetch --tags origin
            if ($LASTEXITCODE -ne 0) {
                throw "git fetch failed"
            }
            & $script:GitCmd -c windows.appendAtomically=false checkout $Branch
            if ($LASTEXITCODE -ne 0) {
                throw "git checkout $Branch failed"
            }
            try {
                & $script:GitCmd -c windows.appendAtomically=false pull --ff-only origin $Branch
            } catch {
                Write-Warn "git pull skipped or failed for tag/detached checkout."
            }
            & $script:GitCmd -c windows.appendAtomically=false submodule update --init --recursive
        } finally {
            Pop-Location
        }
        Write-Ok "Repository ready at $script:InstallDir"
        return
    }

    if (Test-Path -LiteralPath $script:InstallDir) {
        $existing = Get-ChildItem -LiteralPath $script:InstallDir -Force -ErrorAction SilentlyContinue
        if ($existing) {
            throw "InstallDir exists but is not a git repo: $script:InstallDir. Move it aside or remove it manually."
        }
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:InstallDir -Parent) | Out-Null
    }

    Write-Info "Cloning $RepoUrl ($Branch)..."
    & $script:GitCmd -c windows.appendAtomically=false clone --branch $Branch --recurse-submodules $RepoUrl $script:InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw "git clone failed"
    }
    Push-Location $script:InstallDir
    try {
        & $script:GitCmd -c windows.appendAtomically=false config windows.appendAtomically false
        & $script:GitCmd -c windows.appendAtomically=false submodule update --init --recursive
    } finally {
        Pop-Location
    }
    Write-Ok "Repository ready at $script:InstallDir"
}

function Ensure-Venv {
    $venvDir = Join-Path $script:InstallDir "venv"
    if ((Test-Path -LiteralPath $venvDir) -and $ForceRecreateVenv) {
        $safeVenv = Assert-UnderRoot $venvDir "venv"
        Remove-Item -LiteralPath $safeVenv -Recurse -Force
    }

    if (Test-Path -LiteralPath (Join-Path $venvDir "Scripts\python.exe")) {
        Write-Ok "venv exists: $venvDir"
        return
    }

    Push-Location $script:InstallDir
    try {
        & $script:UvCmd venv $venvDir --python $PythonVersion
        if ($LASTEXITCODE -ne 0) {
            throw "uv venv failed"
        }
    } finally {
        Pop-Location
    }
    Write-Ok "venv created: $venvDir"
}

function Install-PythonDependencies {
    if ($SkipDependencyInstall) {
        Write-Warn "Python dependency install skipped."
        return
    }

    $venvPython = Join-Path $script:InstallDir "venv\Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        throw "venv Python not found: $venvPython"
    }

    Push-Location $script:InstallDir
    try {
        if (Test-Path -LiteralPath "uv.lock") {
            Write-Info "Installing Python dependencies with uv.lock..."
            & $script:UvCmd sync --extra all --locked
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Python dependencies installed from uv.lock"
            } else {
                Write-Warn "uv sync --locked failed. Falling back to editable all-extra install."
                & $script:UvCmd pip install --python $venvPython -e ".[all]"
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "Editable all-extra install failed. Falling back to core package only."
                    & $script:UvCmd pip install --python $venvPython -e .
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "uv pip install fallback failed"
                }
            }
        } else {
            Write-Info "uv.lock not found. Installing editable core package..."
            & $script:UvCmd pip install --python $venvPython -e .
            if ($LASTEXITCODE -ne 0) {
                throw "uv pip install -e . failed"
            }
        }

        & $venvPython -c "import dotenv, openai, rich, prompt_toolkit" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "baseline imports failed in local venv"
        }
    } finally {
        Pop-Location
    }
}

function Ensure-Node {
    $localNode = Join-Path $script:NodeDir "node.exe"
    if (Test-Path -LiteralPath $localNode) {
        $script:NodeCmd = $localNode
        $script:NpmCmd = Join-Path $script:NodeDir "npm.cmd"
        Write-Ok "managed Node: $(& $script:NodeCmd --version)"
        return
    }

    if ($NodeZip.Trim()) {
        $zipPath = Resolve-FullPath $NodeZip.Trim()
        if (-not (Test-Path -LiteralPath $zipPath)) {
            throw "NodeZip not found: $zipPath"
        }
        $extractRoot = Join-Path $script:RuntimeDir "node-extract"
        if (Test-Path -LiteralPath $extractRoot) {
            $safeExtract = Assert-UnderRoot $extractRoot "node extract dir"
            Remove-Item -LiteralPath $safeExtract -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force
        $extracted = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
        if (-not $extracted) {
            throw "NodeZip did not contain a Node directory"
        }
        if (Test-Path -LiteralPath $script:NodeDir) {
            $safeNode = Assert-UnderRoot $script:NodeDir "NodeDir"
            Remove-Item -LiteralPath $safeNode -Recurse -Force
        }
        Move-Item -LiteralPath $extracted.FullName -Destination $script:NodeDir
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
        $script:NodeCmd = Join-Path $script:NodeDir "node.exe"
        $script:NpmCmd = Join-Path $script:NodeDir "npm.cmd"
        Write-Ok "managed Node unpacked: $(& $script:NodeCmd --version)"
        return
    }

    throw "Managed Node was requested but not found. Place Node under '$script:NodeDir' or pass -NodeZip. This script will not use system Node."
}

function Install-NodeDependencies {
    if (-not $InstallNodeDeps) {
        Write-Warn "Node dependency install skipped. This keeps browser/TUI tooling out of the base install."
        return
    }

    Ensure-Node

    if (-not (Test-Path -LiteralPath $script:NpmCmd)) {
        throw "npm.cmd not found next to managed Node: $script:NpmCmd"
    }

    if (Test-Path -LiteralPath (Join-Path $script:InstallDir "package.json")) {
        Push-Location $script:InstallDir
        try {
            & $script:NpmCmd install --silent
            if ($LASTEXITCODE -ne 0) {
                throw "npm install failed in $script:InstallDir"
            }
        } finally {
            Pop-Location
        }
    }

    $tuiDir = Join-Path $script:InstallDir "ui-tui"
    if (Test-Path -LiteralPath (Join-Path $tuiDir "package.json")) {
        Push-Location $tuiDir
        try {
            & $script:NpmCmd install --silent
            if ($LASTEXITCODE -ne 0) {
                throw "npm install failed in $tuiDir"
            }
        } finally {
            Pop-Location
        }
    }
}

function Write-TextNoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Patch-WindowsHermesLocalBackend {
    $localBackend = Join-Path $script:InstallDir "tools\environments\local.py"
    if (-not (Test-Path -LiteralPath $localBackend)) {
        Write-Warn "Hermes local backend not found; Windows cwd patch skipped."
        return
    }

    $content = [System.IO.File]::ReadAllText($localBackend)

    if ($content -notmatch "def _windows_git_bash_to_native") {
        $helper = @'
def _windows_git_bash_to_native(path: str) -> str:
    if not (_IS_WINDOWS and path):
        return path
    match = re.match(r"^/([a-zA-Z])(?:/|$)", path)
    if not match:
        return path
    drive = match.group(1).upper() + ":"
    rest = path[2:].replace("/", "\\")
    return drive + rest


def _path_is_dir(path: str) -> bool:
    if not path:
        return False
    if os.path.isdir(path):
        return True
    native = _windows_git_bash_to_native(path)
    return native != path and os.path.isdir(native)


'@
        $insertAt = $content.IndexOf("def _resolve_safe_cwd")
        if ($insertAt -lt 0) {
            Write-Warn "Hermes local backend cwd patch anchor not found."
            return
        }
        $content = $content.Substring(0, $insertAt) + $helper + $content.Substring($insertAt)
    }

    $content = $content.Replace("if cwd and os.path.isdir(cwd):", "if _path_is_dir(cwd):")
    $content = $content.Replace("if os.path.isdir(parent):", "if _path_is_dir(parent):")
    $content = $content.Replace("if cwd_path and os.path.isdir(cwd_path):", "if cwd_path and _path_is_dir(cwd_path):")

    Write-TextNoBom -Path $localBackend -Content $content
    Write-Ok "Applied Windows Git Bash cwd compatibility patch"
}

function Copy-ConfigTemplates {
    if ($SkipConfigTemplate) {
        Write-Warn "Config template creation skipped."
        return
    }

    $envPath = Join-Path $script:HermesHome ".env"
    if (-not (Test-Path -LiteralPath $envPath)) {
        Write-TextNoBom -Path $envPath -Content @"
# Keep secrets here. This file is loaded by the hermes-corp launcher.
CORP_LLM_API_KEY=
NO_PROXY=.corp.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1
"@
        Write-Ok "Created $envPath"
    }

    $configPath = Join-Path $script:HermesHome "config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-TextNoBom -Path $configPath -Content @'
# Enterprise starter config. Fill in your internal model gateway and MCP URLs.
model:
  provider: custom
  default: corp-model
  base_url: https://llm-gateway.corp.local/v1
  api_key: ${CORP_LLM_API_KEY}

toolsets:
  - file
  - terminal
  - todo
  - skills
  - session_search

mcp_servers: {}
'@
        Write-Ok "Created $configPath"
    }

    $soulPath = Join-Path $script:HermesHome "SOUL.md"
    if (-not (Test-Path -LiteralPath $soulPath)) {
        Write-TextNoBom -Path $soulPath -Content "# Hermes Agent Persona`r`n"
        Write-Ok "Created $soulPath"
    }

    $skillsSync = Join-Path $script:InstallDir "tools\skills_sync.py"
    $venvPython = Join-Path $script:InstallDir "venv\Scripts\python.exe"
    if ((Test-Path -LiteralPath $skillsSync) -and (Test-Path -LiteralPath $venvPython)) {
        & $venvPython $skillsSync 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Bundled skills synced"
        } else {
            Write-Warn "Bundled skill sync failed; Hermes can still run."
        }
    }
}

function Write-Launcher {
    $launcherPath = Join-Path $script:BinDir "hermes-corp.ps1"
    $escapedGitBash = ""
    if ($script:GitBashPath) {
        $escapedGitBash = $script:GitBashPath.Replace("'", "''")
    }

    $launcher = @"
param(
    [Parameter(ValueFromRemainingArguments=`$true)]
    [string[]]`$ArgsToHermes
)

`$ErrorActionPreference = "Stop"
`$Root = (Resolve-Path -LiteralPath (Join-Path `$PSScriptRoot '..')).ProviderPath
`$InstallDir = Join-Path `$Root 'app\hermes-agent'
`$HermesHome = Join-Path `$Root 'home'
`$VenvScripts = Join-Path `$InstallDir 'venv\Scripts'
`$NodeDir = Join-Path `$Root 'runtime\node$NodeMajorVersion'
`$HermesExe = Join-Path `$VenvScripts 'hermes.exe'

if (-not (Test-Path -LiteralPath `$HermesExe)) {
    throw "Hermes executable not found: `$HermesExe"
}

`$env:HERMES_HOME = `$HermesHome
`$env:UV_CACHE_DIR = Join-Path `$Root 'uv-cache'
`$env:UV_PYTHON_NO_REGISTRY = '1'
`$env:UV_NO_MODIFY_PATH = '1'
`$env:PIP_REQUIRE_VIRTUALENV = 'true'
`$env:PYTHONUTF8 = '1'
`$env:PYTHONIOENCODING = 'utf-8'
`$env:TERMINAL_CWD = `$Root
"@

    if ($escapedGitBash) {
        $launcher += "`r`n`$env:HERMES_GIT_BASH_PATH = '$escapedGitBash'`r`n"
    }

    $launcher += @"

if (Test-Path -LiteralPath (Join-Path `$NodeDir 'node.exe')) {
    `$env:PATH = "`$VenvScripts;`$NodeDir;`$env:PATH"
} else {
    `$env:PATH = "`$VenvScripts;`$env:PATH"
}

& `$HermesExe @ArgsToHermes
exit `$LASTEXITCODE
"@

    Write-TextNoBom -Path $launcherPath -Content $launcher
    Write-Ok "Launcher written: $launcherPath"
}

function Test-Install {
    $hermesExe = Join-Path $script:InstallDir "venv\Scripts\hermes.exe"
    if (-not (Test-Path -LiteralPath $hermesExe)) {
        throw "Hermes executable not found after install: $hermesExe"
    }

    $env:HERMES_HOME = $script:HermesHome
    & $hermesExe --version
    if ($LASTEXITCODE -ne 0) {
        throw "hermes --version failed"
    }
}

function Main {
    Initialize-Paths

    Write-Host ""
    Write-Host "Hermes Agent native Windows isolated installer" -ForegroundColor Magenta
    Write-Host "Root:       $script:RootPath"
    Write-Host "Repo:       $RepoUrl"
    Write-Host "Branch/tag: $Branch"
    Write-Host ""

    Invoke-Step "Creating local directory layout" { New-DirectoryLayout }
    Invoke-Step "Setting process-local environment" { Set-ProcessOnlyEnvironment }
    Invoke-Step "Checking uv" { Ensure-Uv }
    Invoke-Step "Checking git" { Ensure-Git; Find-GitBash }
    Invoke-Step "Cloning/updating hermes-agent" { Update-Repository }
    Invoke-Step "Creating isolated Python virtual environment" { Ensure-Venv }
    Invoke-Step "Installing Python dependencies into local venv" { Install-PythonDependencies }
    Invoke-Step "Installing optional Node dependencies" { Install-NodeDependencies }
    Invoke-Step "Patching Hermes Windows local backend" { Patch-WindowsHermesLocalBackend }
    Invoke-Step "Creating local Hermes config templates" { Copy-ConfigTemplates }
    Invoke-Step "Writing process-local launcher" { Write-Launcher }
    Invoke-Step "Verifying Hermes executable" { Test-Install }

    Write-Host ""
    if ($DryRun) {
        Write-Ok "Dry-run complete. No files were changed."
    } else {
        Write-Ok "Hermes isolated install complete"
        Write-Host ""
        Write-Host "Run:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script:BinDir\hermes-corp.ps1`" --version"
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script:BinDir\hermes-corp.ps1`""
        Write-Host ""
        Write-Host "Nothing was written to User/Machine PATH or User/Machine HERMES_HOME."
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
