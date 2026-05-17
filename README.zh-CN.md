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
- 允许用户手动从 GitHub 下载源码，但运行时依赖保持隔离

本安装器按这个思路设计。默认情况下，它把运行 PowerShell 命令时所在的当前目录作为安装根目录。

## 安装后目录结构

在目标目录执行安装后，会生成类似结构：

```text
<目标目录>\
  app\hermes-agent\          # Hermes Agent 源码副本
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
- `uv` 已在 `PATH` 中可用，或通过 `-UvExe` 指定
- 已从 GitHub 下载 Hermes Agent 源码 zip，或已经解压好的 Hermes Agent 源码目录

可选：

- Git for Windows，仅当你显式传 `-AllowGitClone` 走兜底 `git clone` 模式时需要
- Git Bash，Hermes terminal 功能建议安装；当 PowerShell 里 git clone 失败但 Git Bash 可以 clone 时，也用于 `-UseGitBashForGit`
- 企业内网 PyPI 镜像
- uv Python standalone 内网镜像
- 企业内网 npm registry
- Node 22 Windows zip 包，仅当你需要 Node 相关 Hermes 功能时使用

## 快速开始

先手动下载 Hermes Agent 源码，避免在受管控桌面上触发 `git clone` 问题。

1. 用浏览器打开 [NousResearch/hermes-agent v2026.5.7](https://github.com/NousResearch/hermes-agent/releases/tag/v2026.5.7)。
2. 下载源码 zip，也可以直接下载 [v2026.5.7.zip](https://github.com/NousResearch/hermes-agent/archive/refs/tags/v2026.5.7.zip)。
3. 可以保留 zip 原样，也可以先解压到本地目录。

然后创建或选择一个安装目录，从这个目录里运行安装脚本：

```powershell
mkdir D:\tools\hermes
cd D:\tools\hermes

powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
```

如果已经解压了 zip，传解压后的源码目录：

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourcePath C:\downloads\hermes-agent-2026.5.7
```

如果完整 clone `hermes-agent.git` 很慢，可以继续让 Hermes 主源码走 zip，只在源码里存在 `.gitmodules` 且确实需要子模块文件时，单独 clone 子模块：

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip `
  -AllowGitClone `
  -CloneSourceSubmodules `
  -UseGitBashForGit
```

如果 PowerShell 提示脚本未进行数字签名、无法运行，可以改用 CMD 包装入口：

```cmd
C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.cmd -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
```

这个 CMD 包装入口只会用当前进程级的 `-ExecutionPolicy Bypass` 启动 PowerShell，不会修改系统策略。如果企业通过组策略强制 `AllSigned`，则需要使用企业代码签名证书给 `.ps1` 文件签名；这种组策略不能靠包装脚本绕过。

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
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip `
  -PypiIndexUrl https://pypi.corp/simple `
  -PythonInstallMirror https://artifacts.corp/astral/python-build-standalone
```

如果本机已经配置了 pip 镜像，例如 `PIP_CONFIG_FILE`、`%APPDATA%\pip\pip.ini` 或 `%PROGRAMDATA%\pip\pip.ini` 里有 `index-url`，可以不传 `-PypiIndexUrl`。安装器会把 pip 配置自动转换成当前进程的 `UV_DEFAULT_INDEX`、`UV_INDEX_URL`、`PIP_INDEX_URL`；`extra-index-url` 会转换成 `UV_INDEX`、`UV_EXTRA_INDEX_URL`、`PIP_EXTRA_INDEX_URL`。这些变量只在安装器进程内生效，不写入全局环境。

注意：pip 镜像只影响 Python 包依赖下载，不影响 uv 下载托管 Python 解释器。如果企业环境不能访问外网，还需要传 `-PythonInstallMirror`，或提前准备可用的 Python/uv 缓存。

如果需要 npm 支持可选 Node 功能：

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip `
  -NpmRegistry https://npm.corp/repository/npm/ `
  -InstallNodeDeps `
  -NodeZip C:\artifacts\node-v22.x.x-win-x64.zip
```

默认不传 `-InstallNodeDeps` 时，脚本会跳过 Node 依赖，也不会使用系统 Node。

