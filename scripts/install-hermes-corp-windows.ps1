<# 
.SYNOPSIS
Install Hermes Agent on native Windows without mutating global environment.

.DESCRIPTION
This installer is intended for enterprise Windows desktops where users can
download the hermes-agent source from GitHub manually, while Python, Node, npm
and runtime environment changes must stay isolated under a single root
directory.

It deliberately does not:
- write User or Machine PATH
- write User or Machine HERMES_HOME
- run winget, choco or scoop
- run git config --global
- install packages into the system Python or global npm prefix

It does:
- prepare hermes-agent from a local source directory or source zip
- optionally clone/update hermes-agent from GitHub only when -AllowGitClone is given
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
  -HttpsProxy http://proxy.corp.local:8080
  -NoProxy .corp.local,10.0.0.0/8,localhost,127.0.0.1
  If -PypiIndexUrl is omitted, the installer tries to read pip config from
  PIP_CONFIG_FILE, %APPDATA%\pip\pip.ini and %PROGRAMDATA%\pip\pip.ini.

Manual source install:
  Download Hermes Agent source zip from GitHub, extract it locally, then pass:
  -SourcePath C:\path\to\hermes-agent-source
  Or pass the downloaded zip directly:
  -SourceZip C:\path\to\hermes-agent-v2026.5.7.zip
  Git clone fallback is disabled unless -AllowGitClone is passed.

Diagnostics:
  Installer logs are written to <root>\logs by default.
  Runtime launcher logs are written to <root>\home\logs.
  Pass -LogDir to place installer logs elsewhere.

If you need completely controlled binary downloads, pre-place uv.exe and
node.exe under the runtime paths or pass -UvExe/-NodeZip.
#>

[CmdletBinding()]
param(
    [string]$Root = "",
    [string]$SourcePath = "",
    [string]$SourceZip = "",
    [string]$RepoUrl = "https://github.com/NousResearch/hermes-agent.git",
    [string]$Branch = "v2026.5.7",
    [string]$PythonVersion = "3.11",
    [string]$NodeMajorVersion = "22",
    [string]$PypiIndexUrl = "",
    [string]$NpmRegistry = "",
    [string]$PythonInstallMirror = "",
    [string]$HttpProxy = "",
    [string]$HttpsProxy = "",
    [string]$NoProxy = "",
    [string]$UvExe = "",
    [string]$NodeZip = "",
    [string]$LogDir = "",
    [switch]$AllowGitClone,
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
$script:LogDir = $null
$script:LogPath = $null
$script:TranscriptPath = $null
$script:TranscriptStarted = $false
$script:PythonMirrorSource = ""

function Write-LogLine {
    param(
        [string]$Level,
        [string]$Message
    )

    if (-not $script:LogPath) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    try {
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 -Value "[$timestamp][$Level] $Message"
    } catch {
        # Logging must never break installation.
    }
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
    Write-LogLine -Level "INFO" -Message $Message
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
    Write-LogLine -Level "OK" -Message $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
    Write-LogLine -Level "WARN" -Message $Message
}

function Invoke-Step {
    param(
        [string]$Description,
        [scriptblock]$Action
    )

    Write-Info $Description
    if ($DryRun) {
        Write-Host "       dry-run: skipped"
        Write-LogLine -Level "DRYRUN" -Message $Description
        return
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Write-LogLine -Level "STEP" -Message "BEGIN $Description"
        & $Action
        Write-LogLine -Level "STEP" -Message ("END {0} ({1:N2}s)" -f $Description, $sw.Elapsed.TotalSeconds)
    } catch {
        Write-LogLine -Level "ERROR" -Message ("FAILED {0}: {1}" -f $Description, $_.Exception.Message)
        Write-LogLine -Level "ERROR" -Message ("ScriptStackTrace: {0}" -f $_.ScriptStackTrace)
        throw
    }
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

function Redact-ForLog {
    param([string]$Value)

    if (-not $Value) {
        return "<not set>"
    }

    if ($Value -match '^[A-Za-z]:\\') {
        return $Value
    }

    if (($Value -match '://') -and ($Value -match '\s')) {
        return (($Value -split '\s+') | Where-Object { $_ } | ForEach-Object { Redact-ForLog $_ }) -join " "
    }

    try {
        $uri = [Uri]$Value
        $authority = $uri.Host
        if (-not $uri.IsDefaultPort) {
            $authority = "${authority}:$($uri.Port)"
        }
        return "$($uri.Scheme)://$authority$($uri.AbsolutePath)"
    } catch {
        if ($Value.Length -gt 80) {
            return "<set length=$($Value.Length)>"
        }
        return $Value
    }
}

function Get-ProcessEnv {
    param([string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, "Process")
}

function Set-ProcessEnvIfValue {
    param(
        [string]$Name,
        [string]$Value
    )

    if ($Value -and $Value.Trim()) {
        [Environment]::SetEnvironmentVariable($Name, $Value.Trim(), "Process")
    }
}

function Join-ConfigListValue {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    return (($Value -split "\s+") | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) -join " "
}

function Get-PipConfigCandidatePaths {
    $paths = New-Object System.Collections.Generic.List[string]

    if ($env:ProgramData) {
        $paths.Add((Join-Path $env:ProgramData "pip\pip.ini"))
    }
    if ($env:APPDATA) {
        $paths.Add((Join-Path $env:APPDATA "pip\pip.ini"))
    }
    if ($env:USERPROFILE) {
        $paths.Add((Join-Path $env:USERPROFILE "pip\pip.ini"))
        $paths.Add((Join-Path $env:USERPROFILE ".pip\pip.ini"))
    }
    if ($env:PIP_CONFIG_FILE -and $env:PIP_CONFIG_FILE.Trim()) {
        $explicit = $env:PIP_CONFIG_FILE.Trim()
        if ($explicit -notmatch '^(?i:nul)$') {
            $paths.Add((Resolve-FullPath $explicit))
        }
    }

    $seen = @{}
    foreach ($path in $paths) {
        if (-not $path) {
            continue
        }
        $full = Resolve-FullPath $path
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $full
        }
    }
}

function Read-PipConfigFile {
    param([string]$Path)

    $settings = @{}
    $section = ""
    $lastKey = ""
    $allowedSections = @("global", "install")
    $allowedKeys = @(
        "index-url",
        "extra-index-url",
        "find-links",
        "trusted-host",
        "cert",
        "client-cert",
        "proxy"
    )

    foreach ($rawLine in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $raw = [string]$rawLine
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
            continue
        }

        if ($trimmed -match '^\[(.+)\]$') {
            $section = $matches[1].Trim().ToLowerInvariant()
            $lastKey = ""
            continue
        }

        if (($allowedSections -contains $section) -and $lastKey -and ($raw -match '^\s+') -and ($allowedKeys -contains $lastKey)) {
            $settings[$lastKey] = Join-ConfigListValue (($settings[$lastKey] + " " + $trimmed).Trim())
            continue
        }

        if (($allowedSections -contains $section) -and ($trimmed -match '^([^:=\s]+)\s*[:=]\s*(.*)$')) {
            $key = $matches[1].Trim().ToLowerInvariant()
            $value = $matches[2].Trim()
            if ($allowedKeys -contains $key) {
                $settings[$key] = Join-ConfigListValue $value
                $lastKey = $key
            } else {
                $lastKey = ""
            }
        }
    }

    return $settings
}

function Get-PipConfigSettings {
    $merged = @{}
    $sources = @{}
    $loadedPaths = New-Object System.Collections.Generic.List[string]

    foreach ($path in Get-PipConfigCandidatePaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($env:PIP_CONFIG_FILE -and ((Resolve-FullPath $env:PIP_CONFIG_FILE.Trim()).ToLowerInvariant() -eq $path.ToLowerInvariant())) {
                Write-Warn "PIP_CONFIG_FILE was set but not found: $path"
            }
            continue
        }

        try {
            $settings = Read-PipConfigFile -Path $path
            if ($settings.Count -gt 0) {
                $loadedPaths.Add($path)
            }
            foreach ($key in $settings.Keys) {
                if ($settings[$key]) {
                    $merged[$key] = $settings[$key]
                    $sources[$key] = $path
                }
            }
        } catch {
            Write-Warn "Could not read pip config '$path': $($_.Exception.Message)"
        }
    }

    return @{
        Settings = $merged
        Sources = $sources
        LoadedPaths = @($loadedPaths)
    }
}

