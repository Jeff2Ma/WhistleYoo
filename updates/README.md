# Sparkle 更新源

`appcast.xml` 是 App 内 `SUFeedURL` 指向的稳定更新源。发布脚本生成的 zip/dmg 和 delta 文件不会提交到 Git，它们应上传到对应版本的 GitHub Release；更新后的 `appcast.xml` 需要提交到 `main` 分支。

完整发布流程见项目根目录 [README.md](../README.md#发布-sparkle-更新)。
