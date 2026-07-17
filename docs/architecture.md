# cxcc 架构

## 所有权

`cxcc` 负责：

- `cx`、`cc`、`mcp` 的实现与用户文档；
- profile/schema/default templates；
- health、doctor、session 与 Codex App 管理；
- Codex App Provider Bridge；
- Windows 与 Shell 安装器、升级器、卸载器；
- 单元、协议、集成和 clean-install 测试；
- GitHub Actions、Release artifacts 与 checksum。

外部 dotfiles/bootstrap 集成只需负责：

- cxcc 版本或发布通道的钉住值；
- bootstrap 中默认启用的 cxcc 安装调用；
- PowerShell/Zsh profile 中加载 cxcc 稳定入口的少量代码；
- 验证“已安装且能加载”的消费者 smoke。

## 数据流

```text
dotfiles bootstrap
  -> 安装钉住版本的 cxcc
  -> profile 加载 cxcc
  -> cx / cc / mcp 读取 ~/.ai-env
  -> 仅在运行时读取 ~/.ai-secrets
  -> 分别更新 Codex / Claude 的本机配置
```

## 发布安装模型

```text
~/.local/share/cxcc/
├── versions/<version>/
├── current.json
├── load.ps1
└── load.sh
```

- Release artifact 安装到版本目录。
- `current.json` 指向当前版本；切换必须原子化。
- loader 是稳定入口，不从 GitHub `main` 直接 source 生产代码。
- 下载内容必须校验 SHA-256。
- 升级保留前一版本以支持回滚。
- 安装与升级默认不覆盖 `~/.ai-env`、`~/.ai-secrets`、`~/.codex`、`~/.claude`。
