# WhistleYoo

macOS 13+ 原生菜单栏代理工具。Native 层管理用户本机安装的 Node.js 和全局 Whistle，使用独立的 Whistle storage，并在 `WKWebView` 中显示 Whistle Web UI。

## 环境要求

- macOS 13+
- Node.js 18+
- Whistle 2.9+：`npm install -g whistle`
- Xcode 16（构建时）

## 构建与测试

```bash
swift test
IPROXY_RUN_INTEGRATION=1 swift test --filter WhistleIntegrationTests
./build.sh --clean
./scripts/verify.sh
open "dist/WhistleYoo.app"
```

正式签名：

```bash
./build.sh --sign "Developer ID Application: Your Name (TEAMID)"
```

## 发布 Sparkle 更新

App 通过 Swift Package Manager 集成 Sparkle 2.9.2。默认更新源为：

```text
https://raw.githubusercontent.com/Jeff2Ma/WhistleYoo/main/updates/appcast.xml
```

首次配置或需要恢复密钥时运行：

```bash
swift package resolve
./scripts/generate-sparkle-keys.sh
```

私钥默认保存在 `.sparkle/ed25519-private-key`，整个 `.sparkle/` 目录已被 Git 忽略。请把私钥离线备份到安全位置；丢失私钥后，没有 Developer ID 签名作为备用信任链，已安装版本将无法验证后续更新。公开密钥位于 `Info.plist` 的 `SUPublicEDKey`。

生成待发布的 zip（推荐）或 dmg，并自动用 EdDSA 签名、更新 appcast：

```bash
./scripts/package-sparkle-update.sh zip
# 或
./scripts/package-sparkle-update.sh dmg
```

脚本会执行干净的 Release 构建，将归档和可能生成的 delta 放到 `updates/`，并更新 `updates/appcast.xml`。归档文件已被 Git 忽略；把归档和 delta 上传到脚本输出的 GitHub Release 地址，然后检查并提交 `appcast.xml`。如果发布到自有服务器，可覆盖下载前缀：

```bash
SPARKLE_DOWNLOAD_URL_PREFIX="https://downloads.example.com/whistleyoo" \
  ./scripts/package-sparkle-update.sh zip
```

需要手工生成 enclosure 签名属性时：

```bash
./scripts/sign-sparkle-update.sh updates/WhistleYoo-0.0.1.zip
```

当前没有 Apple Developer / Developer ID，`build.sh` 默认对 App 做 ad-hoc 签名。为使 Hardened Runtime 下的 App 能加载 SwiftPM 提供的 Sparkle 动态框架，entitlements 启用了 `com.apple.security.cs.disable-library-validation`。这会降低运行时库校验强度，并不能消除 Gatekeeper 的“无法验证开发者”提示；拿到 Developer ID 后，应删除该 entitlement，使用正式签名并公证后再发布。

## 行为说明

- 默认代理端口 `8899`，监听局域网；Web UI 端口 `8900`，仅监听 `127.0.0.1`。
- 端口冲突时直接提示，不自动选择其他端口。
- 开启系统代理前保存 HTTP、HTTPS、SOCKS、PAC 状态；关闭或下次启动时仅恢复仍由本 App 持有的设置。
- 根证书安装到当前用户登录钥匙串，并使用 SHA-256 指纹跟踪。
- App 正常退出时先恢复系统代理，再停止专属 Whistle 实例。
- 停止后按专属数据目录识别并清理 Whistle 遗留的 `pfork` 辅助进程，不影响其他 Whistle 实例。
- 设置包含 `schemaVersion`，已预留逐版本数据迁移机制。

系统代理与证书测试不会在自动测试中修改真实机器状态，相关命令通过 mock 验证；真实集成测试会启动并停止隔离的 Whistle 实例。
