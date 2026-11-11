# 1.4.1-beta.1 验证记录

公开源码快照：2026-11-11。构建机：Apple Silicon、Xcode 27.1 / Swift 6 工具链。

- `swift test` 完整通过：Swift Testing 570项；XCTest报告87项（其中4项因平台/真机条件跳过），0失败。
- Mac Release ARM64构建成功，要求macOS 26+。
- `codesign --verify --deep --strict`通过；当前发布候选为ad-hoc签名，无开发团队身份。
- `spctl --assess`对未公证候选返回rejected，不能宣称默认Gatekeeper放行。最终签名状态以Release说明为准。
- Gitleaks扫描通过，未发现真实凭据；仅精确放行两个公开存储键和RFC 6455公开WebSocket测试nonce。
- 开发环境已验证移动办公自动咖啡因、无限逻辑时长、手动启停释放、蓝牙后台接收及App重启重连。
- 尚未在另一台干净Mac完成下载后首次运行；没有24小时真机持续性测试。本地权限、钥匙串、热点与VPN状态不会随安装包分发。
- iOS/watchOS源码包含在仓库；此次公开Mac包不等于iPhone/Watch公开TestFlight发布。