function Set-PythonPackageMirrorEnvironment {
    $pipConfig = Get-PipConfigSettings
    $settings = $pipConfig.Settings
    $sources = $pipConfig.Sources

    foreach ($path in $pipConfig.LoadedPaths) {
        Write-LogLine -Level "INFO" -Message "Loaded pip config: $path"
    }

    $indexUrl = ""
    $indexSource = ""
    if ($PypiIndexUrl.Trim()) {
        $indexUrl = $PypiIndexUrl.Trim()
        $indexSource = "-PypiIndexUrl"
    } elseif (Get-ProcessEnv "UV_DEFAULT_INDEX") {
        $indexUrl = Get-ProcessEnv "UV_DEFAULT_INDEX"
        $indexSource = "UV_DEFAULT_INDEX"
    } elseif (Get-ProcessEnv "UV_INDEX_URL") {
        $indexUrl = Get-ProcessEnv "UV_INDEX_URL"
        $indexSource = "UV_INDEX_URL"
    } elseif (Get-ProcessEnv "PIP_INDEX_URL") {
        $indexUrl = Get-ProcessEnv "PIP_INDEX_URL"
        $indexSource = "PIP_INDEX_URL"
    } elseif ($settings.ContainsKey("index-url")) {
        $indexUrl = $settings["index-url"]
        $indexSource = "pip config: $($sources['index-url'])"
    }

    if ($indexUrl) {
        Set-ProcessEnvIfValue -Name "UV_DEFAULT_INDEX" -Value $indexUrl
        Set-ProcessEnvIfValue -Name "UV_INDEX_URL" -Value $indexUrl
        Set-ProcessEnvIfValue -Name "PIP_INDEX_URL" -Value $indexUrl
        $script:PythonMirrorSource = $indexSource
        Write-Ok ("Python package index: {0} ({1})" -f (Redact-ForLog $indexUrl), $indexSource)
    } else {
        Write-Warn "No Python package mirror was detected. uv may try public PyPI unless Hermes dependencies are already cached."
    }

    $extraIndex = ""
    $extraSource = ""
    if (Get-ProcessEnv "UV_INDEX") {
        $extraIndex = Get-ProcessEnv "UV_INDEX"
        $extraSource = "UV_INDEX"
    } elseif (Get-ProcessEnv "UV_EXTRA_INDEX_URL") {
        $extraIndex = Get-ProcessEnv "UV_EXTRA_INDEX_URL"
        $extraSource = "UV_EXTRA_INDEX_URL"
    } elseif (Get-ProcessEnv "PIP_EXTRA_INDEX_URL") {
        $extraIndex = Get-ProcessEnv "PIP_EXTRA_INDEX_URL"
        $extraSource = "PIP_EXTRA_INDEX_URL"
    } elseif ($settings.ContainsKey("extra-index-url")) {
        $extraIndex = $settings["extra-index-url"]
        $extraSource = "pip config: $($sources['extra-index-url'])"
    }

    if ($extraIndex) {
        Set-ProcessEnvIfValue -Name "UV_INDEX" -Value $extraIndex
        Set-ProcessEnvIfValue -Name "UV_EXTRA_INDEX_URL" -Value $extraIndex
        Set-ProcessEnvIfValue -Name "PIP_EXTRA_INDEX_URL" -Value $extraIndex
        Write-Ok ("Python extra index: {0} ({1})" -f (Redact-ForLog $extraIndex), $extraSource)
    }

    $findLinks = ""
    if (Get-ProcessEnv "UV_FIND_LINKS") {
        $findLinks = Get-ProcessEnv "UV_FIND_LINKS"
    } elseif (Get-ProcessEnv "PIP_FIND_LINKS") {
        $findLinks = Get-ProcessEnv "PIP_FIND_LINKS"
    } elseif ($settings.ContainsKey("find-links")) {
        $findLinks = $settings["find-links"]
    }

    if ($findLinks) {
        Set-ProcessEnvIfValue -Name "UV_FIND_LINKS" -Value $findLinks
        Set-ProcessEnvIfValue -Name "PIP_FIND_LINKS" -Value $findLinks
    }

    $trustedHost = ""
    if (Get-ProcessEnv "UV_INSECURE_HOST") {
        $trustedHost = Get-ProcessEnv "UV_INSECURE_HOST"
    } elseif (Get-ProcessEnv "PIP_TRUSTED_HOST") {
        $trustedHost = Get-ProcessEnv "PIP_TRUSTED_HOST"
    } elseif ($settings.ContainsKey("trusted-host")) {
        $trustedHost = $settings["trusted-host"]
    }

    if ($trustedHost) {
        Set-ProcessEnvIfValue -Name "UV_INSECURE_HOST" -Value $trustedHost
        Set-ProcessEnvIfValue -Name "PIP_TRUSTED_HOST" -Value $trustedHost
    }

    if (-not (Get-ProcessEnv "SSL_CERT_FILE") -and $settings.ContainsKey("cert")) {
        Set-ProcessEnvIfValue -Name "SSL_CERT_FILE" -Value $settings["cert"]
        Set-ProcessEnvIfValue -Name "PIP_CERT" -Value $settings["cert"]
    }

    if (-not (Get-ProcessEnv "PIP_CLIENT_CERT") -and $settings.ContainsKey("client-cert")) {
        Set-ProcessEnvIfValue -Name "PIP_CLIENT_CERT" -Value $settings["client-cert"]
    }

    if ((-not $HttpProxy.Trim()) -and (-not $HttpsProxy.Trim()) -and $settings.ContainsKey("proxy")) {
        $pipProxy = $settings["proxy"]
        if (-not (Get-ProcessEnv "HTTP_PROXY")) {
            Set-ProcessEnvIfValue -Name "HTTP_PROXY" -Value $pipProxy
            Set-ProcessEnvIfValue -Name "http_proxy" -Value $pipProxy
        }
        if (-not (Get-ProcessEnv "HTTPS_PROXY")) {
            Set-ProcessEnvIfValue -Name "HTTPS_PROXY" -Value $pipProxy
            Set-ProcessEnvIfValue -Name "https_proxy" -Value $pipProxy
        }
    }
}

