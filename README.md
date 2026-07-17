# cxcc

[![CI](https://github.com/Tim-1e/cxcc/actions/workflows/ci.yml/badge.svg)](https://github.com/Tim-1e/cxcc/actions/workflows/ci.yml)

`cxcc` 是 Codex 与 Claude Code 的本地环境控制层，保留现有 `cx`、`cc`、`mcp` 命令体验，同时独立管理 Provider、profile、健康检查、session 与 Codex App Bridge。

> One control plane for Codex and Claude Code.

## 功能

- 在 Codex 与 Claude Code Provider/profile 之间切换。
- 管理健康检查、doctor、统计与跨 Provider session。
- 使用统一 registry 同步 Claude Code 与 Codex MCP 配置。
- 为 Codex App 提供受保护的多 Provider Bridge。
- 保持 Windows PowerShell 与 Bash/Zsh 命令行为一致。

## 平台与状态

- Windows PowerShell、Linux、macOS 与 Git Bash 由 CI 持续验证。
- 用户状态保留在 `~/.ai-env`、`~/.ai-secrets`、`~/.codex` 与 `~/.claude`。

## 安装

PowerShell 7：

```powershell
$version = "v0.1.0"
$installer = Invoke-RestMethod "https://raw.githubusercontent.com/Tim-1e/cxcc/$version/install.ps1"
& ([scriptblock]::Create($installer)) -Version $version
```

Bash：

```bash
curl -fsSL https://raw.githubusercontent.com/Tim-1e/cxcc/v0.1.0/install.sh |
  bash -s -- --version v0.1.0
```

安装器会校验 Release artifact 的 SHA-256，然后写入 `~/.local/share/cxcc/versions/<version>`。在 PowerShell profile 中 dot-source `~/.local/share/cxcc/load.ps1`，或在 Bash/Zsh 配置中 source `~/.local/share/cxcc/load.sh`。需要自定义安装根时设置 `CXCC_HOME`，其末级目录名必须为 `cxcc`。

## 升级与卸载

用目标精确版本重新运行安装命令即可升级；旧版本会保留。将上面同版本安装器改为 `-Rollback` / `--rollback` 可回到前一版，改为 `-Uninstall` / `--uninstall` 可卸载 cxcc。这些操作都不会删除用户 profile、secret、Codex 或 Claude 状态。

运行时需要 Node.js。Windows x64 Release 自带 Codex App Bridge，不需要 .NET SDK。安装器不修改 PATH，升级或回滚后请重新加载 shell profile。

## 安全边界

- 仓库绝不保存真实 API key、OAuth 数据、token、session 数据库或 rollout。
- secret 只在本机运行时读取，不写入 profile registry。
- Bridge bundle、配置哈希、ACL 与递归启动保护均有自动化回归。
- CI 使用固定版本与校验和执行完整 Git 历史 secret 扫描。

## 仓库结构

- `src/powershell/CxCc/`：Windows 实现与稳定入口。
- `src/shell/`：Bash/Zsh 实现与 health helper。
- `src/bridge/CodexProviderBridge/`：Codex App Provider Bridge。
- `templates/`：公开、安全的配置模板。
- `tests/`：行为、隔离、Bridge 与跨平台回归。

架构说明见 [`docs/architecture.md`](docs/architecture.md)。