如果本机已经配置了 npm 镜像，例如 `NPM_CONFIG_USERCONFIG`、`%USERPROFILE%\.npmrc`、`%APPDATA%\npm\etc\npmrc`，可以不传 `-NpmRegistry`。安装器会读取 `.npmrc` 里的 `registry`、`proxy`、`https-proxy`、`strict-ssl`、`cafile`，并设置为当前进程的 `npm_config_*` 变量。`app\hermes-agent\.npmrc` 会在源码准备好后、安装 Node 依赖前再次读取。配置只在安装器进程内生效，不写入全局 npm 配置。

## 参数说明

主入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 [options]
```

参数会转发给 `scripts\install-hermes-corp-windows.ps1`。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Root` | 当前 PowerShell 目录 | 安装根目录。留空时安装到你 `cd` 进入的目录。 |
| `-SourcePath` | 空 | 本地 Hermes Agent 源码目录，也可以是包含解压后源码目录的上级目录。`git clone` 被拦截时推荐使用。 |
| `-SourceZip` | 空 | 本地 Hermes Agent 源码 zip。安装器会解压到 `runtime\source-extract`，再把源码复制到 `app\hermes-agent`。 |
| `-AllowGitClone` | 关闭 | 显式允许安装器使用 git clone 兜底。默认关闭，推荐手动下载源码 zip。 |
| `-UseGitBashForGit` | 关闭 | 让兜底 git 操作通过 Git Bash 执行。当用户手动在 Git Bash 里 `git clone` 成功、但 PowerShell 里失败时使用。 |
| `-CloneSourceSubmodules` | 关闭 | 在 `-SourcePath` 或 `-SourceZip` 模式下，clone/update `.gitmodules` 里声明的子模块。需要同时传 `-AllowGitClone`；适合主 Hermes 源码走 zip、小型子模块走 git 的场景。 |
| `-RepoUrl` | `https://github.com/NousResearch/hermes-agent.git` | 兜底 git 仓库地址。只有传 `-AllowGitClone` 且未传 `-SourcePath` / `-SourceZip` 时才使用。 |
| `-Branch` | `v2026.5.7` | 兜底 git 分支或 tag。`v2026.5.7` 对应 v0.13.0 附近的 Windows Native 版本。 |
| `-PythonVersion` | `3.11` | 本地 uv 虚拟环境使用的 Python 版本。 |
| `-NodeMajorVersion` | `22` | 本地托管 Node 目录名，仅在 `-InstallNodeDeps` 时使用。 |
| `-PypiIndexUrl` | 空 | uv 和 pip 使用的 PyPI/simple 镜像地址。留空时会尝试读取本机 pip 配置。 |
| `-NpmRegistry` | 空 | npm registry 地址。留空时会尝试读取本机 `.npmrc`。 |
| `-PythonInstallMirror` | 空 | uv Python 安装镜像地址。 |
| `-HttpProxy` | 空 | 安装阶段供 git、uv、pip、npm 使用的进程级 HTTP 代理。 |
| `-HttpsProxy` | 空 | 安装阶段供 git、uv、pip、npm 使用的进程级 HTTPS 代理。 |
| `-NoProxy` | 空 | 安装阶段使用的进程级 no-proxy 列表。 |
| `-UvExe` | 空 | 显式指定 `uv.exe` 路径。 |
| `-NodeZip` | 空 | Node Windows zip 包，会解压到 `runtime\node22`。 |
| `-LogDir` | `<安装根目录>\logs` | 安装器诊断日志目录。 |
| `-InstallNodeDeps` | 关闭 | 使用本地托管 Node 安装可选 Node 依赖。 |
| `-ForceRecreateVenv` | 关闭 | 删除并重建安装目录下的本地 venv。 |
| `-SkipDependencyInstall` | 关闭 | 创建目录和 venv，但跳过 Python 依赖安装，主要用于测试。 |
| `-SkipConfigTemplate` | 关闭 | 不创建 `home\.env`、`home\config.yaml`、`home\SOUL.md` 模板。 |
| `-DryRun` | 关闭 | 只打印计划执行步骤，不修改安装文件；诊断日志仍会写入。 |

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

## 日志

安装器会写入诊断日志：