function Get-NpmConfigEnv {
    param([string]$Key)

    $envName = "npm_config_" + ($Key -replace "-", "_")
    $value = Get-ProcessEnv $envName
    if ($value) {
        return $value
    }

    $upperName = "NPM_CONFIG_" + (($Key -replace "-", "_").ToUpperInvariant())
    return Get-ProcessEnv $upperName
}

function Set-NpmConfigEnv {
    param(
        [string]$Key,
        [string]$Value
    )

    if (-not ($Value -and $Value.Trim())) {
        return
    }

    $envName = "npm_config_" + ($Key -replace "-", "_")
    Set-ProcessEnvIfValue -Name $envName -Value $Value
}

function Expand-NpmConfigValue {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    $expanded = [regex]::Replace($Value, '\$\{([^}?]+)(\?)?\}', {
        param($Match)
        $name = $Match.Groups[1].Value
        $optional = $Match.Groups[2].Success
        $envValue = [Environment]::GetEnvironmentVariable($name, "Process")
        if ($null -eq $envValue) {
            if ($optional) {
                return ""
            }
            return $Match.Value
        }
        return $envValue
    })

    return [Environment]::ExpandEnvironmentVariables($expanded).Trim()
}

function Get-NpmConfigCandidatePaths {
    param([switch]$IncludeProject)

    $items = New-Object System.Collections.Generic.List[object]

    $explicitGlobal = Get-NpmConfigEnv "globalconfig"
    if ($explicitGlobal) {
        $items.Add([pscustomobject]@{ Path = (Resolve-FullPath $explicitGlobal); Kind = "globalconfig env" })
    } else {
        if ($env:APPDATA) {
            $items.Add([pscustomobject]@{ Path = (Join-Path $env:APPDATA "npm\etc\npmrc"); Kind = "globalconfig default" })
        }
        if ($script:NodeDir) {
            $items.Add([pscustomobject]@{ Path = (Join-Path $script:NodeDir "etc\npmrc"); Kind = "managed node globalconfig" })
        }
    }

    $explicitUser = Get-NpmConfigEnv "userconfig"
    if ($explicitUser) {
        $items.Add([pscustomobject]@{ Path = (Resolve-FullPath $explicitUser); Kind = "userconfig env" })
    } elseif ($env:USERPROFILE) {
        $items.Add([pscustomobject]@{ Path = (Join-Path $env:USERPROFILE ".npmrc"); Kind = "userconfig default" })
    }

    if ($IncludeProject -and $script:InstallDir) {
        $items.Add([pscustomobject]@{ Path = (Join-Path $script:InstallDir ".npmrc"); Kind = "project config" })
    }

    $seen = @{}
    foreach ($item in $items) {
        if (-not $item.Path) {
            continue
        }
        $full = Resolve-FullPath $item.Path
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [pscustomobject]@{ Path = $full; Kind = $item.Kind }
        }
    }
}

