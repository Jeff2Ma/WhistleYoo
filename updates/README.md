# Sparkle 更新源

`appcast.xml` 是 App 内 `SUFeedURL` 指向的稳定更新源。发布脚本生成的 zip/dmg 和 delta 文件不会提交到 Git，它们应上传到对应版本的 GitHub Release；更新后的 `appcast.xml` 需要提交到 `main` 分支。

完整发布流程见 [维护者指南](../docs/maintainer-guide.md#sparkle-更新签名与手工打包)。

PR 合并到 `main` 后，GitHub Actions 会根据 `release:major`、`release:minor`、`release:patch` 或 `release:none` 标签决定版本与是否发布；没有发布标签时默认递增 patch。发布流程会生成 Universal DMG、上传对应 GitHub Release，并自动回写此文件。首次启用前需配置 Repository Secret `SPARKLE_ED25519_PRIVATE_KEY`；具体步骤见维护者指南的 [GitHub Actions 自动发布](../docs/maintainer-guide.md#github-actions-自动发布)。
