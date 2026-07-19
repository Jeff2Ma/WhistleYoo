# WhistleYoo 维护者指南

本文面向参与开发和发布 WhistleYoo 的维护者。普通用户请阅读项目根目录的 [English README](../README.md) 或 [中文 README](../README_zh.md)。

## 环境要求

- macOS 13 或更高版本；
- Xcode 16；
- Node.js 18 或更高版本；
- 全局安装的 Whistle 2.9 或更高版本；
- 发布更新时需要项目对应的 Sparkle EdDSA 私钥；
- Developer ID 签名和 Apple 公证尚未接入自动发布流程。

安装 Whistle 并解析 Swift 包依赖：

```bash
npm install -g whistle
swift package resolve
```

主要入口如下：

| 入口 | 用途 |
| --- | --- |
| `build.sh` | 构建、签名并按需安装 Universal App |
| `scripts/verify.sh` | 完整本地验证，包括真实 Whistle 集成测试和安装 |
| `scripts/package-sparkle-update.sh` | 生成 Sparkle zip 或 DMG，并刷新 appcast |
| `scripts/sign-sparkle-update.sh` | 单独生成 Sparkle enclosure 签名 |
| `scripts/resolve-release-version.sh` | 为 GitHub Actions 解析版本和发布决策 |
| `.github/workflows/release-macos.yml` | 测试并发布 Universal DMG |

## 本地开发与测试

日常修改至少运行本地化资源校验和严格单元测试：

```bash
./scripts/verify-localization.sh
swift test -Xswiftc -warnings-as-errors
```

真实集成测试会启动一个使用独立 storage 的 Whistle 实例，并要求本机已具备可用的 Node.js 和全局 Whistle：

```bash
WHISTLEYOO_RUN_INTEGRATION=1 \
  swift test --filter WhistleIntegrationTests
```

完整验证入口为：

```bash
./scripts/verify.sh
```

该脚本依次校验本地化资源、单元测试、真实 Whistle 集成、Release 构建、代码签名、`Info.plist` 和 Universal 架构。它最终会调用不带 `--no-install` 的 `build.sh`，因此会退出当前运行的 WhistleYoo，并覆盖安装到 `/Applications/WhistleYoo.app`。

## 构建 Universal App

只构建、不安装：

```bash
./build.sh --clean --no-install
open "dist/WhistleYoo.app"
```

构建并覆盖安装到 `/Applications`：

```bash
./build.sh --clean
open "/Applications/WhistleYoo.app"
```

`build.sh` 会同时编译 `arm64` 和 `x86_64`，把 Release App 放到 `dist/WhistleYoo.app`，执行签名校验，并通过 `lipo` 检查主程序架构。安装前会优先请求正在运行的 App 正常退出，让它先恢复系统代理并停止专属 Whistle 实例；只有正常退出超时才会强制结束进程。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--clean` | 构建前清理 `build/` 和 `dist/` |
| `--no-install` | 只生成 `dist/WhistleYoo.app` |
| `--install-dir <path>` | 修改安装目录，默认为 `/Applications` |
| `--sign <identity>` | 使用指定代码签名身份，默认为 ad-hoc |
| `--version <x.y.z>` | 临时覆盖 `MARKETING_VERSION` |
| `--build-number <n>` | 临时覆盖 `CURRENT_PROJECT_VERSION` |

临时版本号只影响本次构建，不会改写 Xcode 工程：

```bash
./build.sh --clean --no-install \
  --version 0.4.0 \
  --build-number 4000
```

需要单独复查 App 内全部 Mach-O 文件的双架构切片时运行：

```bash
./scripts/verify-universal-app.sh dist/WhistleYoo.app
```

## 代码签名

### 默认 ad-hoc 签名

未指定身份时，`build.sh` 使用 `-` 对 App 做 ad-hoc 签名：

```bash
./build.sh --clean --no-install
codesign --verify --deep --strict --verbose=2 dist/WhistleYoo.app
```

当前 entitlements 启用了 `com.apple.security.cs.disable-library-validation`，用于让 Hardened Runtime 下的 App 加载 SwiftPM 提供的 Sparkle 动态框架。ad-hoc 签名不会消除 Gatekeeper 的“无法验证开发者”提示，也不等同于 Apple 公证。

### Developer ID 签名

本机钥匙串中具备有效证书时，可以指定完整签名身份：

```bash
./build.sh --clean --no-install \
  --sign "Developer ID Application: Your Name (TEAMID)"
```

非 ad-hoc 签名会启用安全时间戳。正式对外切换到 Developer ID 前，还应审查并尽可能移除 `disable-library-validation` entitlement，补齐 `notarytool` 公证与 stapling，并同步调整 GitHub Actions 的证书导入和公证凭据；当前仓库尚未自动完成这些步骤。

## Sparkle 更新签名与手工打包

应用通过 Swift Package Manager 集成 Sparkle 2.9.2，默认 appcast 地址为：

```text
https://raw.githubusercontent.com/Jeff2Ma/WhistleYoo/main/updates/appcast.xml
```

### 初始化或恢复 EdDSA 密钥

```bash
swift package resolve
./scripts/generate-sparkle-keys.sh
```

私钥默认导出到 `.sparkle/ed25519-private-key`，权限为 `600`；整个 `.sparkle/` 目录已被 Git 忽略。脚本会输出对应的 `SUPublicEDKey`，它必须与 `Sources/whistleYooApp/Resources/Info.plist` 中的值一致。

请把私钥离线备份到安全位置。丢失私钥后，如果已安装版本也没有 Developer ID 签名作为备用信任链，就无法继续向这些版本发布可验证的更新。

### 生成更新归档

生成 zip 或 DMG，并自动以 EdDSA 签名、刷新 `updates/appcast.xml`：

```bash
./scripts/package-sparkle-update.sh zip
# 或
./scripts/package-sparkle-update.sh dmg
```

发布特定版本时显式传入版本号和构建号：

```bash
./scripts/package-sparkle-update.sh dmg \
  --version 0.4.0 \
  --build-number 4000
