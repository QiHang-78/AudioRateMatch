import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = MatchEngine()
    var item: NSStatusItem!
    let menu = NSMenu()
    let sourceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let formatItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let outputItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let physicalItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "暂停自动切换", action: #selector(toggle), keyEquivalent: "")
    let sourcesMenu = NSMenu()
    let devicesMenu = NSMenu()
    var statusWindow: NSWindow?
    let windowStatus = NSTextField(wrappingLabelWithString: "")
    let windowDevice = NSTextField(wrappingLabelWithString: "")
    let windowSources = NSTextField(wrappingLabelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleIdentifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        engine.preferredUID = UserDefaults.standard.string(forKey: "outputUID")
        engine.preferredSource = UserDefaults.standard.string(forKey: "sourceKey")
        menu.delegate = self
        restoreStatusItem()
        menu.addItem(NSMenuItem(title: "AudioRateMatch · 系统采样率跟随", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        [sourceItem, formatItem, outputItem, physicalItem, stateItem].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        let sources = NSMenuItem(title: "跟随应用", action: nil, keyEquivalent: ""); sources.submenu = sourcesMenu; menu.addItem(sources)
        let devices = NSMenuItem(title: "输出设备", action: nil, keyEquivalent: ""); devices.submenu = devicesMenu; menu.addItem(devices)
        toggleItem.target = self; menu.addItem(toggleItem)
        add("重新检测", #selector(retry))
        add("显示状态窗口", #selector(showStatus))
        add("打开音频 MIDI 设置", #selector(openMIDI))
        add("复制诊断信息", #selector(copyReport))
        add("查看运行日志", #selector(openLog))
        menu.addItem(.separator()); add("退出 AudioRateMatch", #selector(quit), key: "q")
        engine.onUpdate = { [weak self] in self?.refresh() }
        engine.start(); refresh()
        let version = AppInfo.version
        if UserDefaults.standard.string(forKey: "lastShownVersion") != version {
            showStatus(); UserDefaults.standard.set(version, forKey: "lastShownVersion")
        }
    }
    func add(_ title: String, _ action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
    }
    @objc func restoreStatusItem() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "AudioRateMatch.StatusItem"
        item.isVisible = true
        item.menu = menu
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let bars = NSBezierPath()
            bars.lineWidth = 1.8; bars.lineCapStyle = .round
            for (index, height) in [4.0, 9.0, 15.0, 9.0, 4.0].enumerated() {
                let x = 3.0 + Double(index) * 3.0
                bars.move(to: NSPoint(x: x, y: 9.0 - height / 2))
                bars.line(to: NSPoint(x: x, y: 9.0 + height / 2))
            }
            bars.stroke(); return true
        }
        image.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        item.button?.setAccessibilityTitle("AudioRateMatch")
        refresh()
    }
    func refresh() {
        let names = engine.resolution.names
        sourceItem.title = "播放来源：" + (names.isEmpty ? "等待应用播放" : String(names.prefix(70)))
        formatItem.title = "播放流：\(engine.sourceRate.map { rateText($0) + " kHz" } ?? "未确认或冲突")"
        outputItem.title = engine.output.map { "系统输出：\($0.name) · \(rateText($0.rate)) kHz" } ?? "系统输出：未连接"
        physicalItem.title = "硬件回读：\(engine.output?.physicalRates.map { rateText($0) + " kHz" }.joined(separator: ", ") ?? "—")"
        stateItem.title = engine.state
        let rate = engine.output.map { rateText($0.rate) } ?? "—"
        item.button?.appearsDisabled = !engine.enabled
        item.button?.toolTip = "AudioRateMatch · \(rate) kHz\n" + engine.state + "\n" + sourceItem.title
        item.button?.setAccessibilityValue(engine.enabled ? "\(rate) kHz · \(engine.state)" : "已暂停自动切换")
        toggleItem.title = engine.enabled ? "暂停自动切换" : "恢复自动切换"
        windowStatus.stringValue = engine.state
        windowDevice.stringValue = outputItem.title + "\n" + physicalItem.title
        let lines = engine.resolution.observations.map { "\($0.client.name)  ·  \($0.rate.map { rateText($0) + " kHz" } ?? "格式未确认")" }
        windowSources.stringValue = lines.isEmpty ? "等待应用播放音频。" : lines.prefix(6).joined(separator: "\n")
    }
    func menuWillOpen(_ menu: NSMenu) {
        engine.tick()
        devicesMenu.removeAllItems(); sourcesMenu.removeAllItems()
        let follow = NSMenuItem(title: "跟随系统默认输出", action: #selector(selectDevice(_:)), keyEquivalent: "")
        follow.target = self; follow.state = engine.preferredUID == nil ? .on : .off; devicesMenu.addItem(follow)
        devicesMenu.addItem(.separator())
        for device in Hardware.devices() {
            let entry = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = device.uid
            entry.state = engine.preferredUID == device.uid ? .on : .off; devicesMenu.addItem(entry)
        }
        let automatic = NSMenuItem(title: "自动跟随所有应用", action: #selector(selectSource(_:)), keyEquivalent: "")
        automatic.target = self; automatic.state = engine.preferredSource == nil ? .on : .off
        sourcesMenu.addItem(automatic); sourcesMenu.addItem(.separator())
        let groups = Dictionary(grouping: engine.clients.filter {
            $0.running || !$0.deviceIDs.isEmpty || NSRunningApplication(processIdentifier: $0.pid)?.activationPolicy == .regular
        }, by: \.selectionKey)
        for (key, clients) in groups.sorted(by: { $0.value[0].name.localizedStandardCompare($1.value[0].name) == .orderedAscending }) {
            let active = clients.filter(\.running)
            let rates = Array(Set(active.compactMap { engine.observedRate(for: $0) })).sorted()
            let detail = active.isEmpty ? "未播放" : rates.isEmpty ? "格式未确认" : rates.map { rateText($0) }.joined(separator: "/") + " kHz"
            let entry = NSMenuItem(title: "\(clients[0].name) · \(detail)", action: #selector(selectSource(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = key; entry.state = engine.preferredSource == key ? .on : .off
            sourcesMenu.addItem(entry)
        }
        if let preferred = engine.preferredSource, groups[preferred] == nil {
            let entry = NSMenuItem(title: "所选应用未运行：\(preferred)", action: nil, keyEquivalent: "")
            entry.state = .on; sourcesMenu.addItem(entry)
        }
        sourcesMenu.addItem(.separator())
        sourcesMenu.addItem(NSMenuItem(title: "格式未确认时保持当前采样率", action: nil, keyEquivalent: ""))
    }
    @objc func selectDevice(_ sender: NSMenuItem) {
        engine.preferredUID = sender.representedObject as? String
        UserDefaults.standard.set(engine.preferredUID, forKey: "outputUID"); engine.changedSelection()
    }
    @objc func selectSource(_ sender: NSMenuItem) {
        engine.preferredSource = sender.representedObject as? String
        UserDefaults.standard.set(engine.preferredSource, forKey: "sourceKey"); engine.changedSelection()
    }
    @objc func toggle() { engine.enabled.toggle(); engine.changedSelection() }
    @objc func retry() { engine.retry() }
    @objc func showStatus() {
        if statusWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AudioRateMatch"; window.isReleasedWhenClosed = false; window.center()
            let title = NSTextField(labelWithString: "系统采样率，跟随正在播放的应用")
            title.font = .systemFont(ofSize: 19, weight: .semibold)
            windowStatus.font = .systemFont(ofSize: 14, weight: .medium)
            let note = NSTextField(wrappingLabelWithString: "自动模式在播放流采样率一致时切换；未确认或冲突时保持当前设置。\n点击菜单栏的波形图标，或下方「更多操作」，可指定跟随应用和输出设备。")
            note.textColor = .secondaryLabelColor
            let controls = NSButton(title: "更多操作", target: self, action: #selector(showControls(_:)))
            let midi = NSButton(title: "打开音频 MIDI 设置", target: self, action: #selector(openMIDI))
            let restore = NSButton(title: "恢复菜单栏图标", target: self, action: #selector(restoreStatusItem))
            let buttons = NSStackView(views: [controls, midi, restore]); buttons.orientation = .horizontal; buttons.spacing = 12
            let stack = NSStackView(views: [title, windowStatus, windowDevice, windowSources, note, buttons])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
            ])
            statusWindow = window
        }
        refresh(); statusWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showControls(_ sender: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc func openMIDI() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")) }
    @objc func copyReport() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(engine.report, forType: .string) }
    @objc func openLog() { NSWorkspace.shared.open(MatchEngine.logURL) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreStatusItem(); showStatus(); return true
    }
    func applicationWillTerminate(_ notification: Notification) { engine.stop() }
}