function Read-NpmConfigFile {
    param([string]$Path)

    $settings = @{}
    $allowedKeys = @(
        "registry",
        "proxy",
        "https-proxy",
        "strict-ssl",
        "cafile",
        "userconfig",
        "globalconfig"
    )

    foreach ($rawLine in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $raw = [string]$rawLine
        $trimmed = $raw.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
            continue
        }

        if ($trimmed -match '^([^=]+?)\s*=\s*(.*)$') {
            $key = $matches[1].Trim().ToLowerInvariant()
            $value = Expand-NpmConfigValue $matches[2].Trim().Trim('"').Trim("'")
            if ($allowedKeys -contains $key) {
                $settings[$key] = $value
            }
        }
    }

    return $settings
}

function Get-NpmConfigSettings {
    param([switch]$IncludeProject)

    $merged = @{}
    $sources = @{}
    $loadedPaths = @()

    foreach ($item in Get-NpmConfigCandidatePaths -IncludeProject:$IncludeProject) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
            continue
        }

        try {
            $settings = Read-NpmConfigFile -Path $item.Path
            if ($settings.Count -gt 0) {
                $loadedPaths += $item
            }
            foreach ($key in $settings.Keys) {
                if ($settings[$key]) {
                    $merged[$key] = $settings[$key]
                    $sources[$key] = "$($item.Kind): $($item.Path)"
                }
            }
        } catch {
            Write-Warn "Could not read npm config '$($item.Path)': $($_.Exception.Message)"
        }
    }

    return @{
        Settings = $merged
        Sources = $sources
        LoadedPaths = $loadedPaths
    }
}

function Set-NodePackageMirrorEnvironment {
    param([switch]$IncludeProject)

    $npmConfig = Get-NpmConfigSettings -IncludeProject:$IncludeProject
    $settings = $npmConfig.Settings
    $sources = $npmConfig.Sources

    foreach ($item in $npmConfig.LoadedPaths) {
        Write-LogLine -Level "INFO" -Message "Loaded npm config ($($item.Kind)): $($item.Path)"
    }

    $registry = ""
    $registrySource = ""
    if ($NpmRegistry.Trim()) {
        $registry = $NpmRegistry.Trim()
        $registrySource = "-NpmRegistry"
    } elseif ($IncludeProject -and $settings.ContainsKey("registry") -and ($sources["registry"] -like "project config:*")) {
        $registry = $settings["registry"]
        $registrySource = $sources["registry"]
    } elseif (Get-NpmConfigEnv "registry") {
        $registry = Get-NpmConfigEnv "registry"
        $registrySource = "npm_config_registry"
    } elseif ($settings.ContainsKey("registry")) {
        $registry = $settings["registry"]
        $registrySource = $sources["registry"]
    }

    if ($registry) {
        Set-NpmConfigEnv -Key "registry" -Value $registry
        Write-Ok ("npm registry: {0} ({1})" -f (Redact-ForLog $registry), $registrySource)
    } elseif ($InstallNodeDeps) {
        Write-Warn "No npm registry mirror was detected. npm may try public registry.npmjs.org."
    }

    foreach ($key in @("proxy", "https-proxy", "strict-ssl", "cafile", "userconfig", "globalconfig")) {
        if ($IncludeProject -and $settings.ContainsKey($key) -and ($sources[$key] -like "project config:*")) {
            Set-NpmConfigEnv -Key $key -Value $settings[$key]
            continue
        }
        if (Get-NpmConfigEnv $key) {
            continue
        }
        if ($settings.ContainsKey($key)) {
            Set-NpmConfigEnv -Key $key -Value $settings[$key]
        }
    }

    if (-not (Get-NpmConfigEnv "userconfig")) {
        $userConfigItem = @(Get-NpmConfigCandidatePaths | Where-Object { $_.Kind -like "userconfig*" -and (Test-Path -LiteralPath $_.Path -PathType Leaf) } | Select-Object -First 1)
        if ($userConfigItem.Count -gt 0) {
            Set-NpmConfigEnv -Key "userconfig" -Value $userConfigItem[0].Path
        }
    }

    if (-not (Get-NpmConfigEnv "globalconfig")) {
        $globalConfigItem = @(Get-NpmConfigCandidatePaths | Where-Object { $_.Kind -like "*globalconfig*" -and (Test-Path -LiteralPath $_.Path -PathType Leaf) } | Select-Object -First 1)
        if ($globalConfigItem.Count -gt 0) {
            Set-NpmConfigEnv -Key "globalconfig" -Value $globalConfigItem[0].Path
        }
    }
}