```

脚本会执行干净的 Release 构建，把归档和可能生成的 delta 放入 `updates/`，并让 appcast 最多保留 10 个版本。归档文件已被 Git 忽略，不应提交到仓库；需要上传到同版本的 GitHub Release。

如果发布到其他下载服务器，可以覆盖 URL 前缀：

```bash
SPARKLE_DOWNLOAD_URL_PREFIX="https://downloads.example.com/whistleyoo/" \
  ./scripts/package-sparkle-update.sh zip
```

单独生成某个归档的 enclosure 签名：

```bash
./scripts/sign-sparkle-update.sh updates/WhistleYoo-0.4.0.dmg
```

手工发布时应检查归档文件名、appcast 中的版本/构建号、下载 URL、文件长度和 EdDSA 签名，然后上传归档及 delta，并只提交更新后的 `updates/appcast.xml`。

## GitHub Actions 自动发布

`.github/workflows/release-macos.yml` 支持以下入口：

- PR 合并到 `main`；
- 从 Actions 页面手动选择 `patch`、`minor` 或 `major`；
- 推送严格符合 `vX.Y.Z` 的显式版本标签。

PR 可使用以下互斥标签：

| 标签 | 结果 |
| --- | --- |
| `release:major` | 递增主版本，例如 `v0.3.0 → v1.0.0` |
| `release:minor` | 递增次版本，例如 `v0.3.0 → v0.4.0` |
| `release:patch` | 递增修订版本，例如 `v0.3.0 → v0.3.1` |
| `release:none` | 合并但不发布 |
| 无发布标签 | 默认递增 patch |

多个 `release:*` 标签同时存在时，发布决策会失败。自动发布只处理有关联已合并 PR 的 `main` 提交；直接推送到 `main` 会跳过发布。任务重跑时会复用已经指向当前提交的版本标签，不会再次递增版本。

版本基线取最新的语义化版本标签与 Xcode `MARKETING_VERSION` 中较新的一个。显式标签必须严格使用 `vX.Y.Z`，三个数字均不能超过 `999`。Sparkle build number 按以下公式稳定生成：

```text
major × 1,000,000 + minor × 1,000 + patch
```

例如 `v0.3.1 → 3001`、`v1.0.0 → 1000000`。

### 配置发布私钥

在 GitHub 仓库的 `Settings → Secrets and variables → Actions` 中新增 Repository Secret：

```text
SPARKLE_ED25519_PRIVATE_KEY
```

值为 `.sparkle/ed25519-private-key` 的完整内容。也可以在已登录 GitHub CLI 时从仓库根目录写入，命令不会把私钥打印到终端：

```bash
gh secret set SPARKLE_ED25519_PRIVATE_KEY \
  < .sparkle/ed25519-private-key
```

工作流会在发布前从 Secret 派生公钥，并与 App 内的 `SUPublicEDKey` 比较；不匹配时立即停止。

### 自动发布执行内容

1. 解析来源、版本、标签、构建号和是否需要发布；
2. 在固定的 Intel macOS runner 上校验本地化、运行严格单元测试和真实 Whistle 集成测试；
3. 从默认分支读取最新 appcast，避免丢失历史版本；
4. 同时构建 `arm64` 与 `x86_64`，检查 App 内所有 Mach-O 文件的双架构切片；
5. 生成并用 Sparkle EdDSA 签名 `WhistleYoo-X.Y.Z.dmg`；
6. 校验 App 签名、DMG、版本信息和 Sparkle 签名，生成 SHA-256 文件；
7. 创建或复用版本标签，创建或更新同名 GitHub Release，并上传 DMG 与 SHA-256；
8. 将新的 `updates/appcast.xml` 回写到默认分支；
9. 无论成功或失败，删除 runner 上的临时私钥文件。

默认分支必须允许 workflow 使用 `contents: write` 创建标签、Release 并回写 appcast。如果分支保护禁止直接更新，需要为 GitHub Actions 配置对应例外。

当前自动发布仍使用 ad-hoc 代码签名。Sparkle EdDSA 能验证更新包来源，但不能替代 Developer ID 签名与 Apple 公证。

## 发布前检查清单

- 确认工作树只包含计划发布的修改；
- 确认本地化资源已同步；
- 运行严格单元测试和真实 Whistle 集成测试；
- 确认版本标签或 PR 发布标签正确且唯一；
- 确认 Sparkle 私钥与 `SUPublicEDKey` 匹配；
- 确认 App、DMG、双架构、版本号、构建号和 EdDSA 签名均通过校验；
- 确认 GitHub Release 同时包含 DMG 和 SHA-256；
- 确认默认分支上的 appcast 已包含新版本，且旧版本记录仍然存在；
- 从 Releases 下载公开资产，完成一次干净安装、启动和应用内更新检查。

## 仓库安全约定

- 不提交 `.sparkle/`、证书、私钥、Provisioning Profile 或任何签名凭据；
- 不提交 `updates/*.zip`、`updates/*.dmg`、delta 或本地 `dist/`；
- 不提交包含真实规则、本地路径或内部域名的 `WhistleYoo.json`；
- 发布前检查 `git status` 和待提交 diff，避免把本地运行产物带入版本库。
