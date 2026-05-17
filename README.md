# Hermes Windows Isolated Installer

[中文说明](README.zh-CN.md)

Enterprise-friendly native Windows installer for [Hermes Agent](https://github.com/NousResearch/hermes-agent): uv-based, no WSL, isolated runtime, and no global environment changes.

This project provides a small PowerShell bootstrapper for installing Hermes Agent on Windows while keeping Python, uv cache, optional Node runtime, Hermes config, and launch-time environment variables under one local directory.

## Why This Exists

The upstream Hermes Windows installer is useful, but enterprise desktops often need stricter behavior:

- Do not write User or Machine `PATH`
- Do not write global `HERMES_HOME`
- Do not install into system Python
- Do not rely on system Node
- Do not run `winget`, `choco`, or `scoop`
- Do not run `git config --global`
- Allow manual GitHub source downloads while keeping runtime dependencies isolated

This installer follows that model. It uses the current PowerShell directory as the install root by default.

## What It Installs

By default, running the installer from a target folder creates:

```text
<target-root>\
  app\hermes-agent\          # Hermes Agent source copy
  app\hermes-agent\venv\     # Local Python virtual environment
  home\                      # Local HERMES_HOME
  runtime\                   # Local managed runtimes, if provided
  uv-cache\                  # Local uv cache
  bin\hermes-corp.ps1        # Process-local launcher
```

The generated launcher sets `HERMES_HOME`, `PATH`, uv variables, and optional Node paths only for the current process. It does not persist them globally.

## Prerequisites

Required:

- Windows 10 or Windows 11
- PowerShell 5.1+
- uv available on `PATH`, or passed with `-UvExe`
- Hermes Agent source zip downloaded from GitHub, or an extracted Hermes Agent source directory

Optional:

- Git for Windows, only if you explicitly pass `-AllowGitClone` for fallback `git clone` mode
- Git Bash for Hermes terminal features, and for `-UseGitBashForGit` when PowerShell git cannot clone but Git Bash can
- Internal PyPI mirror
- Internal Python standalone mirror for uv
- Internal npm registry
- Node 22 zip package, only if you need Node-based Hermes features

## Quick Start

Download Hermes Agent source manually first. This avoids `git clone` failures on managed desktops.

1. Open [NousResearch/hermes-agent v2026.5.7](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.5.7) in a browser.
2. Download the source zip, or use the direct archive URL: [v2026.5.7.zip](https://github.com/NousResearch/hermes-agent/archive/refs/tags/v2026.5.7.zip).
3. Keep the zip as-is, or extract it to a local folder.

Then create or choose an install folder and run the installer from that folder:

```powershell
mkdir D:\tools\hermes
cd D:\tools\hermes

powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
```

If you already extracted the zip, pass the extracted source folder instead:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourcePath C:\downloads\hermes-agent-2026.5.7
```

If PowerShell reports that the script is not digitally signed, use the CMD wrapper instead:

```cmd
C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.cmd -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
```

The CMD wrapper starts PowerShell with process-local `-ExecutionPolicy Bypass` and does not change system policy. If your enterprise enforces `AllSigned` through Group Policy, use your enterprise code-signing certificate to sign the `.ps1` files instead; Group Policy cannot be overridden by this wrapper.

After installation:

```powershell
.\bin\hermes-corp.ps1 --version
.\bin\hermes-corp.ps1 doctor
.\bin\hermes-corp.ps1
```

## Enterprise Mirror Example

If your environment uses internal package mirrors:

```powershell
cd D:\tools\hermes

powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip `
  -PypiIndexUrl https://pypi.corp/simple `
  -PythonInstallMirror https://artifacts.corp/astral/python-build-standalone
```

If the machine already has a pip mirror configured through `PIP_CONFIG_FILE`, `%APPDATA%\pip\pip.ini`, or `%PROGRAMDATA%\pip\pip.ini`, you can omit `-PypiIndexUrl`. The installer converts pip config into process-local `UV_DEFAULT_INDEX`, `UV_INDEX_URL`, and `PIP_INDEX_URL`; `extra-index-url` becomes `UV_INDEX`, `UV_EXTRA_INDEX_URL`, and `PIP_EXTRA_INDEX_URL`. These variables are scoped to the installer process and are not written globally.

Note: pip mirrors only affect Python package downloads. They do not affect uv managed Python downloads. In an offline or proxy-only enterprise environment, also pass `-PythonInstallMirror` or pre-seed Python/uv cache.

If you need npm for optional Node-based features:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip `
  -NpmRegistry https://npm.corp/repository/npm/ `
  -InstallNodeDeps `
  -NodeZip C:\artifacts\node-v22.x.x-win-x64.zip
```

Without `-InstallNodeDeps`, the installer skips Node dependencies and does not use system Node.

If the machine already has an npm mirror configured through `NPM_CONFIG_USERCONFIG`, `%USERPROFILE%\.npmrc`, or `%APPDATA%\npm\etc\npmrc`, you can omit `-NpmRegistry`. The installer reads `registry`, `proxy`, `https-proxy`, `strict-ssl`, and `cafile` from `.npmrc` and maps them to process-local `npm_config_*` variables. It reads `app\hermes-agent\.npmrc` again after source preparation and before optional Node dependency installation. The installer does not write global npm config.

## Parameters

Main wrapper:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 [options]
```

Options are forwarded to `scripts\install-hermes-corp-windows.ps1`.

| Parameter | Default | Description |
| --- | --- | --- |
| `-Root` | Current PowerShell directory | Install root. Leave empty to install into the directory you `cd` into. |
| `-SourcePath` | Empty | Local Hermes Agent source directory, or a parent folder containing the extracted source directory. Preferred when `git clone` is blocked. |
| `-SourceZip` | Empty | Local Hermes Agent source zip. The installer extracts it under `runtime\source-extract` and copies the source into `app\hermes-agent`. |
| `-AllowGitClone` | Off | Explicitly allow fallback `git clone`. Off by default; manual source zip is recommended. |
| `-UseGitBashForGit` | Off | Run fallback git operations through Git Bash. Use this when manual `git clone` works in Git Bash but fails from PowerShell. |
| `-RepoUrl` | `https://github.com/NousResearch/hermes-agent.git` | Fallback git repository URL, used only with `-AllowGitClone` when neither `-SourcePath` nor `-SourceZip` is provided. |
| `-Branch` | `v2026.5.7` | Fallback branch or tag. `v2026.5.7` corresponds to the v0.13.0-era Windows Native release. |
| `-PythonVersion` | `3.11` | Python version for the local uv-managed venv. |
| `-NodeMajorVersion` | `22` | Local managed Node folder name, used only with `-InstallNodeDeps`. |
| `-PypiIndexUrl` | Empty | Internal PyPI/simple index URL for uv and pip. If empty, the installer tries to read local pip config. |
| `-NpmRegistry` | Empty | Internal npm registry URL. If empty, the installer tries to read local `.npmrc`. |
| `-PythonInstallMirror` | Empty | uv Python install mirror. |
| `-HttpProxy` | Empty | Process-local HTTP proxy used by git, uv, pip and npm during install. |
| `-HttpsProxy` | Empty | Process-local HTTPS proxy used by git, uv, pip and npm during install. |
| `-NoProxy` | Empty | Process-local no-proxy list. |
| `-UvExe` | Empty | Explicit path to `uv.exe`. |
| `-NodeZip` | Empty | Node Windows zip to unpack into `runtime\node22`. |
| `-LogDir` | `<install-root>\logs` | Installer diagnostic log directory. |
| `-InstallNodeDeps` | Off | Install optional Node dependencies using local managed Node. |
| `-ForceRecreateVenv` | Off | Delete and recreate the local venv under the install root. |
| `-SkipDependencyInstall` | Off | Create layout and venv but skip Python dependency installation. Useful for tests. |
| `-SkipConfigTemplate` | Off | Do not create starter `home\.env`, `home\config.yaml`, or `home\SOUL.md`. |
| `-DryRun` | Off | Print planned steps without changing install files. Diagnostic logs are still written. |

## Configuration

The installer creates starter files under `<target-root>\home`:

```text
home\.env
home\config.yaml
home\SOUL.md
```

The generated `config.yaml` is a template. Edit it to point at your internal model gateway and MCP servers:

```yaml
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
```

Keep secrets in `home\.env`:

```dotenv
CORP_LLM_API_KEY=
NO_PROXY=.corp.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1
```

## Logs

The installer writes diagnostics to:

```text
logs\install-YYYYMMDD-HHMMSS.log
logs\install-transcript-YYYYMMDD-HHMMSS.log
```

The generated launcher writes startup diagnostics to:

```text
home\logs\launcher-YYYYMMDD.log
```

The launcher log records resolved paths, Git Bash detection, proxy variable presence, and the Hermes exit code. It does not record prompts or API key values.

## Re-running

The installer is safe to run again after a failed install. In local source mode, if a previous run left a partial non-source folder at `app\hermes-agent`, the next run moves it to `app\hermes-agent.partial-YYYYMMDD-HHMMSS` and copies the local source again. If a valid Hermes source tree already exists, it is reused.

If you do not pass `-SourcePath` or `-SourceZip`, the installer stops with a manual-source error. It falls back to git mode only when you explicitly pass `-AllowGitClone`. In that mode, a valid git checkout is updated with `fetch`, `checkout`, and submodule sync.

When users can clone successfully from Git Bash but the installer fails during PowerShell git calls, rerun with Git Bash git mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 `
  -AllowGitClone `
  -UseGitBashForGit
```

This runs `git clone`, `fetch`, `checkout`, `pull`, and `submodule update` through Git Bash without writing global Git config.

## Validate The Installer

Run a dry run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 -DryRun -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
```

Run the local sandbox test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-install-hermes-corp-sandbox.ps1
```

The sandbox test uses a fake local source tree and fake `uv` command to validate installer flow without git clone, network access, or dependency downloads.

Before giving this to end users, also run at least one real install test on a clean Windows VM:

```powershell
mkdir D:\hermes-test
cd D:\hermes-test
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
.\bin\hermes-corp.ps1 --version
.\bin\hermes-corp.ps1 doctor
```

## Uninstall

Use the bundled uninstaller from the install root:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1
```

If PowerShell script execution is blocked, use the CMD wrapper:

```cmd
uninstall-hermes-corp.cmd -DryRun
uninstall-hermes-corp.cmd
```

By default it removes generated code/runtime folders and keeps `home`, matching the upstream Hermes uninstall behavior of preserving user config for reinstall.

To remove local config, auth, sessions, skills and logs as well:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1 -RemoveHome
```

For a fuller cleanup pass that also checks process, Startup shortcut, scheduled task, and User environment entries under this install root:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1 -StopProcesses -CleanUserEnvironment -RemoveHome
```

## Notes

- Git is optional. This project does not install Git globally. The installer does not run `git clone` by default; pass `-AllowGitClone` to opt into git fallback. If PowerShell git is blocked but Git Bash works, add `-UseGitBashForGit`; use `-SourcePath` or `-SourceZip` when `git clone` is fully blocked.
- Git Bash is still recommended for Hermes terminal features. If it is installed in a standard location, the launcher detects it automatically.
- In fallback git mode, the installer sets Git's `windows.appendAtomically=false` via process-local environment variables to avoid Windows lock-file issues without running `git config --global`.
- Node is intentionally opt-in. Pass `-InstallNodeDeps` and `-NodeZip` when you need Node-based features.
- This project is not an official Hermes Agent project.