function Start-InstallLog {
    if ($LogDir.Trim()) {
        $script:LogDir = Resolve-FullPath $LogDir.Trim()
    } else {
        $script:LogDir = Join-Path $script:RootPath "logs"
    }

    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    $script:LogPath = Join-Path $script:LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $script:TranscriptPath = Join-Path $script:LogDir ("install-transcript-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Write-LogLine -Level "INFO" -Message "Installer log started"
    Write-LogLine -Level "INFO" -Message "Root=$script:RootPath"
    Write-LogLine -Level "INFO" -Message "PowerShell=$($PSVersionTable.PSVersion)"
    Write-LogLine -Level "INFO" -Message "OS=$([Environment]::OSVersion.VersionString)"
    Write-LogLine -Level "INFO" -Message "ProcessArch=$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"

    try {
        Start-Transcript -LiteralPath $script:TranscriptPath -Append | Out-Null
        $script:TranscriptStarted = $true
    } catch {
        Write-LogLine -Level "WARN" -Message ("Start-Transcript failed: {0}" -f $_.Exception.Message)
    }
}

function Stop-InstallLog {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            # Ignore transcript shutdown failures.
        }
        $script:TranscriptStarted = $false
    }
}

function Write-EnvironmentDiagnostics {
    Write-LogLine -Level "INFO" -Message "Diagnostics: env snapshot begins"
    foreach ($name in @(
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "UV_DEFAULT_INDEX", "UV_INDEX_URL", "UV_INDEX", "UV_EXTRA_INDEX_URL",
        "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "UV_FIND_LINKS", "PIP_FIND_LINKS",
        "UV_INSECURE_HOST", "PIP_TRUSTED_HOST", "SSL_CERT_FILE", "PIP_CERT", "PIP_CONFIG_FILE",
        "UV_PYTHON_INSTALL_MIRROR",
        "npm_config_registry", "npm_config_proxy", "npm_config_https_proxy",
        "npm_config_strict_ssl", "npm_config_cafile", "npm_config_userconfig", "npm_config_globalconfig",
        "HERMES_HOME", "UV_CACHE_DIR", "TERMINAL_CWD"
    )) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ($name -match "KEY|TOKEN|SECRET|PASSWORD") {
            $display = if ($value) { "<set length=$($value.Length)>" } else { "<not set>" }
        } else {
            $display = Redact-ForLog $value
        }
        Write-LogLine -Level "INFO" -Message ("ENV {0}={1}" -f $name, $display)
    }
    if ($script:PythonMirrorSource) {
        Write-LogLine -Level "INFO" -Message ("PythonMirrorSource={0}" -f $script:PythonMirrorSource)
    }
    Write-LogLine -Level "INFO" -Message ("PATH contains root: {0}" -f ($env:PATH -like "*$script:RootPath*"))
    Write-LogLine -Level "INFO" -Message "Diagnostics: env snapshot ends"
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

    if ($PythonInstallMirror.Trim()) {
        $env:UV_PYTHON_INSTALL_MIRROR = $PythonInstallMirror.Trim()
    }

    if ($HttpProxy.Trim()) {
        $proxy = $HttpProxy.Trim()
        $env:HTTP_PROXY = $proxy
        $env:http_proxy = $proxy
        $env:npm_config_proxy = $proxy
    }

    if ($HttpsProxy.Trim()) {
        $proxy = $HttpsProxy.Trim()
        $env:HTTPS_PROXY = $proxy
        $env:https_proxy = $proxy
        $env:npm_config_https_proxy = $proxy
    }

    if ($NoProxy.Trim()) {
        $noProxyValue = $NoProxy.Trim()
        $env:NO_PROXY = $noProxyValue
        $env:no_proxy = $noProxyValue
    }

    Set-PythonPackageMirrorEnvironment
    Set-NodePackageMirrorEnvironment

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
        throw "git.exe not found on PATH. Pass -SourcePath or -SourceZip for manual source install, or install Git separately. This installer will not install Git globally."
    }
    $script:GitCmd = $found
    Write-Ok "git: $(& $script:GitCmd --version)"
}

