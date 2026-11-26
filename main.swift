import AppKit
import Carbon
import ServiceManagement

struct Item {
    let url: URL
    let name: String
    static func installed() -> [Item] {
        let fm = FileManager.default
        var items = [Item]()
        var seen = Set<String>()
        for path in ["~/Applications", "/Applications", "/System/Applications"] {
            let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files where url.pathExtension == "app" {
                files.skipDescendants()
                guard let bundle = Bundle(url: url), bundle.executableURL != nil,
                      bundle.bundleIdentifier != Bundle.main.bundleIdentifier,
                      seen.insert(bundle.bundleIdentifier ?? url.path).inserted else { continue }
                let display = fm.displayName(atPath: url.path)
                items.append(Item(url: url, name: display.hasSuffix(".app") ? String(display.dropLast(4)) : display))
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

final class Panel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppTile: NSButton {}

final class SearchSurface: NSView {
    weak var field: NSTextField?

    override func mouseDown(with event: NSEvent) {
        if let field { window?.makeFirstResponder(field) }
    }
}

struct Shortcut: Codable, Equatable {
    let key: UInt32
    let flags: UInt32
    let label: String

    static let standard = Shortcut(key: UInt32(kVK_Space), flags: UInt32(optionKey | shiftKey), label: "⌥⇧空格")

    init(key: UInt32, flags: UInt32, label: String) {
        self.key = key
        self.flags = flags
        self.label = label
    }

    static let modifiers: [(flag: UInt32, label: String)] = [
        (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
        (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")
    ]
    static let supportedFlags = modifiers.reduce(UInt32(0)) { $0 | $1.flag }
    static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                               kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
    static let keys: [(code: UInt32, label: String)] = {
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
            kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
            kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
            kVK_ANSI_Y, kVK_ANSI_Z
        ]
        let numbers = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                       kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let special = [(kVK_Space, "空格"), (kVK_Tab, "Tab"), (kVK_Return, "回车"), (kVK_Delete, "删除"),
                       (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓")]
        let pairs = special + Array(zip(letters, "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)))
            + Array(zip(numbers, numbers.indices.map(String.init)))
            + Array(zip(Self.functionKeys, Self.functionKeys.indices.map { "F" + String($0 + 1) }))
        return pairs.map { (UInt32($0.0), $0.1) }
    }()

    var isUsedBySystem: Bool {
        if key == kVK_Tab, flags == UInt32(cmdKey) || flags == UInt32(cmdKey | shiftKey) {
            return true
        }
        let hasSyntheticFn = Self.functionKeys.contains(Int(key))
        let navigation = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        let mask = Self.supportedFlags | (hasSyntheticFn || navigation.contains(Int(key)) ? 0 : UInt32(kEventKeyModifierFnMask))
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let entries = raw?.takeRetainedValue() as? [[String: NSNumber]] else { return false }
        return entries.contains { entry in
            entry["kHISymbolicHotKeyEnabled"]?.boolValue == true
                && entry["kHISymbolicHotKeyCode"]?.uint32Value == key
                && entry["kHISymbolicHotKeyModifiers"].map { $0.uint32Value & mask } == flags
        }
    }
}

final class Launcher: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: Panel!
    let background = NSVisualEffectView()
    let grid = NSView()
    let searchSurface = SearchSurface()
    let pageIndicators = NSView()
    let search = NSTextField()
    let clearSearch = NSButton()
    var dragStart: NSPoint?
    var pressedTile: AppTile?
    var dragDistance: CGFloat = 0
    let settings = NSButton()
    let preferences = NSPopover()
    let defaults = UserDefaults.standard
    let shortcutButton = NSButton()
    let loginButton = NSButton()
    let loginMessage = NSTextField(labelWithString: "")
    let shortcutEditor = NSView()
    let shortcutKey = NSPopUpButton()
    var shortcutModifiers = [NSButton]()
    let shortcutMessage = NSTextField(labelWithString: "")
    var shortcut = Shortcut.standard
    var hotKeyHandler: EventHandlerRef?
    var hotKey: EventHotKeyRef?
    var hotKeyID: UInt32 = 0
    var isPresented = false
    var presentationID = 0
    let rowOptions = 2...8
    let columnOptions = 3...10
    var rows = 4
    var columns = 7
    let apps = Item.installed()
    var results = [Item]()
    var page = 0
    var pages = 1
    var monitor: Any?
    var spaceObserver: NSObjectProtocol?
    var horizontalTravel: CGFloat = 0
    var verticalTravel: CGFloat = 0
    var lastScroll = -1.0
    var paged = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        window = Panel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .mainMenu + 1
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        window.contentView = background
        window.setFrame(screen.frame, display: true)
        grid.frame = background.bounds
        background.addSubview(grid)
        pageIndicators.frame = NSRect(
            x: 0, y: background.bounds.height * 0.07,
            width: background.bounds.width, height: 26
        )
        background.addSubview(pageIndicators)
        defaults.register(defaults: ["gridRows": 4, "gridColumns": 7])
        rows = min(rowOptions.upperBound, max(rowOptions.lowerBound, defaults.integer(forKey: "gridRows")))
        columns = min(columnOptions.upperBound, max(columnOptions.lowerBound, defaults.integer(forKey: "gridColumns")))
        if let saved = defaults.data(forKey: "launcherShortcut"),
           let decoded = try? JSONDecoder().decode(Shortcut.self, from: saved) {
            shortcut = decoded
        }
        configureToolbar()
        installHotKey()
        results = apps
        drawPage()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .swipe, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.closeLauncher(animated: false)
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let openedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !openedAtLogin { showLauncher() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showLauncher()
        return false
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        focusLauncher()
    }
    func showLauncher() {
        guard let window else { return }
        guard !isPresented else {
            focusLauncher()
            return
        }
        presentationID += 1
        isPresented = true
        search.stringValue = ""
        updateSearch()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = window.isVisible
        if !wasVisible { window.alphaValue = reduceMotion ? 1 : 0 }
        NSApp.unhideWithoutActivation()
        NSApp.activate(ignoringOtherApps: true)
        focusLauncher()

        if reduceMotion {
            clearPresentationAnimations()
            window.alphaValue = 1
        } else {
            if !wasVisible {
                animateEntrance(searchSurface, offset: 10, scale: 0.985, delay: 0.025, duration: 0.27)
                animateEntrance(settings, offset: 8, scale: 0.985, delay: 0.025, duration: 0.27)
                animateEntrance(grid, offset: 17, scale: 0.98, delay: 0.045, duration: 0.32)
                animateEntrance(pageIndicators, offset: 0, scale: 1, delay: 0.10, duration: 0.19)
            } else {
                clearPresentationAnimations()
            }
            fadeWindow(to: 1, duration: 0.22)
        }
    }
    func focusLauncher() {
        guard isPresented else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeFirstResponder(search)
    }
    func applicationDidResignActive(_ notification: Notification) {
        closeLauncher(animated: false)
    }
    func closeLauncher(animated: Bool = true) {
        guard let window, isPresented || (!animated && window.isVisible) else { return }
        presentationID += 1
        let closingID = presentationID
        isPresented = false
        preferences.close()
        shortcutEditor.isHidden = true

        let finish = { [weak self] in
            guard let self, self.presentationID == closingID, !self.isPresented else { return }
            self.window.orderOut(nil)
            self.clearPresentationAnimations()
            if NSApp.isActive { NSApp.hide(nil) }
        }
        if animated && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fadeWindow(to: 0, duration: 0.15, completion: finish)
        } else {
            finish()
        }
    }

    func fadeWindow(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.75, 0.25, 1)
            window.animator().alphaValue = alpha
        } completionHandler: {
            completion?()
        }
    }

    func animateEntrance(_ view: NSView, offset: CGFloat, scale: CGFloat, delay: TimeInterval, duration: TimeInterval) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration

        let motion = CABasicAnimation(keyPath: "transform")
        motion.fromValue = CATransform3DScale(CATransform3DMakeTranslation(0, -offset, 0), scale, scale, 1)
        motion.toValue = CATransform3DIdentity
        motion.duration = duration

        let entrance = CAAnimationGroup()
        entrance.animations = [fade, motion]
        entrance.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        entrance.duration = duration
        entrance.fillMode = .backwards
        entrance.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.30, 1)
        layer.add(entrance, forKey: "launcherEntrance")
    }

    func clearPresentationAnimations() {
        for view in [searchSurface, settings, grid, pageIndicators] {
            view.layer?.removeAnimation(forKey: "launcherEntrance")
        }
    }

    func installHotKey() {
        let eventTypes = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let launcher = Unmanaged<Launcher>.fromOpaque(context).takeUnretainedValue()
            var identity = EventHotKeyID()
            let result = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identity
            )
            guard result == noErr, identity.signature == 0x4C4F5358, identity.id == launcher.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            guard GetEventKind(event) == UInt32(kEventHotKeyReleased) else { return noErr }
            if launcher.preferences.isShown {
                launcher.shortcutMessage.stringValue = "已收到 " + launcher.shortcut.label
            } else if launcher.isPresented {
                launcher.closeLauncher()
            } else {
                launcher.showLauncher()
            }
            return noErr
        }, eventTypes.count, eventTypes, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        if status == noErr, !shortcut.isUsedBySystem, registerShortcut(shortcut) { return }
        if status == noErr, shortcut != .standard, !Shortcut.standard.isUsedBySystem, registerShortcut(.standard) {
            shortcut = .standard
            defaults.removeObject(forKey: "launcherShortcut")
            shortcutButton.title = shortcut.label
            shortcutMessage.stringValue = "原组合键不可用，已恢复默认"
        } else {
            shortcutMessage.stringValue = "快捷键不可用，请更换组合键"
        }
    }
    func registerShortcut(_ candidate: Shortcut) -> Bool {
        guard hotKeyHandler != nil else { return false }
        if hotKey != nil, candidate.key == shortcut.key, candidate.flags == shortcut.flags { return true }
        let nextID = hotKeyID &+ 1
        let identity = EventHotKeyID(signature: 0x4C4F5358, id: nextID)
        var registration: EventHotKeyRef?
        let target = GetApplicationEventTarget()
        var status = RegisterEventHotKey(
            candidate.key, candidate.flags, identity, target,
            UInt32(kEventHotKeyExclusive), &registration
        )
        // macOS can retain a shared reservation for Command-Space after Spotlight is disabled.
        if status == eventHotKeyExistsErr, candidate.key == kVK_Space,
           candidate.flags == UInt32(cmdKey), !candidate.isUsedBySystem {
            status = RegisterEventHotKey(candidate.key, candidate.flags, identity, target, 0, &registration)
        }
        guard status == noErr, let registration else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = registration
        hotKeyID = nextID
        return true
    }
    @objc func editShortcut() {
        if !shortcutEditor.isHidden {
            shortcutEditor.isHidden = true
            return
        }
        if shortcutKey.selectItem(withTag: Int(shortcut.key)) == false {
            shortcutKey.selectItem(withTag: kVK_Space)
        }
        for (button, modifier) in zip(shortcutModifiers, Shortcut.modifiers) {
            button.state = shortcut.flags & modifier.flag != 0 ? .on : .off
        }
        shortcutMessage.stringValue = "当前生效：" + (hotKey == nil ? "未设置" : shortcut.label)
        shortcutEditor.isHidden = false
    }
    @objc func saveShortcut() {
        guard let item = shortcutKey.selectedItem else { return }
        let selected = zip(shortcutModifiers, Shortcut.modifiers)
            .filter { $0.0.state == .on }.map { $0.1 }
        guard selected.contains(where: { $0.flag != UInt32(shiftKey) }) else {
            shortcutMessage.stringValue = "请至少选择 ⌃、⌥ 或 ⌘ 中的一项"
            return
        }
        let candidate = Shortcut(
            key: UInt32(item.tag), flags: selected.reduce(0) { $0 | $1.flag },
            label: selected.map { $0.label }.joined() + item.title
        )
        guard !candidate.isUsedBySystem else {
            shortcutMessage.stringValue = "macOS 已占用此组合键"
            return
        }
        guard registerShortcut(candidate) else {
            shortcutMessage.stringValue = "此组合键不可用，请换一个"
            return
        }
        shortcut = candidate
        defaults.set(try? JSONEncoder().encode(candidate), forKey: "launcherShortcut")
        shortcutButton.title = candidate.label
        shortcutMessage.stringValue = "已保存 " + candidate.label + "，可在这里试按"
    }

    func configureToolbar() {
        let bounds = background.bounds
        let top = bounds.height * 0.89
        let width = min(342, bounds.width * 0.55)
        let height: CGFloat = 46
        searchSurface.frame = NSRect(x: bounds.midX - width / 2, y: top, width: width, height: height)
        styleControl(searchSurface, radius: height / 2)
        searchSurface.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        searchSurface.field = search
        background.addSubview(searchSurface)

        let magnifier = NSImageView(frame: NSRect(x: 16, y: (height - 18) / 2, width: 18, height: 18))
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        magnifier.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        magnifier.contentTintColor = .secondaryLabelColor
        searchSurface.addSubview(magnifier)

        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 15)
        search.lineBreakMode = .byTruncatingTail
        search.usesSingleLineMode = true
        search.placeholderString = "搜索应用"
        search.setAccessibilityLabel("搜索应用")
        search.delegate = self
        search.sizeToFit()
        let fieldHeight = search.frame.height
        search.frame = NSRect(x: 44, y: (height - fieldHeight) / 2, width: width - 84, height: fieldHeight)
        searchSurface.addSubview(search)

        clearSearch.frame = NSRect(x: width - 38, y: (height - 30) / 2, width: 30, height: 30)
        clearSearch.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除搜索")
        clearSearch.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        clearSearch.contentTintColor = .secondaryLabelColor
        clearSearch.isBordered = false
        clearSearch.isHidden = true
        clearSearch.target = self
        clearSearch.action = #selector(resetSearch)
        searchSurface.addSubview(clearSearch)

        settings.frame = NSRect(x: bounds.width - max(76, bounds.width * 0.075), y: top, width: 44, height: 44)
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settings.symbolConfiguration = .init(pointSize: 19, weight: .medium)
        settings.isBordered = false
        settings.toolTip = "网格设置"
        settings.setAccessibilityLabel("设置")
        settings.target = self
        settings.action = #selector(toggleSettings)
        styleControl(settings, radius: 14)
        background.addSubview(settings)

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 309))
        let title = NSTextField(labelWithString: "网格设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 20, y: 268, width: 180, height: 22)
        content.view.addSubview(title)
        for (label, values, value, y) in [("行数", rowOptions, rows, 229), ("列数", columnOptions, columns, 191)] {
            let text = NSTextField(labelWithString: label)
            text.frame = NSRect(x: 20, y: y + 3, width: 88, height: 20)
            content.view.addSubview(text)
            let picker = NSPopUpButton(frame: NSRect(x: 190, y: y, width: 110, height: 26))
            picker.addItems(withTitles: values.map(String.init))
            picker.selectItem(withTitle: String(value))
            picker.setAccessibilityLabel(label)
            picker.tag = label == "行数" ? 0 : 1
            picker.target = self
            picker.action = #selector(changeDensity(_:))
            content.view.addSubview(picker)
        }
        let shortcutLabel = NSTextField(labelWithString: "全局快捷键")
        shortcutLabel.frame = NSRect(x: 20, y: 153, width: 110, height: 20)
        content.view.addSubview(shortcutLabel)
        shortcutButton.frame = NSRect(x: 190, y: 149, width: 110, height: 26)
        shortcutButton.title = shortcut.label
        shortcutButton.setAccessibilityLabel("编辑全局快捷键")
        shortcutButton.target = self
        shortcutButton.action = #selector(editShortcut)
        content.view.addSubview(shortcutButton)
        shortcutEditor.frame = NSRect(x: 20, y: 95, width: 280, height: 42)
        shortcutEditor.isHidden = true
        for (index, modifier) in Shortcut.modifiers.enumerated() {
            let check = NSButton(checkboxWithTitle: modifier.label, target: nil, action: nil)
            check.frame = NSRect(x: CGFloat(index) * 39, y: 10, width: 38, height: 24)
            check.setAccessibilityLabel(["Control", "Option", "Shift", "Command"][index])
            shortcutModifiers.append(check)
            shortcutEditor.addSubview(check)
        }
        shortcutKey.frame = NSRect(x: 157, y: 9, width: 61, height: 26)
        shortcutKey.setAccessibilityLabel("主键")
        for key in Shortcut.keys {
            shortcutKey.addItem(withTitle: key.label)
            shortcutKey.lastItem?.tag = Int(key.code)
        }
        shortcutEditor.addSubview(shortcutKey)
        let save = NSButton(title: "保存", target: self, action: #selector(saveShortcut))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: 222, y: 9, width: 58, height: 26)
        shortcutEditor.addSubview(save)
        content.view.addSubview(shortcutEditor)
        shortcutMessage.frame = NSRect(x: 20, y: 68, width: 280, height: 22)
        shortcutMessage.font = .systemFont(ofSize: 11)
        shortcutMessage.textColor = .secondaryLabelColor
        content.view.addSubview(shortcutMessage)
        let divider = NSBox(frame: NSRect(x: 20, y: 57, width: 280, height: 1))
        divider.boxType = .separator
        content.view.addSubview(divider)
        loginButton.setButtonType(.switch)
        loginButton.title = "登录时启动"
        loginButton.frame = NSRect(x: 20, y: 30, width: 280, height: 23)
        loginButton.target = self
        loginButton.action = #selector(changeLoginItem)
        content.view.addSubview(loginButton)
        loginMessage.frame = NSRect(x: 20, y: 10, width: 280, height: 17)
        loginMessage.font = .systemFont(ofSize: 11)
        loginMessage.textColor = .secondaryLabelColor
        content.view.addSubview(loginMessage)
        preferences.contentViewController = content
        preferences.behavior = .transient
    }
    func styleControl(_ view: NSView, radius: CGFloat) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.19).cgColor
    }
    @objc func toggleSettings() {
        if preferences.isShown {
            preferences.close()
            shortcutEditor.isHidden = true
        }
        else {
            shortcutEditor.isHidden = true
            refreshLoginItem()
            preferences.show(relativeTo: settings.bounds, of: settings, preferredEdge: .minY)
        }
    }
    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginButton.state = status == .enabled ? .on : .off
        loginMessage.stringValue = status == .requiresApproval
            ? "请在系统设置的「登录项与扩展」中允许 LaunchOS"
            : "登录后在后台等待全局快捷键"
    }
    @objc func changeLoginItem() {
        let service = SMAppService.mainApp
        do {
            if loginButton.state == .on {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                } else if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginMessage.stringValue = "更新登录项失败：\(error.localizedDescription)"
            loginMessage.toolTip = error.localizedDescription
        }
    }

    @objc func changeDensity(_ sender: NSPopUpButton) {
        guard let value = Int(sender.titleOfSelectedItem ?? "") else { return }
        let firstVisible = page * capacity
        if sender.tag == 0 {
            rows = value
            defaults.set(value, forKey: "gridRows")
        } else {
            columns = value
            defaults.set(value, forKey: "gridColumns")
        }
        page = firstVisible / capacity
        drawPage()
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53, NSApp.isActive {
            closeLauncher()
            return nil
        }
        guard event.window === window, isPresented else { return event }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return handleMouse(event)
        default:
            break
        }
        guard !preferences.isShown else { return event }
        if event.type == .swipe, event.deltaX != 0 {
            go(page + (event.deltaX < 0 ? 1 : -1))
            return nil
        }
        if event.type == .scrollWheel {
            guard event.momentumPhase.isEmpty else { return event }
            let continuous = !event.phase.isEmpty
            if event.phase == .began || (!continuous && event.timestamp - lastScroll > 0.25) {
                horizontalTravel = 0
                verticalTravel = 0
                paged = false
            }
            lastScroll = event.timestamp
            horizontalTravel += event.scrollingDeltaX
            verticalTravel += abs(event.scrollingDeltaY)
            if !paged && abs(horizontalTravel) >= (continuous ? 26 : 1)
                && abs(horizontalTravel) > verticalTravel * 1.25 {
                go(page + (horizontalTravel < 0 ? 1 : -1))
                paged = true
            }
            return nil
        }
        if (search.currentEditor() as? NSTextView)?.hasMarkedText() == true { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty && search.stringValue.isEmpty && [123,124].contains(event.keyCode) {
            go(page + (event.keyCode == 124 ? 1 : -1))
            return nil
        }
        if modifiers.isEmpty && [36,76].contains(event.keyCode) { submit(); return nil }
        return event
    }
    func handleMouse(_ event: NSEvent) -> NSEvent? {
        let point = grid.convert(event.locationInWindow, from: nil)
        let backgroundPoint = grid.convert(point, to: background)
        switch event.type {
        case .leftMouseDown:
            dragStart = nil
            pressedTile = nil
            if searchSurface.frame.contains(backgroundPoint)
                || settings.frame.contains(backgroundPoint)
                || pageIndicators.hitTest(backgroundPoint) is NSButton {
                return event
            }
            let tile = grid.hitTest(backgroundPoint) as? AppTile
            if preferences.isShown && tile != nil { return event }
            dragStart = point
            dragDistance = 0
            pressedTile = tile
            return nil
        case .leftMouseDragged:
            guard let start = dragStart else { return event }
            dragDistance = max(dragDistance, hypot(point.x - start.x, point.y - start.y))
            return nil
        case .leftMouseUp:
            guard let start = dragStart else { return event }
            let tile = pressedTile
            dragStart = nil
            pressedTile = nil
            let deltaX = point.x - start.x
            let deltaY = point.y - start.y
            let height = grid.bounds.height
            if start.y > height * 0.12, start.y < height * 0.86,
               abs(deltaX) >= 48, abs(deltaX) > abs(deltaY) * 1.25 {
                go(page + (deltaX < 0 ? 1 : -1))
                return nil
            }
            if dragDistance < 8, hypot(deltaX, deltaY) < 8 {
                if let tile {
                    if tile.superview === grid && tile.frame.contains(point) { tile.performClick(nil) }
                } else {
                    closeLauncher()
                }
            }
            return nil
        default:
            return event
        }
    }
    @objc func resetSearch() {
        search.stringValue = ""
        updateSearch()
        window.makeFirstResponder(search)
    }
    func controlTextDidChange(_ notification: Notification) { updateSearch() }
    func updateSearch() {
        let q = search.stringValue
        clearSearch.isHidden = q.isEmpty
        results = q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.url.lastPathComponent.localizedCaseInsensitiveContains(q) }
        page = 0
        drawPage()
    }
    var capacity: Int { columns * rows }
    func go(_ index: Int) {
        let next = min(pages - 1, max(0,index))
        guard next != page else { return }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = next > page ? .fromRight : .fromLeft
        transition.duration = 0.22
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            grid.wantsLayer = true
            grid.layer?.add(transition, forKey: "page")
        }
        page = next
        drawPage()
    }
    func drawPage() {
        grid.subviews.forEach { $0.removeFromSuperview() }
        let size = grid.bounds.size
        pages = max(1,(results.count + capacity - 1)/capacity)
        page = min(page, pages - 1)
        let dx = size.width * 0.86 / CGFloat(columns)
        let dy = min(145,size.height * 0.69 / CGFloat(rows))
        let iconSize = max(1, min(80, dx - 10, dy - 24))
        let tileFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        for (slot, item) in results.dropFirst(page * capacity).prefix(capacity).enumerated() {
            let x = size.width * 0.07 + CGFloat(slot % columns) * dx
            let y = size.height * 0.82 - CGFloat(slot / columns + 1) * dy
            let titleWidth = ceil((item.name as NSString).size(withAttributes: [.font: tileFont]).width)
            let tileWidth = min(dx - 6, max(iconSize + 16, titleWidth + 18))
            let tileHeight = min(dy - 4, iconSize + 36)
            let tile = AppTile(frame: NSRect(
                x: x + (dx - tileWidth) / 2, y: y + (dy - tileHeight) / 2,
                width: tileWidth, height: tileHeight
            ))
            tile.title = item.name
            tile.font = tileFont
            tile.image = NSWorkspace.shared.icon(forFile: item.url.path).copy() as? NSImage
            tile.image?.size = NSSize(width: iconSize, height: iconSize)
            tile.imagePosition = .imageAbove
            tile.imageScaling = .scaleNone
            tile.isBordered = false
            tile.lineBreakMode = .byTruncatingTail
            tile.tag = page * capacity + slot
            tile.target = self
            tile.action = #selector(clicked(_:))
            tile.toolTip = item.name
            grid.addSubview(tile)
        }
        if results.isEmpty {
            let label = NSTextField(labelWithString: "没有找到应用")
            label.sizeToFit()
            label.setFrameOrigin(NSPoint(x: grid.bounds.midX-label.frame.width/2,y: grid.bounds.midY))
            grid.addSubview(label)
        }
        updatePageIndicators()
    }
    func updatePageIndicators() {
        let width = pageIndicators.bounds.width
        if pageIndicators.subviews.count != pages {
            pageIndicators.subviews.forEach { $0.removeFromSuperview() }
            let dotWidth = min(20, width * 0.8 / CGFloat(pages))
            let start = (width - CGFloat(pages) * dotWidth) / 2
            for index in 0..<pages {
                let dot = NSButton(title: "●", target: self, action: #selector(dotClicked(_:)))
                dot.frame = NSRect(x: start + CGFloat(index) * dotWidth, y: 0, width: dotWidth, height: 26)
                dot.isBordered = false
                dot.font = .systemFont(ofSize: 10)
                dot.tag = index
                dot.setAccessibilityLabel("第 " + String(index + 1) + " 页")
                pageIndicators.addSubview(dot)
            }
        }
        for case let dot as NSButton in pageIndicators.subviews {
            dot.alphaValue = dot.tag == page ? 1 : 0.38
        }
    }
    @objc func dotClicked(_ sender: NSButton) { go(sender.tag) }
    @objc func clicked(_ sender: NSButton) { launch(sender.tag) }
    @objc func submit() { launch(page * capacity) }
    func launch(_ index: Int) {
        guard results.indices.contains(index) else { return }
        NSWorkspace.shared.openApplication(at: results[index].url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { NSAlert(error: error).runModal() }
                else { self?.closeLauncher(animated: false) }
            }
        }
    }
}

if CommandLine.arguments.contains("--check-index") {
    print(Item.installed().count)
} else {
    let app = NSApplication.shared
    let launcher = Launcher()
    app.delegate = launcher
    app.setActivationPolicy(.regular)
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "退出 LaunchOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    app.mainMenu = mainMenu
    app.run()
}
