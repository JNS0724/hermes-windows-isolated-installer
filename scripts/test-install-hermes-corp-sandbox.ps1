<#
.SYNOPSIS
Sandbox validation for install-hermes-corp-windows.ps1.

.DESCRIPTION
Creates a disposable local fake hermes-agent source tree, source zip, and fake
uv command, then runs the installer from sandbox working directories without
-Root. This verifies the default "current directory is install root" behavior
without git clone, network access, or global environment writes.
#>

[CmdletBinding()]
param(
    [string]$SandboxName = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Write-Step {
    param([string]$Message)
    Write-Host "[TEST] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-TextNoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-File {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "Expected file/path not found: $Path"
}

function Resolve-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Assert-UnderPath {
    param(
        [string]$Candidate,
        [string]$Root,
        [string]$Label
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate)
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $rootSlash = $rootFull.TrimEnd('\') + '\'
    $candidateLower = $candidateFull.ToLowerInvariant()
    $rootLower = $rootFull.ToLowerInvariant()
    $rootSlashLower = $rootSlash.ToLowerInvariant()
    if (($candidateLower -ne $rootLower) -and (-not $candidateLower.StartsWith($rootSlashLower))) {
        throw "$Label is outside expected root. Candidate=$candidateFull Root=$rootFull"
    }
}

function Remove-SandboxTree {
    param([string]$Path)

    $sandboxBase = Join-Path $repoRoot ".sandbox"
    Assert-UnderPath -Candidate $Path -Root $sandboxBase -Label "remove target"
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $_.Attributes = [System.IO.FileAttributes]::Normal
            } catch {
                # Best effort; Remove-Item below will surface real failures.
            }
        }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $fullControl, $allow)
    @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue) |
        ForEach-Object {
            try {
                $acl = Get-Acl -LiteralPath $_.FullName
                $acl.SetAccessRule($rule)
                Set-Acl -LiteralPath $_.FullName -AclObject $acl
            } catch {
                # Best effort; Remove-Item below will surface real failures.
            }
        }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).ProviderPath
if (-not $SandboxName.Trim()) {
    $SandboxName = "install-corp-sandbox-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
}
$installer = Join-Path $repoRoot "scripts\install-hermes-corp-windows.ps1"
$sandboxRoot = Join-Path $repoRoot ".sandbox\$SandboxName"
$sourceRepo = Join-Path $sandboxRoot "source\hermes-agent-fake"
$sourceZip = Join-Path $sandboxRoot "source\hermes-agent-fake.zip"
$pipConfigFile = Join-Path $sandboxRoot "pip.ini"
$npmConfigFile = Join-Path $sandboxRoot ".npmrc"
$npmCaFile = Join-Path $sandboxRoot "corp-npm-ca.pem"
$fakeUvEnvLog = Join-Path $sandboxRoot "fake-uv-env.log"
$installRoot = Join-Path $sandboxRoot "target"
$zipInstallRoot = Join-Path $sandboxRoot "target-zip"
$missingSourceRoot = Join-Path $sandboxRoot "target-missing-source"
$missingSourceOutput = Join-Path $sandboxRoot "missing-source.out.log"
$fakeUv = Join-Path $sandboxRoot "tools\uv.cmd"

Assert-File $installer
Assert-UnderPath -Candidate $sandboxRoot -Root (Join-Path $repoRoot ".sandbox") -Label "sandbox root"

$originalUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$originalUserHermesHome = [Environment]::GetEnvironmentVariable("HERMES_HOME", "User")
$originalProcessPath = $env:PATH
$originalProcessHermesHome = $env:HERMES_HOME
$originalPipRequireVenv = $env:PIP_REQUIRE_VIRTUALENV
$originalUvCacheDir = $env:UV_CACHE_DIR
$originalGitConfigCount = $env:GIT_CONFIG_COUNT
$originalGitConfigKey0 = $env:GIT_CONFIG_KEY_0
$originalGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
$originalPipConfigFile = $env:PIP_CONFIG_FILE
$originalFakeUvLog = $env:FAKE_UV_LOG
$originalUvDefaultIndex = $env:UV_DEFAULT_INDEX
$originalUvIndexUrl = $env:UV_INDEX_URL
$originalUvIndex = $env:UV_INDEX
$originalUvExtraIndexUrl = $env:UV_EXTRA_INDEX_URL
$originalPipIndexUrl = $env:PIP_INDEX_URL
$originalPipExtraIndexUrl = $env:PIP_EXTRA_INDEX_URL
$originalUvInsecureHost = $env:UV_INSECURE_HOST
$originalPipTrustedHost = $env:PIP_TRUSTED_HOST
$originalUvFindLinks = $env:UV_FIND_LINKS
$originalPipFindLinks = $env:PIP_FIND_LINKS
$originalNpmUserConfig = $env:npm_config_userconfig
$originalNpmGlobalConfig = $env:npm_config_globalconfig
$originalNpmRegistry = $env:npm_config_registry
$originalNpmProxy = $env:npm_config_proxy
$originalNpmHttpsProxy = $env:npm_config_https_proxy
$originalNpmStrictSsl = $env:npm_config_strict_ssl
$originalNpmCaFile = $env:npm_config_cafile

