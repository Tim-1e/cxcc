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
- 独立安装器和首个 Release 尚未发布；目前仍由 [`Tim-1e/dotfiles`](https://github.com/Tim-1e/dotfiles) 提供生产安装入口。

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
