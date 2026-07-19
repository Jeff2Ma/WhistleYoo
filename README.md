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
WHISTLEYOO_RUN_INTEGRATION=1 swift test --filter WhistleIntegrationTests
./build.sh --clean
./scripts/verify.sh
open "dist/WhistleYoo.app"
```

正式签名：

```bash
./build.sh --sign "Developer ID Application: Your Name (TEAMID)"
```

临时覆盖版本号和构建号（不会修改 Xcode 工程文件）：

```bash
./build.sh --clean --no-install --version 0.0.4 --build-number 4
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
./scripts/sign-sparkle-update.sh updates/WhistleYoo-<version>.zip
```

当前没有 Apple Developer / Developer ID，`build.sh` 默认对 App 做 ad-hoc 签名。为使 Hardened Runtime 下的 App 能加载 SwiftPM 提供的 Sparkle 动态框架，entitlements 启用了 `com.apple.security.cs.disable-library-validation`。这会降低运行时库校验强度，并不能消除 Gatekeeper 的“无法验证开发者”提示；拿到 Developer ID 后，应删除该 entitlement，使用正式签名并公证后再发布。

## GitHub Actions 自动发布 Universal DMG

仓库内的 `.github/workflows/release-macos.yml` 会在推送 `vX.Y.Z` 标签时自动：

1. 在固定的 Intel macOS runner 上运行单元测试和 Whistle 集成测试；
2. 同时编译 `arm64` 与 `x86_64`，检查 App 内所有 Mach-O 文件的双架构切片；
3. 生成并用 Sparkle EdDSA 签名 `WhistleYoo-X.Y.Z.dmg`；
4. 创建或更新同名 GitHub Release，并上传 DMG 和 SHA-256 文件；
5. 将新 `appcast.xml` 原子回写到默认分支。

首次启用前，在 GitHub 仓库的 `Settings → Secrets and variables → Actions` 中新增 Repository Secret：

```text
SPARKLE_ED25519_PRIVATE_KEY
```

Secret 的值应为本机 `.sparkle/ed25519-private-key` 的完整内容。工作流会在发布前派生公钥并与 App 内的 `SUPublicEDKey` 比较，密钥不匹配时不会上传 Release。

已登录 GitHub CLI 时，也可以在仓库根目录安全写入 Secret（命令不会把私钥打印到终端）：

```bash
gh secret set SPARKLE_ED25519_PRIVATE_KEY < .sparkle/ed25519-private-key
```

发布示例：

```bash
git tag v0.0.4
git push origin v0.0.4
```

标签必须严格使用 `vX.Y.Z`，每段数字不能超过 `999`。工作流使用版本号计算稳定、递增的 Sparkle build number，例如 `v0.0.4 → 4`、`v0.1.0 → 1000`。默认分支还需允许此 workflow 使用 `contents: write` 回写 `updates/appcast.xml`；如果启用了禁止直接更新的分支保护，需要为 GitHub Actions 配置对应例外。当前自动发布仍是 ad-hoc 代码签名，GitHub Actions 自动化不会消除 Gatekeeper 提示；Developer ID 签名与 Apple 公证需要另行配置证书和公证凭据。

## 行为说明

- 默认代理端口 `8899`，监听局域网；Web UI 端口 `8900`，仅监听 `127.0.0.1`。
- 端口冲突时直接提示，不自动选择其他端口。
- 开启系统代理前保存 HTTP、HTTPS、SOCKS、PAC 状态；关闭或下次启动时仅恢复仍由本 App 持有的设置。
- 根证书安装到当前用户登录钥匙串，并使用 SHA-256 指纹跟踪。
- App 正常退出时先恢复系统代理，再停止专属 Whistle 实例。
- 停止后按专属数据目录识别并清理 Whistle 遗留的 `pfork` 辅助进程，不影响其他 Whistle 实例。
- 设置包含 `schemaVersion`，已预留逐版本数据迁移机制。

系统代理与证书测试不会在自动测试中修改真实机器状态，相关命令通过 mock 验证；真实集成测试会启动并停止隔离的 Whistle 实例。
