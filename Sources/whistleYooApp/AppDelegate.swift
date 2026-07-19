import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(whistleYooCore)
import whistleYooCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppStateController()
    private let consoleSession = WhistleConsoleSession()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let popover = NSPopover()
    private var mainWindowController: MainWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var terminationInProgress = false
    private var animationTimer: Timer?
    private var animationFrameIndex = 0
    private var currentAnimationKind: StatusBarAnimationKind?
    private var animationFrameCache: [StatusBarAnimationKind: [NSImage]] = [:]
    private var lastRenderedStatus: ApplicationStatus?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateController.shared.start()
        configureMainMenu()
        configureStateCallbacks()
        configureAccessibilityNotifications()
        configureStatusItem()
        configurePopover()
        if !applyDockVisibility(state.showDockIcon), !state.showDockIcon {
            state.setShowDockIcon(true)
        }

        Task {
            let shouldShowOnboarding = await state.launch()
            updateStatusIcon()
            if shouldShowOnboarding {
                showOnboarding(reset: false)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard !state.isLoadingRules, !state.isSavingRules else {
            showRuleOperationInProgressAlert()
            openMainWindow(tab: .rules)
            return .terminateCancel
        }
        if mainWindowController?.hasUnsavedRules == true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = appLocalized("存在未保存的规则修改")
            alert.informativeText = appLocalized("退出 WhistleYoo 将放弃当前规则中未保存的修改。")
            alert.addButton(withTitle: appLocalized("继续编辑"))
            alert.addButton(withTitle: appLocalized("放弃并退出"))
            alert.buttons[1].hasDestructiveAction = true
            popover.performClose(nil)
            guard alert.runModal() == .alertSecondButtonReturn else {
                openMainWindow(tab: .rules)
                return .terminateCancel
            }
            mainWindowController?.discardUnsavedRules()
        }
        terminationInProgress = true
        Task {
            do {
                try await state.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                terminationInProgress = false
                sender.reply(toApplicationShouldTerminate: false)
                showTerminationError(error)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopAnimation()
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        let preferredScreen = statusItem?.button?.window?.screen
            ?? mainWindowController?.window?.screen
            ?? NSScreen.main
        popover.performClose(nil)
        sender.activate(ignoringOtherApps: true)

        if onboardingWindowController?.window?.isVisible == true {
            onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        } else if let mainWindowController {
            mainWindowController.reopen(centeredOn: preferredScreen)
        } else {
            openMainWindow(tab: .console)
        }
        return true
    }

    private func showRuleOperationInProgressAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = appLocalized("规则操作仍在进行")
        alert.informativeText = appLocalized("请等待当前规则操作完成后再退出 WhistleYoo。")
        alert.addButton(withTitle: appLocalized("继续编辑"))
        popover.performClose(nil)
        alert.runModal()
    }

    private func configureStateCallbacks() {
        state.onStatusChange = { [weak self] in
            self?.updateStatusIcon()
        }
        state.onError = { [weak self] error in
            self?.showError(error)
        }
        state.onMessage = { [weak self] message in
            self?.showMessage(message)
        }
        state.onEngineReady = { [weak self] url in
            self?.consoleSession.loadForEngineStart(baseURL: url)
        }
        state.onDockVisibilityChange = { [weak self] isVisible in
            self?.applyDockVisibility(isVisible) == true
        }
    }

    private func configureAccessibilityNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        updateStatusIcon(force: true)
    }

    private func applyDockVisibility(_ isVisible: Bool) -> Bool {
        let targetPolicy: NSApplication.ActivationPolicy = isVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != targetPolicy else { return true }

        // AppKit can order windows out while changing activation policy. Remember
        // the visible non-panel windows and restore them after that transition has
        // completed so toggling the Dock icon never looks like it closed a window.
        let visibleWindows = NSApp.orderedWindows.filter {
            $0.isVisible && !($0 is NSPanel)
        }
        let keyWindow = NSApp.keyWindow.flatMap { candidate in
            visibleWindows.contains(where: { $0 === candidate }) ? candidate : nil
        }

        let didChange = NSApp.setActivationPolicy(targetPolicy)
        guard didChange else { return false }

        if visibleWindows.isEmpty {
            if isVisible {
                NSApp.activate(ignoringOtherApps: true)
            }
            return true
        }

        // Restore immediately so there is no intentionally blank run-loop frame,
        // then reassert once after AppKit finishes the activation-policy change.
        restoreWindows(visibleWindows, keyWindow: keyWindow)
        DispatchQueue.main.async { [weak self] in
            self?.restoreWindows(visibleWindows, keyWindow: keyWindow)
        }
        return true
    }

    private func restoreWindows(_ windows: [NSWindow], keyWindow: NSWindow?) {
        // orderFrontRegardless keeps the windows on-screen even during the brief
        // inactive phase caused by switching from .regular to .accessory.
        for window in windows.reversed() {
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        (keyWindow ?? windows.first)?.makeKey()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: appLocalized("退出 WhistleYoo"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: appLocalized("编辑"))
        editMenuItem.submenu = editMenu
        editMenu.addItem(
            withTitle: appLocalized("撤销"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redoItem = editMenu.addItem(
            withTitle: appLocalized("重做"),
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: appLocalized("剪切"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: appLocalized("复制"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: appLocalized("粘贴"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: appLocalized("全选"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        updateStatusIcon()
    }

    private func configurePopover() {
        let rootView = StatusPopoverView(
            state: state,
            openConsole: { [weak self] in self?.openMainWindow(tab: .console) },
            openSettings: { [weak self] in self?.openMainWindow(tab: .settings) },
            openOnboarding: { [weak self] in self?.showOnboarding(reset: false) },
            openMobileSetup: { [weak self] in self?.openMainWindow(tab: .mobile) },
            quit: { NSApp.terminate(nil) }
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: rootView)
    }

    @objc private func handleStatusItemClick(_ button: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseDown {
            showStatusMenu(from: button)
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        popover.performClose(nil)
        rebuildStatusMenu()
        button.highlight(true)
        defer { button.highlight(false) }
        NSMenu.popUpContextMenu(statusMenu, with: event, for: button)
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        statusMenu.autoenablesItems = false

        let statusItem = NSMenuItem(
            title: "WhistleYoo · \(state.statusTitle)",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        statusMenu.addItem(statusItem)

        let descriptionItem = NSMenuItem(
            title: state.engineDescription,
            action: nil,
            keyEquivalent: ""
        )
        descriptionItem.isEnabled = false
        statusMenu.addItem(descriptionItem)
        statusMenu.addItem(.separator())

        if state.needsOnboarding || isEnvironmentUnavailable {
            addStatusMenuItem(
                title: appLocalized("运行设置引导"),
                action: #selector(openOnboardingFromStatusMenu(_:)),
                isEnabled: !state.isTransitioning
            )
        } else {
            let isRunningOrStopping: Bool
            switch state.engineState {
            case .running, .stopping:
                isRunningOrStopping = true
            case .starting, .stopped, .failed:
                isRunningOrStopping = false
            }
            addStatusMenuItem(
                title: appLocalized(isRunningOrStopping ? "停止代理引擎" : "启动代理引擎"),
                action: #selector(toggleEngineFromStatusMenu(_:)),
                isEnabled: !state.isTransitioning
            )
        }

        let proxyItem = addStatusMenuItem(
            title: appLocalized("全局系统代理"),
            action: #selector(toggleSystemProxyFromStatusMenu(_:)),
            isEnabled: state.isEngineRunning && !state.isTransitioning
        )
        switch state.systemProxyStatus {
        case .enabledByThisApp:
            proxyItem.state = .on
        case .partiallyEnabled:
            proxyItem.state = .mixed
        case .disabled, .configuredByOther, .unavailable:
            proxyItem.state = .off
        }

        statusMenu.addItem(.separator())
        addStatusMenuItem(
            title: appLocalized("Whistle 面板"),
            action: #selector(openConsoleFromStatusMenu(_:)),
            isEnabled: !state.isTransitioning
        )
        addStatusMenuItem(
            title: appLocalized("手机代理"),
            action: #selector(openMobileSetupFromStatusMenu(_:)),
            isEnabled: !state.isTransitioning
        )
        addStatusMenuItem(
            title: appLocalized("更多设置"),
            action: #selector(openSettingsFromStatusMenu(_:))
        )

        statusMenu.addItem(.separator())
        addStatusMenuItem(
            title: appLocalized("检查更新…"),
            action: #selector(checkForUpdatesFromStatusMenu(_:)),
            isEnabled: UpdateController.shared.canCheckForUpdates
        )

        statusMenu.addItem(.separator())
        addStatusMenuItem(
            title: appLocalized("退出 WhistleYoo"),
            action: #selector(quitFromStatusMenu(_:))
        )
    }

    @discardableResult
    private func addStatusMenuItem(
        title: String,
        action: Selector,
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        statusMenu.addItem(item)
        return item
    }

    private var isEnvironmentUnavailable: Bool {
        if case .unavailable = state.environmentStatus { return true }
        return false
    }

    @objc private func toggleEngineFromStatusMenu(_ sender: NSMenuItem) {
        switch state.engineState {
        case .running:
            Task { await state.stopEngine() }
        case .starting, .stopping:
            break
        case .stopped, .failed:
            Task { await state.startEngine() }
        }
    }

    @objc private func toggleSystemProxyFromStatusMenu(_ sender: NSMenuItem) {
        Task { await state.toggleSystemProxy() }
    }

    @objc private func openConsoleFromStatusMenu(_ sender: NSMenuItem) {
        openMainWindow(tab: .console)
    }

    @objc private func openMobileSetupFromStatusMenu(_ sender: NSMenuItem) {
        openMainWindow(tab: .mobile)
    }

    @objc private func openSettingsFromStatusMenu(_ sender: NSMenuItem) {
        openMainWindow(tab: .settings)
    }

    @objc private func openOnboardingFromStatusMenu(_ sender: NSMenuItem) {
        showOnboarding(reset: false)
    }

    @objc private func checkForUpdatesFromStatusMenu(_ sender: NSMenuItem) {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func quitFromStatusMenu(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        Task { await state.refreshSystemProxyStatus() }
        updatePopoverContentSize(maximumSize: button.window?.screen?.visibleFrame.size)
        // 先激活 app，再展示 popover 并让其成为 key window，
        // 这样弹出即聚焦、控件首次点击即响应；.transient 行为保证点击外部自动关闭（非锁定）。
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updatePopoverContentSize(maximumSize: NSSize?) {
        guard let hostingController = popover.contentViewController as? NSHostingController<StatusPopoverView> else {
            return
        }
        let fittingSize = hostingController.sizeThatFits(in: NSSize(
            width: 350,
            height: CGFloat.greatestFiniteMagnitude
        ))
        guard fittingSize.width.isFinite, fittingSize.height.isFinite,
              fittingSize.width > 0, fittingSize.height > 0,
              maximumSize.map({ fittingSize.width <= $0.width && fittingSize.height <= $0.height }) ?? true
        else { return }
        popover.contentSize = fittingSize
    }

    private func openMainWindow(tab: MainWorkspaceTab) {
        let preferredScreen = statusItem?.button?.window?.screen
            ?? mainWindowController?.window?.screen
            ?? NSScreen.main
        popover.performClose(nil)
        if mainWindowController == nil {
            mainWindowController = MainWindowController(
                state: state,
                consoleSession: consoleSession,
                initialTab: tab,
                exportCertificate: { [weak self] in self?.exportCertificate() },
                runOnboarding: { [weak self] in self?.showOnboarding(reset: true) }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.show(tab: tab, centeredOn: preferredScreen)
    }

    private func showOnboarding(reset: Bool) {
        let preferredScreen = statusItem?.button?.window?.screen ?? NSScreen.main
        popover.performClose(nil)
        if reset {
            state.resetOnboarding()
        }
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(
                state: state,
                completion: { [weak self] in
                    self?.onboardingWindowController?.close()
                    self?.onboardingWindowController = nil
                }
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.showCentered(on: preferredScreen)
    }

    private func exportCertificate() {
        Task {
            do {
                let certificate = try await state.certificateData()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "WhistleYoo-rootCA.crt"
                panel.allowedContentTypes = [.x509Certificate]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try certificate.write(to: url, options: .atomic)
            } catch {
                showError(error)
            }
        }
    }

    private func updateStatusIcon(force: Bool = false) {
        guard let button = statusItem?.button else { return }

        let status = state.applicationStatus
        let previousStatus = lastRenderedStatus
        let statusChanged = previousStatus != status
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldCrossfade = previousStatus != nil && statusChanged && !reduceMotion

        updateStatusItemMetadata(button)
        guard statusChanged || force else { return }
        lastRenderedStatus = status

        guard !reduceMotion, let animation = StatusBarAnimationKind(status: status) else {
            stopAnimation()
            renderStaticStatusIcon(for: status, crossfade: shouldCrossfade)
            return
        }

        startAnimation(animation, crossfade: shouldCrossfade)
    }

    private func updateStatusItemMetadata(_ button: NSStatusBarButton) {
        button.toolTip = "WhistleYoo · \(state.statusTitle)\n\(state.engineDescription)"
        button.setAccessibilityLabel("WhistleYoo · \(state.statusTitle)")
        button.setAccessibilityHelp(state.engineDescription)
    }

    private func renderStaticStatusIcon(for status: ApplicationStatus, crossfade: Bool) {
        let descriptor = status.statusBarIcon
        let animationStyle = StatusBarAnimationKind(status: status)
        guard let image = StatusBarIconRenderer.image(
            baseSymbolName: descriptor.baseSymbolName,
            badgeSymbolName: descriptor.badgeSymbolName,
            accessibilityDescription: nil,
            badgeBoundsOverride: animationStyle?.badgeBounds,
            badgePointSizeOverride: animationStyle?.badgePointSize
        ) else { return }

        setStatusIcon(image, crossfade: crossfade)
    }

    private func setStatusIcon(_ image: NSImage, crossfade: Bool) {
        guard let button = statusItem?.button else { return }
        if crossfade {
            button.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.2
            button.layer?.add(transition, forKey: "iconTransition")
        } else {
            button.layer?.removeAnimation(forKey: "iconTransition")
        }
        button.image = image
    }

    private func startAnimation(_ kind: StatusBarAnimationKind, crossfade: Bool) {
        stopAnimation()
        currentAnimationKind = kind
        animationFrameIndex = 0

        guard renderAnimationFrame(crossfade: crossfade) else {
            stopAnimation()
            renderStaticStatusIcon(for: state.applicationStatus, crossfade: crossfade)
            return
        }

        animationTimer = Timer.scheduledTimer(
            timeInterval: kind.interval,
            target: self,
            selector: #selector(advanceStatusIconAnimation),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func advanceStatusIconAnimation() {
        guard let kind = currentAnimationKind else {
            stopAnimation()
            return
        }

        let nextFrameIndex = animationFrameIndex + 1
        if let totalFrameCount = kind.totalFrameCount,
           nextFrameIndex >= totalFrameCount {
            // Entry animations finish on their fully opaque frame. Keep that
            // cached image in place instead of starting a permanent timer.
            stopAnimation()
            return
        }

        animationFrameIndex = nextFrameIndex
        if !renderAnimationFrame(crossfade: false) {
            stopAnimation()
            renderStaticStatusIcon(for: state.applicationStatus, crossfade: false)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        currentAnimationKind = nil
        animationFrameIndex = 0
    }

    @discardableResult
    private func renderAnimationFrame(crossfade: Bool) -> Bool {
        guard let kind = currentAnimationKind else { return false }
        let frames = cachedAnimationFrames(for: kind)
        guard !frames.isEmpty else { return false }

        setStatusIcon(frames[animationFrameIndex % frames.count], crossfade: crossfade)
        return true
    }

    private func cachedAnimationFrames(for kind: StatusBarAnimationKind) -> [NSImage] {
        if let cachedFrames = animationFrameCache[kind] {
            return cachedFrames
        }

        let renderedFrames = kind.frames.compactMap { frame in
            StatusBarIconRenderer.image(
                baseSymbolName: "globe",
                badgeSymbolName: kind.badgeSymbolName,
                accessibilityDescription: nil,
                badgeBoundsOverride: kind.badgeBounds,
                badgePointSizeOverride: kind.badgePointSize,
                badgeOpacityOverride: frame.opacity,
                badgeScaleOverride: frame.scale
            )
        }
        guard renderedFrames.count == kind.frames.count else { return [] }
        animationFrameCache[kind] = renderedFrames
        return renderedFrames
    }

    private func showError(_ error: Error) {
        guard !terminationInProgress else { return }
        let alert = NSAlert(error: error)
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showMessage(_ message: String) {
        guard !terminationInProgress else { return }
        let alert = NSAlert()
        alert.messageText = "WhistleYoo"
        alert.informativeText = message
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showTerminationError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = appLocalized("无法安全退出 WhistleYoo")
        alert.informativeText = appLocalizedFormat(
            "系统代理或代理引擎未能安全关闭，应用将继续运行。请重试；若仍失败，请检查网络代理设置。\n\n%@",
            error.localizedDescription
        )
        alert.addButton(withTitle: appLocalized("好"))
        alert.runModal()
    }
}

private enum StatusBarIconRenderer {
    private static let canvasSize = NSSize(width: 24, height: 18)
    private static let baseBounds = NSRect(x: 0, y: 1, width: 17, height: 17)
    private static let badgeBounds = NSRect(x: 13, y: 1, width: 10, height: 10)

    static func image(
        baseSymbolName: String,
        badgeSymbolName: String,
        accessibilityDescription: String?,
        badgeBoundsOverride: NSRect? = nil,
        badgePointSizeOverride: CGFloat? = nil,
        badgeOpacityOverride: CGFloat? = nil,
        badgeScaleOverride: CGFloat? = nil
    ) -> NSImage? {
        let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let effectivePointSize = badgePointSizeOverride ?? 10
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: effectivePointSize, weight: .semibold)
        guard let baseImage = NSImage(
            systemSymbolName: baseSymbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(baseConfiguration),
        let badgeImage = NSImage(
            systemSymbolName: badgeSymbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(badgeConfiguration) else {
            return nil
        }

        let unscaledBadgeBounds = badgeBoundsOverride ?? badgeBounds
        let effectiveBadgeBounds = scaledRect(
            unscaledBadgeBounds,
            by: badgeScaleOverride ?? 1
        )
        let effectiveBadgeOpacity = min(max(badgeOpacityOverride ?? 1, 0), 1)
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            baseImage.draw(in: fittedRect(for: baseImage.size, inside: baseBounds))

            // Keep a transparent halo around the badge so the globe lines never
            // merge into the smaller state glyph at menu-bar scale.
            let previousOperation = NSGraphicsContext.current?.compositingOperation
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: effectiveBadgeBounds.insetBy(dx: -1.0, dy: -1.0)).fill()
            NSGraphicsContext.current?.compositingOperation = previousOperation ?? .sourceOver

            badgeImage.draw(
                in: fittedRect(for: badgeImage.size, inside: effectiveBadgeBounds),
                from: NSRect(origin: .zero, size: badgeImage.size),
                operation: .sourceOver,
                fraction: effectiveBadgeOpacity
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func scaledRect(_ rect: NSRect, by scale: CGFloat) -> NSRect {
        let safeScale = max(scale, 0.1)
        let size = NSSize(width: rect.width * safeScale, height: rect.height * safeScale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func fittedRect(for imageSize: NSSize, inside bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct StatusBarAnimationFrame: Hashable {
    let opacity: CGFloat
    let scale: CGFloat
}

/// Entry animations are finite; only a real engine transition repeats.
private enum StatusBarAnimationKind: Hashable {
    case listeningEntry
    case proxyEnabledEntry
    case transitioning

    init?(status: ApplicationStatus) {
        switch status.statusBarAnimationBehavior {
        case .none:
            return nil
        case .entryPulse:
            switch status {
            case .listeningOnly: self = .listeningEntry
            case .systemProxyEnabled: self = .proxyEnabledEntry
            case .transitioning, .stopped, .attention, .unavailable: return nil
            }
        case .continuousPulse:
            guard status == .transitioning else { return nil }
            self = .transitioning
        }
    }

    var badgeSymbolName: String {
        switch self {
        case .listeningEntry: return "waveform"
        case .proxyEnabledEntry: return "bolt.fill"
        case .transitioning: return "ellipsis.circle.fill"
        }
    }

    var frames: [StatusBarAnimationFrame] {
        switch self {
        case .listeningEntry:
            return [
                StatusBarAnimationFrame(opacity: 0.68, scale: 0.94),
                StatusBarAnimationFrame(opacity: 1.0, scale: 1.0)
            ]
        case .proxyEnabledEntry:
            return [
                StatusBarAnimationFrame(opacity: 0.70, scale: 0.94),
                StatusBarAnimationFrame(opacity: 1.0, scale: 1.0)
            ]
        case .transitioning:
            return [
                StatusBarAnimationFrame(opacity: 0.55, scale: 0.94),
                StatusBarAnimationFrame(opacity: 1.0, scale: 1.0)
            ]
        }
    }

    var interval: TimeInterval {
        switch self {
        case .listeningEntry: return 0.55
        case .proxyEnabledEntry: return 0.35
        case .transitioning: return 0.45
        }
    }

    /// Finite entry animations pulse twice and end on the fully opaque frame.
    /// A nil value means the transition animation repeats until state changes.
    var totalFrameCount: Int? {
        switch self {
        case .listeningEntry, .proxyEnabledEntry: return frames.count * 2
        case .transitioning: return nil
        }
    }

    var badgeBounds: NSRect {
        switch self {
        case .listeningEntry: return NSRect(x: 12, y: 1.5, width: 11, height: 8.5)
        case .proxyEnabledEntry: return NSRect(x: 13, y: 1.25, width: 9.5, height: 9.5)
        case .transitioning: return NSRect(x: 13, y: 1, width: 10, height: 10)
        }
    }

    var badgePointSize: CGFloat {
        switch self {
        case .listeningEntry: return 9.0
        case .proxyEnabledEntry: return 10.0
        case .transitioning: return 9.5
        }
    }
}
