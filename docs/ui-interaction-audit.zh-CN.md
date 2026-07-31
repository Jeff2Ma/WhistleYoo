# WhistleYoo UI 交互审计

结论：当前 UI 的视觉层级和核心心智模型已经比较成熟，不建议推翻重做。最该优化的不是颜色、圆角或间距，而是“界面状态是否真实”“操作是否可恢复”“是否符合 macOS 键盘与无障碍习惯”。

本轮做了源码审计、文档截图走查、运行中 App 的 AX 无障碍树与日志验证，并执行了完整测试和 Release 构建。

## P0：建议优先修复

### 1. 页面切换会触发 SwiftUI 未定义行为

实机从其他页面切回 Rules & Values 时，稳定出现多条：

```text
Modifying state during view update, this will cause undefined behavior.
```

原因很可能是 `updateNSView` 期间同步发布光标位置，再写回 SwiftUI `@State`：[WhistleCodeEditor.swift](../Sources/whistleYooApp/WhistleCodeEditor.swift#L179)、[RuleConfigurationView.swift](../Sources/whistleYooApp/RuleConfigurationView.swift#L654)。

建议只在真实 selection 变化时发布，并延迟到下一轮 MainActor；不要在 `updateNSView` 中同步修改 SwiftUI 状态。

### 2. 草稿保护可以被菜单栏入口绕过

侧栏切换会询问是否丢弃规则草稿，但菜单栏/Popover 直接修改选中标签：[AppViews.swift](../Sources/whistleYooApp/AppViews.swift#L645)、[AppWindowControllers.swift](../Sources/whistleYooApp/AppWindowControllers.swift#L80)。

危险链路是：

```text
规则未保存
→ 通过菜单栏打开设置
→ 导入配置
→ 旧草稿拒绝同步新规则
→ 返回并保存
→ 覆盖刚导入的规则
```

同时，配置导入没有阻止 Values 正在保存/加载的情况：[AppStateController.swift](../Sources/whistleYooApp/AppStateController.swift#L713)。

建议建立唯一的导航与操作协调器，所有侧栏、菜单栏、重开窗口、配置导入都经过同一套 dirty/operation gate。

### 3. MCP 页面显示的不是实际运行状态

当前混合了三种状态：

- 尚未应用的表单草稿；
- 已写入设置的配置；
- NIO 实际监听状态。

复制的 JSON 使用本地草稿端口，甚至可以复制尚未应用或非法的地址；“设置已应用”又早于异步端口绑定完成：[AppViews.swift](../Sources/whistleYooApp/AppViews.swift#L1123)、[MCPHTTPServerCoordinator.swift](../Sources/whistleYooApp/MCPHTTPServerCoordinator.swift#L27)。

更严重的是，导入配置后没有触发 MCP runtime 重配，界面可能显示已关闭/只读/已开启鉴权，而旧服务仍按原权限和端口运行：[AppStateController.swift](../Sources/whistleYooApp/AppStateController.swift#L754)。

建议引入明确的 `Stopped / Starting / Listening / Failed` 状态；只有监听成功后才显示成功并允许复制“实际生效配置”。

### 4. 手机代理和兼容域名可能显示假状态

手机代理 ViewModel 只在 `prepare()` 时复制引擎状态。页面保持打开时若引擎停止，仍会显示绿色“代理服务已监听”并保留二维码：[MobileSetup.swift](../Sources/whistleYooApp/MobileSetup.swift#L47)。

兼容域名则先保存 desired 状态，再同步 Whistle；同步失败不回滚，第二次保存还可能直接返回成功：[AppStateController.swift](../Sources/whistleYooApp/AppStateController.swift#L855)。

建议区分 desired/applied 状态，失败时显示“未应用 · 重试”，手机页则实时订阅 engine、端口和网络接口变化。

### 5. Onboarding 可能失败后仍显示完成

“完成”会先永久标记 onboarding 已完成，然后尝试开启系统代理；无论持久化或代理启用是否成功，窗口都会关闭：[AppViews.swift](../Sources/whistleYooApp/AppViews.swift#L941)、[AppStateController.swift](../Sources/whistleYooApp/AppStateController.swift#L1104)。

此外，“重新运行设置助手”在窗口打开前就清除完成标记，用户仅查看后关闭，也会导致下次启动再次强制进入助手：[AppDelegate.swift](../Sources/whistleYooApp/AppDelegate.swift#L489)。

建议让完成方法返回结构化结果，失败留在当前页并提供重试；“重新运行”使用临时模式，完成后才提交版本标记。

## P1：交互体验与无障碍

- 代码编辑器会拦截 Tab、Shift-Tab，且连 Control-Tab 也被当作缩进，实机验证会形成键盘焦点陷阱：[WhistleCodeEditor.swift](../Sources/whistleYooApp/WhistleCodeEditor.swift#L505)。
- 规则排序只有拖拽，AX 树只暴露 `Press/ScrollToVisible`，键盘和 VoiceOver 无法上移/下移：[RuleConfigurationView.swift](../Sources/whistleYooApp/RuleConfigurationView.swift#L579)。
- 主侧栏和当前规则行没有暴露 `AXSelected`。
- “兼容性域名过滤”开关在实机 AX 树中没有名称；MCP、代理、Web UI 三个端口输入框也没有可区分的无障碍名称。
- 13pt 编辑器语法色在浅色模式实测对比度约为 2.22–4.17:1，低于小字建议的 4.5:1。
- Popover 状态图标永久脉冲，没有响应 Reduce Motion；状态栏图标反而已经正确处理：[AppViews.swift](../Sources/whistleYooApp/AppViews.swift#L61)。

这些不是边缘问题。Apple 当前规范明确要求键盘独立操作、Reduce Motion、非纯颜色状态表达和小字对比度：[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)。

## P1：补齐 macOS 原生体验

实机主菜单只有“退出”和“编辑”，缺少：

- 关于；
- 设置 `⌘,`；
- 检查更新；
- 窗口与帮助；
- 规则保存、刷新、编辑器命令。

代码入口在 [AppDelegate.swift](../Sources/whistleYooApp/AppDelegate.swift#L202)。Apple 也明确建议 macOS 菜单栏包含应用全部命令，并提供完整键盘工作流：[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)、[Menus](https://developer.apple.com/design/human-interface-guidelines/menus)。

Settings 当前是一张很长的滚动页，而且把低频高风险的配置导入放在第一屏。建议拆成 General、Network、Certificate、Advanced，并把 About 移回 App 菜单。至少应让 `⌘,` 直接打开 Settings；这也符合 Apple 的 [Settings 规范](https://developer.apple.com/design/human-interface-guidelines/settings)。

## 其他值得顺手修的点

- 所有业务错误都会弹阻塞式 `NSAlert`，同时页面内又显示相同错误；普通可恢复错误应留在操作附近，只有退出恢复失败等关键情况才打断用户：[AppStateController.swift](../Sources/whistleYooApp/AppStateController.swift#L1398)、[Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)。
- 打开 Rules & Values 会静默启动代理引擎，与 Console/Mobile 的显式启动 CTA 不一致：[RuleConfigurationView.swift](../Sources/whistleYooApp/RuleConfigurationView.swift#L307)。
- Default 示例写着“双击启停规则”，但实现只有右侧开关，并没有双击处理：[RuleConfigurationView.swift](../Sources/whistleYooApp/RuleConfigurationView.swift#L223)。
- Mobile 页面和 Onboarding 都没有滚动/自适应布局，最小窗口、大字体和长错误文本下容易裁切。
- 主窗口每次从菜单栏打开都会重新居中，多显示器环境下会把用户摆好的窗口移走：[AppWindowControllers.swift](../Sources/whistleYooApp/AppWindowControllers.swift#L80)。

## 建议排期

第一阶段先处理状态正确性：SwiftUI fault、统一导航/草稿守卫、配置导入事务、MCP runtime 状态、Mobile 实时状态、Onboarding 完成结果。

第二阶段再补 macOS 菜单、键盘路径、VoiceOver、对比度和响应式布局。视觉样式可以最后微调。

现有优点应保留：Popover 中“代理引擎 / 全局系统代理”的双层表达很清楚，规则编辑的未保存提示、刷新/删除确认也比较完整，手机代理的步骤式信息结构也很好。

## 验证结果

- 95 个单元测试全部通过；
- 真实 Whistle 集成测试 1/1 通过；
- 本地化校验通过；
- Universal Release 构建通过；
- 本轮审计未修改产品代码或用户配置。
