# 可复现发布

```sh
./scripts/package-macos.sh
```

默认构建 Apple Silicon Release、进行 ad-hoc 签名并生成 ZIP / DMG / SHA256。该产物只应标记为测试版，未经过 Apple 公证，不保证在另一台 Mac 上默认放行。

正式公开分发准备 Developer ID Application 签名身份及本机 Keychain 中的 notarytool profile（不要把凭据存入仓库或命令行历史）：

```sh
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' NOTARY_PROFILE='your-notary-profile' ./scripts/package-macos.sh
```

脚本在提交公证后等待结果，失败则停止；成功后 staple / validate，再生成最终 ZIP 和 DMG。发布前用 `spctl --assess --type execute --verbose`检查 App，并在一台干净的 Mac 验证下载、首次启动、权限和配对。只完成本机构建不算跨机安装验收。

Apple 官方流程：https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

iOS / watchOS 需要独立的开发者签名、App Store Connect 和 TestFlight 分发流程；本项目不提供可任意侧载的通用 IPA。