```text
logs\install-YYYYMMDD-HHMMSS.log
logs\install-transcript-YYYYMMDD-HHMMSS.log
```

生成的运行入口会写入启动日志：

```text
home\logs\launcher-YYYYMMDD.log
```

运行日志会记录解析到的路径、Git Bash 探测结果、代理变量是否存在以及 Hermes 退出码。日志不会记录 prompt 内容，也不会记录 API key 明文。

## 重新运行

安装器可以在失败后重新运行。在本地源码模式下，如果上一次运行在 `app\hermes-agent` 留下了残缺的非源码目录，下一次运行会把它移动到 `app\hermes-agent.partial-YYYYMMDD-HHMMSS`，然后重新复制本地源码。如果已经存在有效 Hermes 源码树，则会复用它。

如果没有传 `-SourcePath` 或 `-SourceZip`，安装器会直接停止并提示手动下载源码。只有显式传 `-AllowGitClone` 时，才会回退到 git 模式。该模式下已有有效 git checkout 时，会执行 `fetch`、`checkout` 和 submodule 同步。

如果用户手动在 Git Bash 里可以 clone，但安装器在 PowerShell 调 git 时失败，可以改用 Git Bash git 模式重新运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 `
  -AllowGitClone `
  -UseGitBashForGit
```

该模式会通过 Git Bash 执行 `git clone`、`fetch`、`checkout`、`pull` 和 `submodule update`，不会写入全局 Git 配置。

推荐的 zip 工作流里，`-SourceZip` 和 `-SourcePath` 始终优先于 clone Hermes 主仓库。只有源码里存在 `.gitmodules` 且确实需要这些子模块文件时，才额外加 `-CloneSourceSubmodules`。因为源码压缩包不保留主仓库 git index，空的子模块目录会按 `.gitmodules` 里的 URL 和 branch/default HEAD clone；如果必须精确使用主仓库锁定的子模块提交，仍然需要完整 git checkout。

## 验证安装器

先做 dry run：

```powershell
powershell -ExecutionPolicy Bypass -File .\install-hermes-corp.ps1 -DryRun -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
```

运行本地沙箱测试：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-install-hermes-corp-sandbox.ps1
```

沙箱测试会使用 fake 本地源码树和 fake `uv`，用于验证安装流程，不执行 `git clone`，不访问网络，也不下载依赖。

给终端用户使用前，建议至少在干净 Windows VM 里跑一次真实安装：

```powershell
mkdir D:\hermes-test
cd D:\hermes-test
powershell -ExecutionPolicy Bypass -File C:\path\to\hermes-windows-isolated-installer\install-hermes-corp.ps1 `
  -SourceZip C:\downloads\hermes-agent-v2026.5.7.zip
.\bin\hermes-corp.ps1 --version
.\bin\hermes-corp.ps1 doctor
```

## 卸载

在安装根目录运行自带卸载脚本：

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-hermes-corp.ps1
```

如果 PowerShell 脚本执行被拦截，可以使用 CMD 包装入口：

```cmd
uninstall-hermes-corp.cmd -DryRun
uninstall-hermes-corp.cmd
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

- Git 是可选项。本项目不会全局安装 Git。默认不执行 `git clone`；只有传 `-AllowGitClone` 才会使用 git 兜底。PowerShell git 被拦截但 Git Bash 可用时，加 `-UseGitBashForGit`；完整 clone `hermes-agent.git` 很慢或被拦截时，使用 `-SourcePath` 或 `-SourceZip`。
- 使用 `-SourceZip` 或 `-SourcePath` 时，Hermes 主源码不会被 clone。`-CloneSourceSubmodules` 只会 clone `.gitmodules` 里声明的子模块。
- Git Bash 仍建议安装，用于 Hermes terminal 功能。安装在常见路径时，启动器会自动探测。
- 在兜底 git 模式下，安装器会通过进程级环境变量设置 Git 的 `windows.appendAtomically=false`，用于规避 Windows lock 文件问题，但不会运行 `git config --global`。
- Node 是可选项。只有需要 Node 相关功能时，才传 `-InstallNodeDeps` 和 `-NodeZip`。
- 本项目不是 Hermes Agent 官方项目。