try {
    $env:GIT_CONFIG_COUNT = "1"
    $env:GIT_CONFIG_KEY_0 = "windows.appendAtomically"
    $env:GIT_CONFIG_VALUE_0 = "false"
    $env:PIP_CONFIG_FILE = $pipConfigFile
    $env:FAKE_UV_LOG = $fakeUvEnvLog
    $env:UV_DEFAULT_INDEX = $null
    $env:UV_INDEX_URL = $null
    $env:UV_INDEX = $null
    $env:UV_EXTRA_INDEX_URL = $null
    $env:PIP_INDEX_URL = $null
    $env:PIP_EXTRA_INDEX_URL = $null
    $env:UV_INSECURE_HOST = $null
    $env:PIP_TRUSTED_HOST = $null
    $env:UV_FIND_LINKS = $null
    $env:PIP_FIND_LINKS = $null
    $env:npm_config_userconfig = $npmConfigFile
    $env:npm_config_globalconfig = $null
    $env:npm_config_registry = $null
    $env:npm_config_proxy = $null
    $env:npm_config_https_proxy = $null
    $env:npm_config_strict_ssl = $null
    $env:npm_config_cafile = $null

    Write-Step "Resetting sandbox: $sandboxRoot"
    if (Test-Path -LiteralPath $sandboxRoot) {
        Remove-SandboxTree -Path $sandboxRoot
    }
    New-Item -ItemType Directory -Force -Path $sourceRepo, $installRoot, $zipInstallRoot, $missingSourceRoot, (Split-Path $fakeUv -Parent) | Out-Null

    Write-Step "Creating fake uv command"
    Write-TextNoBom -Path $fakeUv -Content @'
@echo off
setlocal EnableDelayedExpansion
if not "%FAKE_UV_LOG%"=="" (
  echo CMD=%*>>"%FAKE_UV_LOG%"
  echo UV_DEFAULT_INDEX=%UV_DEFAULT_INDEX%>>"%FAKE_UV_LOG%"
  echo UV_INDEX_URL=%UV_INDEX_URL%>>"%FAKE_UV_LOG%"
  echo PIP_INDEX_URL=%PIP_INDEX_URL%>>"%FAKE_UV_LOG%"
  echo UV_INDEX=%UV_INDEX%>>"%FAKE_UV_LOG%"
  echo UV_EXTRA_INDEX_URL=%UV_EXTRA_INDEX_URL%>>"%FAKE_UV_LOG%"
  echo PIP_EXTRA_INDEX_URL=%PIP_EXTRA_INDEX_URL%>>"%FAKE_UV_LOG%"
  echo UV_INSECURE_HOST=%UV_INSECURE_HOST%>>"%FAKE_UV_LOG%"
  echo PIP_TRUSTED_HOST=%PIP_TRUSTED_HOST%>>"%FAKE_UV_LOG%"
  echo npm_config_registry=%npm_config_registry%>>"%FAKE_UV_LOG%"
  echo npm_config_proxy=%npm_config_proxy%>>"%FAKE_UV_LOG%"
  echo npm_config_https_proxy=%npm_config_https_proxy%>>"%FAKE_UV_LOG%"
  echo npm_config_strict_ssl=%npm_config_strict_ssl%>>"%FAKE_UV_LOG%"
  echo npm_config_cafile=%npm_config_cafile%>>"%FAKE_UV_LOG%"
  echo npm_config_userconfig=%npm_config_userconfig%>>"%FAKE_UV_LOG%"
)
if "%~1"=="--version" (
  echo uv 0.0.0-sandbox
  exit /b 0
)
if "%~1"=="venv" (
  set "VENV=%~2"
  if "!VENV!"=="" exit /b 2
  mkdir "!VENV!\Scripts" >nul 2>nul
  copy /Y "%SystemRoot%\System32\cmd.exe" "!VENV!\Scripts\python.exe" >nul
  copy /Y "%SystemRoot%\System32\cmd.exe" "!VENV!\Scripts\hermes.exe" >nul
  exit /b 0
)
if "%~1"=="sync" exit /b 0
if "%~1"=="pip" exit /b 0
echo unsupported fake uv command: %*
exit /b 1
'@

    Write-Step "Creating fake system pip config"
    Write-TextNoBom -Path $pipConfigFile -Content @'
[global]
index-url = https://pypi.corp/simple
extra-index-url =
    https://pypi-extra.corp/simple
trusted-host =
    pypi.corp
    pypi-extra.corp
'@

    Write-Step "Creating fake local npm config"
    Write-TextNoBom -Path $npmCaFile -Content "fake npm ca`r`n"
    Write-TextNoBom -Path $npmConfigFile -Content @"
registry=https://npm.corp/repository/npm/
proxy=http://proxy.corp.local:8080
https-proxy=http://proxy.corp.local:8080
strict-ssl=false
cafile=$npmCaFile
"@

    Write-Step "Creating local fake hermes-agent source tree"
    Write-TextNoBom -Path (Join-Path $sourceRepo "README.md") -Content "# fake hermes-agent`r`n"
    Write-TextNoBom -Path (Join-Path $sourceRepo "hermes_cli\__init__.py") -Content ""
    Write-TextNoBom -Path (Join-Path $sourceRepo "pyproject.toml") -Content @'
[project]
name = "hermes-agent"
version = "0.0.0"
'@

    Write-Step "Creating local fake hermes-agent source zip"
    Compress-Archive -Path (Join-Path $sourceRepo "*") -DestinationPath $sourceZip -Force

    Write-Step "Creating a stale partial source directory to verify re-run repair"
    $partialInstallDir = Join-Path $installRoot "app\hermes-agent"
    New-Item -ItemType Directory -Force -Path $partialInstallDir | Out-Null
    Write-TextNoBom -Path (Join-Path $partialInstallDir "stale-clone-marker.txt") -Content "partial clone`r`n"

    Write-Step "Running installer from sandbox target without -Root"
    Push-Location $installRoot
    try {
        & $installer `
            -SourcePath $sourceRepo `
            -UvExe $fakeUv `
            -SkipDependencyInstall
    } finally {
        Pop-Location
    }

    Write-Step "Checking expected sandbox outputs"
    $installedRepo = Join-Path $installRoot "app\hermes-agent"
    $venvHermes = Join-Path $installedRepo "venv\Scripts\hermes.exe"
    $config = Join-Path $installRoot "home\config.yaml"
    $envFile = Join-Path $installRoot "home\.env"
    $launcher = Join-Path $installRoot "bin\hermes-corp.ps1"

    Assert-File (Join-Path $installedRepo "pyproject.toml")
    Assert-File (Join-Path $installedRepo "hermes_cli\__init__.py")
    Assert-File $venvHermes
    Assert-File $config
    Assert-File $envFile
    Assert-File $launcher
    Assert-File $fakeUvEnvLog
    $fakeUvEnvText = Get-Content -LiteralPath $fakeUvEnvLog -Raw
    Assert-True ($fakeUvEnvText.Contains("UV_DEFAULT_INDEX=https://pypi.corp/simple")) "uv should inherit pip index-url as UV_DEFAULT_INDEX"
    Assert-True ($fakeUvEnvText.Contains("PIP_INDEX_URL=https://pypi.corp/simple")) "pip should inherit pip index-url as PIP_INDEX_URL"
    Assert-True ($fakeUvEnvText.Contains("UV_INDEX=https://pypi-extra.corp/simple")) "uv should inherit pip extra-index-url as UV_INDEX"
    Assert-True ($fakeUvEnvText.Contains("UV_EXTRA_INDEX_URL=https://pypi-extra.corp/simple")) "uv should inherit pip extra-index-url compat env"
    Assert-True ($fakeUvEnvText.Contains("PIP_EXTRA_INDEX_URL=https://pypi-extra.corp/simple")) "pip should inherit pip extra-index-url"
    Assert-True ($fakeUvEnvText.Contains("UV_INSECURE_HOST=pypi.corp pypi-extra.corp")) "uv should inherit pip trusted-host"
    Assert-True ($fakeUvEnvText.Contains("PIP_TRUSTED_HOST=pypi.corp pypi-extra.corp")) "pip should inherit pip trusted-host"
    Assert-True ($fakeUvEnvText.Contains("npm_config_registry=https://npm.corp/repository/npm/")) "npm should inherit local registry"
    Assert-True ($fakeUvEnvText.Contains("npm_config_proxy=http://proxy.corp.local:8080")) "npm should inherit local proxy"
    Assert-True ($fakeUvEnvText.Contains("npm_config_https_proxy=http://proxy.corp.local:8080")) "npm should inherit local https-proxy"
    Assert-True ($fakeUvEnvText.Contains("npm_config_strict_ssl=false")) "npm should inherit local strict-ssl"
    Assert-True ($fakeUvEnvText.Contains("npm_config_cafile=$npmCaFile")) "npm should inherit local cafile"
    Assert-True ($fakeUvEnvText.Contains("npm_config_userconfig=$npmConfigFile")) "npm should preserve local userconfig path"

    $partialArchives = @(Get-ChildItem -LiteralPath (Join-Path $installRoot "app") -Directory -Filter "hermes-agent.partial-*" -ErrorAction SilentlyContinue)
    Assert-True ($partialArchives.Count -eq 1) "Expected stale partial source directory to be moved aside once"
    Assert-File (Join-Path $partialArchives[0].FullName "stale-clone-marker.txt")

    $configText = Get-Content -LiteralPath $config -Raw
    Assert-True ($configText.Contains('${CORP_LLM_API_KEY}')) "config.yaml should preserve literal `${CORP_LLM_API_KEY}"

    $launcherText = Get-Content -LiteralPath $launcher -Raw
    Assert-True ($launcherText.Contains("Join-Path `$PSScriptRoot '..'")) "launcher should derive root from its own location"
    Assert-True (-not $launcherText.Contains($installRoot)) "launcher should not hard-code sandbox install root"

    Write-Step "Running generated launcher"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher --version | Out-Host
    Assert-True ($LASTEXITCODE -eq 0) "generated launcher failed"

    Write-Step "Running installer with -SourceZip"
    Push-Location $zipInstallRoot
    try {
        & $installer `
            -SourceZip $sourceZip `
            -UvExe $fakeUv `
            -SkipDependencyInstall
    } finally {
        Pop-Location
    }

    $zipInstalledRepo = Join-Path $zipInstallRoot "app\hermes-agent"
    Assert-File (Join-Path $zipInstalledRepo "pyproject.toml")
    Assert-File (Join-Path $zipInstalledRepo "hermes_cli\__init__.py")
    Assert-File (Join-Path $zipInstalledRepo "venv\Scripts\hermes.exe")

    Write-Step "Checking missing local source fails without git clone"
    Push-Location $missingSourceRoot
    try {
        & $installer -UvExe $fakeUv -SkipDependencyInstall *> $missingSourceOutput
        $missingSourceExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-True ($missingSourceExitCode -ne 0) "installer should fail when no local source is provided and -AllowGitClone is omitted"
    $missingSourceText = Get-Content -LiteralPath $missingSourceOutput -Raw
    Assert-True ($missingSourceText.Contains("Local source is required")) "missing source error should explain manual source requirement"
    Assert-True (-not $missingSourceText.Contains("Cloning ")) "installer should not try git clone unless -AllowGitClone is provided"

    Write-Step "Checking global environment was not changed"
    $afterUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $afterUserHermesHome = [Environment]::GetEnvironmentVariable("HERMES_HOME", "User")
    Assert-True ($afterUserPath -eq $originalUserPath) "User PATH changed"
    Assert-True ($afterUserHermesHome -eq $originalUserHermesHome) "User HERMES_HOME changed"

    Write-Pass "Sandbox install script validation passed"
    Write-Host "Sandbox root: $sandboxRoot"
} finally {
    $env:PATH = $originalProcessPath
    $env:HERMES_HOME = $originalProcessHermesHome
    $env:PIP_REQUIRE_VIRTUALENV = $originalPipRequireVenv
    $env:UV_CACHE_DIR = $originalUvCacheDir
    $env:GIT_CONFIG_COUNT = $originalGitConfigCount
    $env:GIT_CONFIG_KEY_0 = $originalGitConfigKey0
    $env:GIT_CONFIG_VALUE_0 = $originalGitConfigValue0
    $env:PIP_CONFIG_FILE = $originalPipConfigFile
    $env:FAKE_UV_LOG = $originalFakeUvLog
    $env:UV_DEFAULT_INDEX = $originalUvDefaultIndex
    $env:UV_INDEX_URL = $originalUvIndexUrl
    $env:UV_INDEX = $originalUvIndex
    $env:UV_EXTRA_INDEX_URL = $originalUvExtraIndexUrl
    $env:PIP_INDEX_URL = $originalPipIndexUrl
    $env:PIP_EXTRA_INDEX_URL = $originalPipExtraIndexUrl
    $env:UV_INSECURE_HOST = $originalUvInsecureHost
    $env:PIP_TRUSTED_HOST = $originalPipTrustedHost
    $env:UV_FIND_LINKS = $originalUvFindLinks
    $env:PIP_FIND_LINKS = $originalPipFindLinks
    $env:npm_config_userconfig = $originalNpmUserConfig
    $env:npm_config_globalconfig = $originalNpmGlobalConfig
    $env:npm_config_registry = $originalNpmRegistry
    $env:npm_config_proxy = $originalNpmProxy
    $env:npm_config_https_proxy = $originalNpmHttpsProxy
    $env:npm_config_strict_ssl = $originalNpmStrictSsl
    $env:npm_config_cafile = $originalNpmCaFile
}