function Find-GitBash {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($script:GitCmd) {
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

function Move-PartialInstallDirAside {
    $safeInstallDir = Assert-UnderRoot $script:InstallDir "partial InstallDir"
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $archiveDir = Join-Path $script:AppDir "hermes-agent.partial-$timestamp"
    $suffix = 1
    while (Test-Path -LiteralPath $archiveDir) {
        $archiveDir = Join-Path $script:AppDir "hermes-agent.partial-$timestamp-$suffix"
        $suffix++
    }
    [void](Assert-UnderRoot $archiveDir "partial InstallDir archive")

    Write-Warn "InstallDir exists but is not a reusable Hermes source tree. Moving it aside for retry:"
    Write-Warn "  from: $safeInstallDir"
    Write-Warn "  to:   $archiveDir"
    Rename-Item -LiteralPath $safeInstallDir -NewName (Split-Path $archiveDir -Leaf) -Force
}

function Test-LocalSourceRequested {
    return [bool]($SourcePath.Trim() -or $SourceZip.Trim())
}

function Test-HermesSourceDir {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $pyproject = Join-Path $Path "pyproject.toml"
    if (-not (Test-Path -LiteralPath $pyproject -PathType Leaf)) {
        return $false
    }

    if (Test-Path -LiteralPath (Join-Path $Path "hermes_cli") -PathType Container) {
        return $true
    }

    if (Test-Path -LiteralPath (Join-Path $Path "agent") -PathType Container) {
        return $true
    }

    return $false
}

function Find-HermesSourceDir {
    param([string]$Root)

    $rootFull = Resolve-FullPath $Root
    if (Test-HermesSourceDir $rootFull) {
        return $rootFull
    }

    $directChildren = @(Get-ChildItem -LiteralPath $rootFull -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($child in $directChildren) {
        if (Test-HermesSourceDir $child.FullName) {
            return $child.FullName
        }
    }

    $pyprojects = @(Get-ChildItem -LiteralPath $rootFull -Recurse -Filter "pyproject.toml" -File -ErrorAction SilentlyContinue | Select-Object -First 25)
    foreach ($pyproject in $pyprojects) {
        if (Test-HermesSourceDir $pyproject.DirectoryName) {
            return $pyproject.DirectoryName
        }
    }

    return $null
}

function Resolve-LocalSourceDir {
    if ($SourcePath.Trim() -and $SourceZip.Trim()) {
        throw "Pass only one source option: -SourcePath or -SourceZip."
    }

    if ($SourcePath.Trim()) {
        $sourceRoot = Resolve-FullPath $SourcePath.Trim()
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            throw "SourcePath is not a directory: $sourceRoot"
        }
        $sourceDir = Find-HermesSourceDir $sourceRoot
        if (-not $sourceDir) {
            throw "SourcePath does not look like a Hermes Agent source tree. Expected pyproject.toml plus hermes_cli or agent under: $sourceRoot"
        }
        return $sourceDir
    }

    if ($SourceZip.Trim()) {
        $zipPath = Resolve-FullPath $SourceZip.Trim()
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            throw "SourceZip not found: $zipPath"
        }

        $extractRoot = Join-Path $script:RuntimeDir "source-extract"
        if (Test-Path -LiteralPath $extractRoot) {
            $safeExtract = Assert-UnderRoot $extractRoot "source extract dir"
            Remove-Item -LiteralPath $safeExtract -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

        $sourceDir = Find-HermesSourceDir $extractRoot
        if (-not $sourceDir) {
            throw "SourceZip did not contain a recognizable Hermes Agent source tree: $zipPath"
        }
        return $sourceDir
    }

    return $null
}

function Copy-HermesSourceTree {
    param([string]$SourceDir)

    $sourceFull = Resolve-FullPath $SourceDir
    $installFull = Resolve-FullPath $script:InstallDir
    if ($sourceFull.TrimEnd('\').ToLowerInvariant() -eq $installFull.TrimEnd('\').ToLowerInvariant()) {
        Write-Ok "Source already present at $script:InstallDir"
        return
    }

    New-Item -ItemType Directory -Force -Path $script:InstallDir | Out-Null
    $skipNames = @(".git", ".hg", ".svn", ".venv", "venv", "node_modules", "__pycache__", "hermes_agent.egg-info")
    Get-ChildItem -LiteralPath $sourceFull -Force | Where-Object { $skipNames -notcontains $_.Name } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $script:InstallDir -Recurse -Force
    }
}

function Install-SourceFromLocal {
    $sourceDir = Resolve-LocalSourceDir
    Write-Info "Using local Hermes Agent source: $sourceDir"

    if (Test-Path -LiteralPath $script:InstallDir) {
        if (Test-HermesSourceDir $script:InstallDir) {
            Write-Ok "Hermes source already exists: $script:InstallDir"
            return
        }

        $existing = Get-ChildItem -LiteralPath $script:InstallDir -Force -ErrorAction SilentlyContinue
        if ($existing) {
            Move-PartialInstallDirAside
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $script:InstallDir -Parent) | Out-Null
    Copy-HermesSourceTree -SourceDir $sourceDir

    if (-not (Test-HermesSourceDir $script:InstallDir)) {
        throw "Local source copy did not produce a valid Hermes Agent source tree at $script:InstallDir"
    }
    Write-Ok "Hermes source ready at $script:InstallDir"
}

function Update-Repository {
    if (Test-LocalSourceRequested) {
        Install-SourceFromLocal
        return
    }

    if (-not $AllowGitClone) {
        throw "Local source is required. Download Hermes Agent source zip manually, then pass -SourceZip or -SourcePath. To use git explicitly, rerun with -AllowGitClone."
    }

    if (-not $script:GitCmd) {
        throw "git.exe is required when -AllowGitClone is used without -SourcePath or -SourceZip."
    }

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
            Move-PartialInstallDirAside
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

    Set-NodePackageMirrorEnvironment -IncludeProject
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
`$LauncherLogDir = Join-Path `$HermesHome 'logs'
`$LauncherLogPath = Join-Path `$LauncherLogDir ("launcher-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

function Write-HermesLauncherLog {
    param(
        [string]`$Level,
        [string]`$Message
    )

    try {
        if (-not (Test-Path -LiteralPath `$LauncherLogDir)) {
            New-Item -ItemType Directory -Force -Path `$LauncherLogDir | Out-Null
        }
        `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        Add-Content -LiteralPath `$LauncherLogPath -Encoding UTF8 -Value "[`$timestamp][`$Level] `$Message"
    } catch {
        # Launcher logging must never block Hermes startup.
    }
}

function Redact-HermesLauncherValue {
    param([string]`$Value)

    if (-not `$Value) {
        return '<not set>'
    }

    if (`$Value -match '^[A-Za-z]:\\') {
        return `$Value
    }

    try {
        `$uri = [Uri]`$Value
        `$authority = `$uri.Host
        if (-not `$uri.IsDefaultPort) {
            `$authority = "`${authority}:`$(`$uri.Port)"
        }
        return "`$(`$uri.Scheme)://`$authority`$(`$uri.AbsolutePath)"
    } catch {
        if (`$Value.Length -gt 80) {
            return "<set length=`$(`$Value.Length)>"
        }
        return `$Value
    }
}

trap {
    Write-HermesLauncherLog -Level 'ERROR' -Message ("Unhandled launcher error: {0}" -f `$_.Exception.Message)
    Write-HermesLauncherLog -Level 'ERROR' -Message ("ScriptStackTrace: {0}" -f `$_.ScriptStackTrace)
    Write-Host "[FAIL] `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host "Launcher log: `$LauncherLogPath" -ForegroundColor Yellow
    exit 1
}

Write-HermesLauncherLog -Level 'INFO' -Message 'Launcher started'
Write-HermesLauncherLog -Level 'INFO' -Message "Root=`$Root"
Write-HermesLauncherLog -Level 'INFO' -Message "InstallDir=`$InstallDir"
Write-HermesLauncherLog -Level 'INFO' -Message "HermesHome=`$HermesHome"
Write-HermesLauncherLog -Level 'INFO' -Message "HermesExe=`$HermesExe exists=`$(Test-Path -LiteralPath `$HermesExe)"
Write-HermesLauncherLog -Level 'INFO' -Message "ArgsCount=`$(`$ArgsToHermes.Count)"
Write-HermesLauncherLog -Level 'INFO' -Message "PowerShell=`$(`$PSVersionTable.PSVersion)"
Write-HermesLauncherLog -Level 'INFO' -Message "OS=`$([Environment]::OSVersion.VersionString)"
Write-HermesLauncherLog -Level 'INFO' -Message "ProcessArch=`$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"

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

    $launcher += @'

function Find-HermesGitBash {
    $candidates = New-Object System.Collections.Generic.List[string]

    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $gitExeDir = Split-Path $gitCmd.Source -Parent
        if ($gitExeDir) {
            $maybeRoot = Split-Path $gitExeDir -Parent
            if ($maybeRoot) {
                $candidates.Add((Join-Path $maybeRoot 'bin\bash.exe'))
                $candidates.Add((Join-Path $maybeRoot 'usr\bin\bash.exe'))
            }
        }
    }

    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($pf86) {
        $candidates.Add((Join-Path $pf86 'Git\bin\bash.exe'))
    }
    if ($env:LocalAppData) {
        $candidates.Add((Join-Path $env:LocalAppData 'Programs\Git\bin\bash.exe'))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }
    return $null
}

$GitBashPath = Find-HermesGitBash
if ($GitBashPath) {
    $env:HERMES_GIT_BASH_PATH = $GitBashPath
}

Write-HermesLauncherLog -Level 'INFO' -Message "GitBashPath=$(if ($GitBashPath) { $GitBashPath } else { '<not found>' })"
'@

    $launcher += @"

if (Test-Path -LiteralPath (Join-Path `$NodeDir 'node.exe')) {
    `$env:PATH = "`$VenvScripts;`$NodeDir;`$env:PATH"
} else {
    `$env:PATH = "`$VenvScripts;`$env:PATH"
}

foreach (`$name in @(
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
    'HERMES_HOME', 'UV_CACHE_DIR', 'TERMINAL_CWD', 'HERMES_GIT_BASH_PATH'
)) {
    `$value = [Environment]::GetEnvironmentVariable(`$name, 'Process')
    Write-HermesLauncherLog -Level 'INFO' -Message ("ENV {0}={1}" -f `$name, (Redact-HermesLauncherValue `$value))
}

`$pathContainsRoot = `$env:PATH -like "*`$Root*"
Write-HermesLauncherLog -Level 'INFO' -Message "PATH contains root: `$pathContainsRoot"
Write-HermesLauncherLog -Level 'INFO' -Message "Hermes process starting"
& `$HermesExe @ArgsToHermes
`$exitCode = `$LASTEXITCODE
Write-HermesLauncherLog -Level 'INFO' -Message "Hermes process exited with code `$exitCode"
if (`$exitCode -ne 0) {
    Write-Host "Launcher log: `$LauncherLogPath" -ForegroundColor Yellow
}
exit `$exitCode
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
    Start-InstallLog
    $localSourceMode = Test-LocalSourceRequested

    Write-Host ""
    Write-Host "Hermes Agent native Windows isolated installer" -ForegroundColor Magenta
    Write-Host "Root:       $script:RootPath"
    if ($localSourceMode) {
        Write-Host "Source:     local"
        if ($SourcePath.Trim()) {
            Write-Host "SourcePath: $($SourcePath.Trim())"
        }
        if ($SourceZip.Trim()) {
            Write-Host "SourceZip:  $($SourceZip.Trim())"
        }
    } else {
        Write-Host "Source:     missing local source"
        Write-Host "Git clone:  $(if ($AllowGitClone) { 'enabled' } else { 'disabled' })"
        if ($AllowGitClone) {
            Write-Host "Repo:       $RepoUrl"
            Write-Host "Branch/tag: $Branch"
        }
    }
    Write-Host "Log:        $script:LogPath"
    Write-Host "Transcript: $script:TranscriptPath"
    Write-Host ""
    Write-LogLine -Level "INFO" -Message ("LocalSourceMode={0}" -f $localSourceMode)
    if ($SourcePath.Trim()) {
        Write-LogLine -Level "INFO" -Message ("SourcePath={0}" -f (Resolve-FullPath $SourcePath.Trim()))
    }
    if ($SourceZip.Trim()) {
        Write-LogLine -Level "INFO" -Message ("SourceZip={0}" -f (Resolve-FullPath $SourceZip.Trim()))
    }

    Invoke-Step "Creating local directory layout" { New-DirectoryLayout }
    Invoke-Step "Setting process-local environment" { Set-ProcessOnlyEnvironment }
    Invoke-Step "Writing diagnostic environment snapshot" { Write-EnvironmentDiagnostics }
    Invoke-Step "Checking uv" { Ensure-Uv }
    if ($localSourceMode -or (-not $AllowGitClone)) {
        Invoke-Step "Checking Git Bash for terminal support (optional)" { Find-GitBash }
    } else {
        Invoke-Step "Checking git" { Ensure-Git; Find-GitBash }
    }
    Invoke-Step "Preparing hermes-agent source tree" { Update-Repository }
    Invoke-Step "Creating isolated Python virtual environment" { Ensure-Venv }
    Invoke-Step "Installing Python dependencies into local venv" { Install-PythonDependencies }
    Invoke-Step "Installing optional Node dependencies" { Install-NodeDependencies }
    Invoke-Step "Patching Hermes Windows local backend" { Patch-WindowsHermesLocalBackend }
    Invoke-Step "Creating local Hermes config templates" { Copy-ConfigTemplates }
    Invoke-Step "Writing process-local launcher" { Write-Launcher }
    Invoke-Step "Verifying Hermes executable" { Test-Install }

    Write-Host ""
    if ($DryRun) {
        Write-Ok "Dry-run complete. No install files were changed; diagnostic logs were written."
        Write-Host "Install log: $script:LogPath"
        Write-Host "Transcript:  $script:TranscriptPath"
    } else {
        Write-Ok "Hermes isolated install complete"
        Write-Host ""
        Write-Host "Run:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script:BinDir\hermes-corp.ps1`" --version"
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$script:BinDir\hermes-corp.ps1`""
        Write-Host ""
        Write-Host "Nothing was written to User/Machine PATH or User/Machine HERMES_HOME."
        Write-Host "Install log: $script:LogPath"
        Write-Host "Transcript:  $script:TranscriptPath"
    }
}

try {
    Main
} catch {
    Write-LogLine -Level "ERROR" -Message ("Installer failed: {0}" -f $_.Exception.Message)
    Write-LogLine -Level "ERROR" -Message ("ScriptStackTrace: {0}" -f $_.ScriptStackTrace)
    Write-Host ""
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    if ($script:LogPath) {
        Write-Host "Log: $script:LogPath" -ForegroundColor Yellow
        Write-Host "Transcript: $script:TranscriptPath" -ForegroundColor Yellow
    }
    Write-Host ""
    Stop-InstallLog
    exit 1
} finally {
    Stop-InstallLog
}
