# CodexBridge

为 macOS 上依赖 Clash 代理的 Codex / ChatGPT 桌面云端连接提供后台桥接。

某些桌面版本的 `wss://codex-cloud-backend.chatgpt.com/` 连接会绕过系统代理和 `HTTP_PROXY` / `HTTPS_PROXY`，反复出现 `open_timeout`、关闭代码 `1006`。CodexBridge 用一个目标受限的 TUN 将这条连接转发到现有 Clash，保持 TLS 原样传输。

这是社区代理兼容性工具，与 OpenAI、Clash 或 MetaCubeX 无隶属关系；它不能修复账户、服务端、地区限制或其他类型的网络错误。上游修复代理行为后，可以卸载本工具。

## 技术栈

- Swift / Foundation / CryptoKit，使用系统原生库，无第三方 Swift 依赖。
- macOS `launchd` LaunchDaemon：开机启动、异常恢复、后台运行。
- [官方 Mihomo](https://github.com/MetaCubeX/mihomo) 内核：独立子进程负责 TUN、TLS 域名识别与 SOCKS5 转发。

运行时不需要 Python、Node.js 或 Go。构建源码需要 Xcode Command Line Tools 和 Swift 5.9 或更新版本。

## 工作原理

```text
桌面应用的云端连接
  → 仅覆盖目标服务器解析地址的 TUN 路由
  → 从 TLS SNI 识别目标域名，不解密 TLS
  → 本机现有 Clash mixed/SOCKS5 端口
  → 云端服务器
```

每次启动从 `scutil --proxy` 发现实际端口，使用 `lsof` 确认监听者属于 Clash/mihomo，并验证 SOCKS5 协议。项目没有写死代理端口。

服务在开机后等待 Clash 启动，不要求 Clash 比它先启动。Clash 退出时，辅助内核停止并释放 TUN 路由；Clash 重新启动或端口改变后，服务自动重新建立桥接。辅助内核异常退出时会自动重试。

只添加目标解析结果的 `/32` 或 `/128` 路由，不修改系统 DNS、系统代理设置、Clash 订阅、节点选择或应用安装包。TLS 域名识别也能处理本机 DNS 返回错误公网地址的情况：识别出目标域名后由 Clash 完成转发。其他域名通过 `DIRECT` 规则保留原先路径。

已有目标连接时不会仅因 DNS 变化重建 TUN。连接断开后定期补充新地址，路由数量设有上限。DNS 短暂失败不会清空正在使用的路由。

## 使用条件

- macOS 13 或更新版本，Apple Silicon / Intel。
- 已运行 Clash 系列客户端，并开启本机系统代理。
- 实际系统代理端口必须同时支持免认证 SOCKS5；ClashX 的 mixed 端口符合这一条件。
- 第一次安装需要本机管理员授权，用于创建 TUN 网卡和安装 LaunchDaemon。
- Clash 自己的登录启动由 Clash 管理；CodexBridge 不替你启用 Clash 的登录项。

## 安装

```bash
cd /path/to/CodexBridge
./scripts/install.sh
```

脚本先以普通用户完成构建、官方内核下载和 SHA256 校验，再通过 `sudo` 请求管理员授权。不要直接使用 `sudo ./scripts/install.sh`。

如果之前运行过临时修复脚本，请先在旧终端按 `Ctrl+C` 停止它，避免两个 TUN 同时覆盖相同路由。

安装完成后可以关闭终端。服务的代码和内核会复制到 root 所有、普通用户不可写的安装目录，不会以 root 身份运行项目目录中的文件。重新运行安装命令可更新本地安装；安装失败时会恢复之前的安装。

安装不会修改 `~/.codex/.env`。已有 HTTP 代理配置继续保留。

## 状态与维护

```bash
./scripts/status.sh

# 暂停至下次开机，之后可手动启动
sudo ./scripts/service-admin.sh stop
sudo ./scripts/service-admin.sh start

# 重新启动后台服务
sudo ./scripts/service-admin.sh restart

# 查看服务日志
sudo tail -n 50 '/Library/Application Support/CodexBridge/logs/bridge.log'

# 卸载后台服务与安装产物，保留项目源码
./scripts/uninstall.sh
```

`state=active` 表示 TUN 和 Clash 桥接正常，不等于账户已完成云端认证。`target_connections > 0` 表示真实目标连接正在经过 TUN；`cloud_state=connected` 来自桌面应用的最近日志。应用没有运行时，后一个字段可能仍反映旧日志，应结合目标连接数查看。

`state=waiting` 常见原因是 Clash 尚未启动、系统代理未开启、目标 DNS 暂时不可用或代理端口不支持 SOCKS5。服务会持续等待，不会因此退出。

| 内容 | 位置 |
|---|---|
| LaunchDaemon | `/Library/LaunchDaemons/io.github.codexbridge.plist` |
| 已安装程序、配置与状态 | `/Library/Application Support/CodexBridge/` |
| 私有运行时配置与控制器凭据 | `/var/run/codexbridge/` |
| 服务日志 | `/Library/Application Support/CodexBridge/logs/bridge.log` |

运行时凭据和日志只允许 root 读取。公开状态文件不包含密钥。服务日志轮转保留约四份、每份约 2 MB；内核输出中的控制器凭据会被去除。

## 开发与验证

```bash
./scripts/test.sh
./scripts/build.sh
./scripts/fetch-core.sh
.build/release/codexbridge doctor
./scripts/integration-proxy.sh
```

测试使用独立 Swift 执行器，Command Line Tools 即可运行，无需安装完整 Xcode。

单元测试覆盖代理发现、错误端口与监听者、私有地址拒绝、路由范围和凭据文件权限。集成检查使用关闭 TUN 的临时本地入口，验证 TLS SNI → 现有 Clash 转发和证书校验，因此无需管理员权限。

真实 TUN、开机服务安装与桌面 WebSocket 恢复需要在本机完成管理员授权后验证。不要把未认证请求的 HTTP `403` 当作桌面登录成功。

GitHub Actions 在 macOS 上运行单元测试、构建、脚本语法和 plist 检查；不会安装系统服务或访问账号。

## 提交到 GitHub

只提交源码、脚本和文档。`.build/`、下载的内核、`.env`、运行时文件及日志均已忽略。仓库不需要保存本机账号、订阅地址或管理员凭据。

```bash
git add .
git commit -m "Initial CodexBridge implementation"
# 在 GitHub 创建 CodexBridge 仓库后，再设置自己的 remote 并 push。
```

Swift 桥接代码采用 MIT 许可；独立 Mihomo 内核采用其上游 GPL-3.0 许可。下载和校验规则见 `scripts/fetch-core.sh`，第三方说明见 `THIRD_PARTY_NOTICES.md`。

## 依据

- [同类桌面代理问题及 TUN 验证](https://github.com/openai/codex/issues/49829)
- [Apple：Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Mihomo TUN 文档](https://wiki.metacubex.one/config/inbound/tun/)
- [Mihomo TLS 域名识别文档](https://wiki.metacubex.one/config/sniff/)
