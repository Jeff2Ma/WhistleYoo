import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppStateController()
    private let consoleSession = WhistleConsoleSession()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindowController: MainWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateController.shared.start()
        configureMainMenu()
        configureStateCallbacks()
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
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
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

    @objc private func togglePopover() {
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

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let descriptor = state.applicationStatus.statusBarIcon
        button.image = StatusBarIconRenderer.image(
            baseSymbolName: descriptor.baseSymbolName,
            badgeSymbolName: descriptor.badgeSymbolName,
            accessibilityDescription: state.statusTitle
        )
        button.toolTip = "WhistleYoo · \(state.statusTitle)"
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
    private static let badgeBounds = NSRect(x: 13, y: 0, width: 11, height: 11)

    static func image(
        baseSymbolName: String,
        badgeSymbolName: String,
        accessibilityDescription: String
    ) -> NSImage? {
        let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let badgeConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
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

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            baseImage.draw(in: fittedRect(for: baseImage.size, inside: baseBounds))

            // Keep a transparent halo around the badge so the globe lines never
            // merge into the smaller state glyph at menu-bar scale.
            let previousOperation = NSGraphicsContext.current?.compositingOperation
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badgeBounds.insetBy(dx: -0.75, dy: -0.75)).fill()
            NSGraphicsContext.current?.compositingOperation = previousOperation ?? .sourceOver

            badgeImage.draw(in: fittedRect(for: badgeImage.size, inside: badgeBounds))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
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
