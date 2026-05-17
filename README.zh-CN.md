# Hermes Windows 隔离安装器

这是一个面向企业 Windows 环境的 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 原生安装脚本：基于 uv，不依赖 WSL，运行时隔离，不污染本机全局环境。

本仓库提供一个小型 PowerShell 启动器，用来在 Windows 上安装 Hermes Agent，并把 Python 虚拟环境、uv 缓存、可选 Node 运行时、Hermes 配置和启动时环境变量都限制在一个本地目录内。

[English README](README.md)

## 为什么需要这个脚本

官方 Hermes Windows 安装脚本可以工作，但企业桌面通常有更严格的要求：

- 不写入 User 或 Machine 级 `PATH`
- 不写入全局 `HERMES_HOME`
- 不把依赖安装到系统 Python
- 不依赖系统 Node
- 不运行 `winget`、`choco` 或 `scoop`
- 不运行 `git config --global`
- 允许访问 GitHub 拉取源码，但运行时依赖保持隔离

本安装器按这个思路设计。默认情况下，它把运行 PowerShell 命令时所在的当前目录作为安装根目录。

## 安装后目录结构

在目标目录执行安装后，会生成类似结构：

```text
<目标目录>\
  app\hermes-agent\          # Hermes Agent 源码
  app\hermes-agent\venv\     # 本地 Python 虚拟环境
  home\                      # 本地 HERMES_HOME
  runtime\                   # 本地托管运行时，可选
  uv-cache\                  # 本地 uv 缓存
  bin\hermes-corp.ps1        # 隔离启动入口
```

生成的 `bin\hermes-corp.ps1` 只在当前进程里设置 `HERMES_HOME`、`PATH`、uv 变量和可选 Node 路径，不会持久写入系统或用户环境变量。

## 前置要求

必需：

- Windows 10 或 Windows 11
- PowerShell 5.1+
- `git` 已在 `PATH` 中可用
- `uv` 已在 `PATH` 中可用，或通过 `-UvExe` 指定
- 可以访问 `https://github.com/NousResearch/hermes-agent.git`

可选：

- 企业内网 PyPI 镜像
- uv Python standalone 内网镜像
- 企业内网 npm registry
- Node 22 Windows zip 包，仅当你需要 Node 相关 Hermes 功能时使用

## 快速开始

先创建或选择一个安装目录，然后从这个目录里运行安装脚本：

```powershell
mkdir D:\tools\hermes
cd D:\tools\hermes

powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1
```

安装完成后：

```powershell
.\bin\hermes-corp.ps1 --version
.\bin\hermes-corp.ps1 doctor
.\bin\hermes-corp.ps1
```

## 企业内网镜像示例

如果企业环境使用内网 Python 包镜像：

```powershell
cd D:\tools\hermes

powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -PypiIndexUrl https://pypi.corp/simple `
  -PythonInstallMirror https://artifacts.corp/astral/python-build-standalone
```

如果需要 npm 支持可选 Node 功能：

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -NpmRegistry https://npm.corp/repository/npm/ `
  -InstallNodeDeps `
  -NodeZip C:\artifacts\node-v22.x.x-win-x64.zip
```

默认不传 `-InstallNodeDeps` 时，脚本会跳过 Node 依赖，也不会使用系统 Node。

## 参数说明

主入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 [options]
```

参数会转发给 `scripts\install-hermes-corp-windows.ps1`。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Root` | 当前 PowerShell 目录 | 安装根目录。留空时安装到你 `cd` 进入的目录。 |
| `-RepoUrl` | `https://github.com/NousResearch/hermes-agent.git` | Hermes Agent 仓库地址。 |
| `-Branch` | `v2026.5.7` | Hermes Agent 分支或 tag。`v2026.5.7` 对应 v0.13.0 附近的 Windows Native 版本。 |
| `-PythonVersion` | `3.11` | 本地 uv 虚拟环境使用的 Python 版本。 |
| `-NodeMajorVersion` | `22` | 本地托管 Node 目录名，仅在 `-InstallNodeDeps` 时使用。 |
| `-PypiIndexUrl` | 空 | uv 和 pip 使用的 PyPI/simple 镜像地址。 |
| `-NpmRegistry` | 空 | npm registry 地址。 |
| `-PythonInstallMirror` | 空 | uv Python 安装镜像地址。 |
| `-UvExe` | 空 | 显式指定 `uv.exe` 路径。 |
| `-NodeZip` | 空 | Node Windows zip 包，会解压到 `runtime\node22`。 |
| `-InstallNodeDeps` | 关闭 | 使用本地托管 Node 安装可选 Node 依赖。 |
| `-ForceRecreateVenv` | 关闭 | 删除并重建安装目录下的本地 venv。 |
| `-SkipDependencyInstall` | 关闭 | 创建目录和 venv，但跳过 Python 依赖安装，主要用于测试。 |
| `-SkipConfigTemplate` | 关闭 | 不创建 `home\.env`、`home\config.yaml`、`home\SOUL.md` 模板。 |
| `-DryRun` | 关闭 | 只打印计划执行步骤，不修改文件。 |

## 配置

安装器会在 `<目标目录>\home` 下创建初始配置文件：

```text
home\.env
home\config.yaml
home\SOUL.md
```

生成的 `config.yaml` 是模板，需要按你的企业模型网关和 MCP 服务调整：

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

密钥建议放在 `home\.env`：

```dotenv
CORP_LLM_API_KEY=
NO_PROXY=.corp.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1
```

## 验证安装器

先做 dry run：

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 -DryRun
```

运行本地沙箱测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-install-hermes-corp-sandbox.ps1
```

沙箱测试会使用 fake `git` 和 fake `uv`，用于验证安装流程，不访问网络，也不下载依赖。

给终端用户使用前，建议至少在干净 Windows VM 里跑一次真实安装：

```powershell
mkdir D:\hermes-test
cd D:\hermes-test
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1
.\bin\hermes-corp.ps1 --version
.\bin\hermes-corp.ps1 doctor
```

## 卸载

在安装根目录运行自带卸载脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1
```

默认会删除代码、虚拟环境、运行时、uv 缓存和启动入口，并保留 `home`，这与官方 Hermes 卸载默认保留用户配置的语义一致，方便后续重装。

如果要连本地配置、认证信息、会话、技能和日志一起删除：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1 -RemoveHome
```

如果要做更完整的清理，同时检查进程、启动目录快捷方式、计划任务和 User 环境变量里是否还有指向该安装目录的项：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1 -StopProcesses -CleanUserEnvironment -RemoveHome
```

## 说明

- Git 被视为前置依赖。本项目不会全局安装 Git。
- 安装器会通过进程级环境变量设置 Git 的 `windows.appendAtomically=false`，用于规避 Windows lock 文件问题，但不会运行 `git config --global`。
- Node 是可选项。只有需要 Node 相关功能时，才传 `-InstallNodeDeps` 和 `-NodeZip`。
- 本项目不是 Hermes Agent 官方项目。
