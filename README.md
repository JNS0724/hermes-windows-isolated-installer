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
- Allow GitHub source access while keeping runtime dependencies isolated

This installer follows that model. It uses the current PowerShell directory as the install root by default.

## What It Installs

By default, running the installer from a target folder creates:

```text
<target-root>\
  app\hermes-agent\          # Hermes Agent source checkout
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
- Git available on `PATH`
- uv available on `PATH`, or passed with `-UvExe`
- Network access to `https://github.com/NousResearch/hermes-agent.git`

Optional:

- Internal PyPI mirror
- Internal Python standalone mirror for uv
- Internal npm registry
- Node 22 zip package, only if you need Node-based Hermes features

## Quick Start

Create or choose an install folder, then run the installer from that folder:

```powershell
mkdir D:\tools\hermes
cd D:\tools\hermes

powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1
```

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
  -PypiIndexUrl https://pypi.corp/simple `
  -PythonInstallMirror https://artifacts.corp/astral/python-build-standalone
```

If you need npm for optional Node-based features:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -NpmRegistry https://npm.corp/repository/npm/ `
  -InstallNodeDeps `
  -NodeZip C:\artifacts\node-v22.x.x-win-x64.zip
```

Without `-InstallNodeDeps`, the installer skips Node dependencies and does not use system Node.

## Parameters

Main wrapper:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 [options]
```

Options are forwarded to `scripts\install-hermes-corp-windows.ps1`.

| Parameter | Default | Description |
| --- | --- | --- |
| `-Root` | Current PowerShell directory | Install root. Leave empty to install into the directory you `cd` into. |
| `-RepoUrl` | `https://github.com/NousResearch/hermes-agent.git` | Hermes Agent repository URL. |
| `-Branch` | `v2026.5.7` | Hermes Agent branch or tag. `v2026.5.7` corresponds to the v0.13.0-era Windows Native release. |
| `-PythonVersion` | `3.11` | Python version for the local uv-managed venv. |
| `-NodeMajorVersion` | `22` | Local managed Node folder name, used only with `-InstallNodeDeps`. |
| `-PypiIndexUrl` | Empty | Internal PyPI/simple index URL for uv and pip. |
| `-NpmRegistry` | Empty | Internal npm registry URL. |
| `-PythonInstallMirror` | Empty | uv Python install mirror. |
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

## Validate The Installer

Run a dry run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 -DryRun
```

Run the local sandbox test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-install-hermes-corp-sandbox.ps1
```

The sandbox test uses fake `git` and fake `uv` commands to validate installer flow without network access or dependency downloads.

Before giving this to end users, also run at least one real install test on a clean Windows VM:

```powershell
mkdir D:\hermes-test
cd D:\hermes-test
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1
.\bin\hermes-corp.ps1 --version
.\bin\hermes-corp.ps1 doctor
```

## Uninstall

Use the bundled uninstaller from the install root:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1
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

- Git is intentionally treated as a prerequisite. This project does not install Git globally.
- The installer sets Git's `windows.appendAtomically=false` via process-local environment variables to avoid Windows lock-file issues without running `git config --global`.
- Node is intentionally opt-in. Pass `-InstallNodeDeps` and `-NodeZip` when you need Node-based features.
- This project is not an official Hermes Agent project.
