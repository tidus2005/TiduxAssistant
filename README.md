# TiduxAssistant · Codex 随行助手

Mac、iPhone、Apple Watch 的个人 AI 协作助手。Mac 执行任务，手机查看状态、传送文件，手表快速提问和记录。

这是独立社区项目，与 OpenAI、Apple 无隶属关系。不包含 API Key、账号、付费模型额度或私人服务地址。

[下载安装包](https://github.com/tidus2005/TiduxAssistant/releases) · [安装与配对](docs/INSTALL.md) · [架构](docs/ARCHITECTURE.md) · [隐私和安全](SECURITY.md) · [MIT 许可](LICENSE)

## 当前能力

| 平台 | 能力 | 边界 |
| --- | --- | --- |
| Mac | 移动办公、咖啡因、合盖运行、热点恢复、设备状态、语音输入 | 合盖与后台热点部分依赖系统版本；不保证锁屏后 GUI 操作 |
| iPhone | BLE 配对与状态同步、照片/视频/文件传送、控制台、听写 | 后台由 iOS 调度；强制退出 App 后不保证重连 |
| Watch | 提问入口、任务/审批入口、表盘组件、实时记录 | 需要自行签名或获邀 TestFlight；不是可替换系统的第三方表盘 |

**移动办公**默认联动咖啡因。支持15分钟至4小时、8/12/24小时，以及无限（手动结束）。长会话使用有界系统保护租约续期；手动停止或安全停止恢复原配置。过热、没电、系统关机仍可能中断任务；请保持通风，不要在密闭包内持续高负载。

连接优先级：手机与 Mac **BLE → 局域网 → 显式配置的远程 HTTPS**；手机与 Watch 使用 WatchConnectivity。不会自动修改 VPN、代理或 DNS。热点已关联不等于互联网或 Codex 远控可用。

## 下载使用

前往 [Releases](https://github.com/tidus2005/TiduxAssistant/releases) 下载 Mac 安装包。首个版本为 **1.4.1-beta.1**，要求 **Apple Silicon、macOS 26 或以上**。

每个 Release 会明确标注 Developer ID / Apple 公证状态。未公证测试包不等于 macOS 默认信任的软件；不要关闭 Gatekeeper 或系统完整性保护。如果系统拒绝运行，请阅读安装说明或从源码构建。

iPhone 和 Watch 源码已提供，但不能像 Mac 一样把 ZIP 拖入安装。当前没有面向公众的 TestFlight 邀请链接；需要自己的 Apple 开发签名，或等待后续公开测试。

## 从源码构建

需要 Xcode 26+（Swift 6.2+）、Xcode Command Line Tools 和 XcodeGen。

```sh
brew install xcodegen
git clone https://github.com/tidus2005/TiduxAssistant.git
cd TiduxAssistant
xcodegen generate
swift test
./scripts/package-macos.sh
```

打包脚本默认生成 ad-hoc 签名的 Mac 测试包，不启动程序，不覆盖已安装 App，不修改系统设置。正式发布设置 `SIGNING_IDENTITY` 为 Developer ID Application 证书并设置 `NOTARY_PROFILE`，详情见 [发布流程](docs/RELEASING.md)。

开发 iPhone / Watch：生成工程后打开 `CodexWatchPet.xcodeproj`，选择自己的开发团队，为各 Target 配置可用的 Bundle ID、App Group 和签名；部署目标分别为 iOS 26+、watchOS 11+。真机支持情况须以实测为准。

## 验证状态

移动办公与咖啡因相关69项测试已在开发 Mac 通过，蓝牙配对、后台状态接收、手机 App 重启后重连已实测。首次公开发布还会从此仓库单独构建和运行测试。尚未验证24小时连续真机运行、所有 Mac 型号、所有 VPN/热点组合；“连接成功”不代表每个任务执行成功。

## 贡献

欢迎通过 Issue 报告问题；提供系统版本、复现步骤和已脱敏日志。不要提交配对码、短信验证码、API Key 或个人聊天内容。公共快照从现有应用整理，保留内部模块名 CodexWatchPet；私人仓库的历史、测试录音、运行记录和本机配置不包含在内。
