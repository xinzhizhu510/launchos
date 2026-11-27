import AppKit
import Carbon
import ServiceManagement

struct Item: Equatable {
    let url: URL
    let name: String
    let identifier: String

    static let userApplicationFolders = ["~/Applications", "/Applications"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    }
    static let applicationFolders = userApplicationFolders + [URL(fileURLWithPath: "/System/Applications", isDirectory: true)]

    var canMoveToTrash: Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .isUserImmutableKey, .isSystemImmutableKey, .volumeIsReadOnlyKey
        ]
        guard identifier != Bundle.main.bundleIdentifier,
              let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory == true, values.isSymbolicLink == false,
              values.isUserImmutable != true, values.isSystemImmutable != true,
              values.volumeIsReadOnly != true else { return false }
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard !resolvedPath.hasPrefix("/System/"),
              Self.userApplicationFolders.contains(where: {
                  resolvedPath.hasPrefix($0.resolvingSymlinksInPath().path + "/")
              }) else { return false }
        // Use a conservative ownership check for the inline action. Finder can handle other owners.
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
        let owner = attributes?[.ownerAccountID] as? NSNumber
        return owner?.uint32Value == getuid()
    }

    static func installed(in folders: [URL] = applicationFolders) -> [Item] {
        let fm = FileManager.default
        var items = [String: Item]()
        for root in folders {
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files where url.pathExtension.lowercased() == "app" {
                files.skipDescendants()
                guard let bundle = Bundle(url: url), bundle.executableURL != nil,
                      bundle.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let identifier = bundle.bundleIdentifier ?? url.path
                if let current = items[identifier], !isNewer(url, than: current.url) { continue }
                let display = fm.displayName(atPath: url.path)
                let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
                items[identifier] = Item(url: url, name: name, identifier: identifier)
            }
        }
        return items.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    static func isNewer(_ candidate: URL, than current: URL) -> Bool {
        func versionInfo(_ url: URL) -> [String: Any] {
            // Read the plist rather than cached Bundle metadata when a copy may have been updated in place.
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            else { return [:] }
            return info as? [String: Any] ?? [:]
        }

        let candidateInfo = versionInfo(candidate)
        let currentInfo = versionInfo(current)
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            let left = candidateInfo[key] as? String ?? ""
            let right = currentInfo[key] as? String ?? ""
            let comparison = left.compare(right, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending }
        }
        return false
    }
}

struct AppUsage: Codable {
    var days: [Int: Int] = [:]
    var lastOpened: Date = .distantPast

    private static func day(_ date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 86_400))
    }

    mutating func record(at date: Date) {
        let today = Self.day(date)
        days = days.filter { $0.key >= today - 29 && $0.key <= today }
        days[today, default: 0] += 1
        lastOpened = date
    }

    func count(at date: Date) -> Int {
        let today = Self.day(date)
        return days.reduce(0) { $0 + ((today - 29...today).contains($1.key) ? $1.value : 0) }
    }

    static func frequentlyOpened(_ apps: [Item], usage: [String: AppUsage], at date: Date) -> [Item] {
        let ranked = apps.compactMap { app -> (app: Item, count: Int, lastOpened: Date)? in
            guard let activity = usage[app.identifier] else { return nil }
            let opens = activity.count(at: date)
            return opens > 0 ? (app, opens, activity.lastOpened) : nil
        }.sorted { first, second in
            if first.count != second.count { return first.count > second.count }
            if first.lastOpened != second.lastOpened { return first.lastOpened > second.lastOpened }
            return first.app.name.localizedStandardCompare(second.app.name) == .orderedAscending
        }
        return ranked.prefix(24).map { $0.app }
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
    let libraryTabs = NSSegmentedControl(
        labels: ["全部应用", "最近常用"], trackingMode: .selectOne, target: nil, action: nil
    )
    var appUsage: [String: AppUsage] = [:]
    var launchObserver: NSObjectProtocol?
    var showingFrequentApps: Bool { libraryTabs.selectedSegment == 1 }
    let clearSearch = NSButton()
    var dragStart: NSPoint?
    var pressedTile: AppTile?
    var dragDistance: CGFloat = 0
    var longPress: DispatchWorkItem?
    var isEditingApps = false
    var itemBeingMovedToTrash: Item?
    var trashFailure: (item: Item, message: String)?
    let trashQueue = DispatchQueue(label: "local.launchos.trash")
    var catalogTimer: Timer?
    let doneEditing = NSButton()
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
    var apps: [Item] = []
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
        if let data = defaults.data(forKey: "appUsage"),
           let saved = try? JSONDecoder().decode([String: AppUsage].self, from: data) {
            appUsage = saved
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  let identifier = app.bundleIdentifier ?? app.bundleURL?.path else { return }
            guard let self else { return }
            if !self.apps.contains(where: { $0.identifier == identifier }) && self.dragStart == nil {
                self.refreshCatalog()
            }
            self.recordOpen(identifier)
        }
        configureToolbar()
        installHotKey()
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
        apps = Item.installed()
        updateSearch()
        catalogTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.itemBeingMovedToTrash == nil, self.dragStart == nil,
                  self.window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            self.refreshCatalog()
        }

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
                animateEntrance(libraryTabs, offset: 8, scale: 0.985, delay: 0.045, duration: 0.27)
                animateEntrance(grid, offset: 17, scale: 0.98, delay: 0.045, duration: 0.32)
                animateEntrance(pageIndicators, offset: 0, scale: 1, delay: 0.10, duration: 0.19)
            } else {
                clearPresentationAnimations()
            }
            fadeWindow(to: 1, duration: 0.22)
        }
        showTrashFailureIfNeeded()
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
        catalogTimer?.invalidate()
        catalogTimer = nil
        resetPointerInteraction()
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        isEditingApps = false
        doneEditing.isHidden = true
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
        for view in [searchSurface, settings, libraryTabs, grid, pageIndicators] {
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

        libraryTabs.frame = NSRect(x: bounds.midX - 106, y: top - 32, width: 212, height: 24)
        libraryTabs.segmentStyle = .rounded
        libraryTabs.selectedSegment = 0
        libraryTabs.target = self
        libraryTabs.action = #selector(changeLibraryTab)
        libraryTabs.setWidth(104, forSegment: 0)
        libraryTabs.setWidth(104, forSegment: 1)
        libraryTabs.setAccessibilityLabel("应用页签")
        background.addSubview(libraryTabs)

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

        doneEditing.title = "完成"
        doneEditing.bezelStyle = .rounded
        doneEditing.frame = NSRect(x: settings.frame.minX - 78, y: top + 8, width: 68, height: 28)
        doneEditing.target = self
        doneEditing.action = #selector(finishEditingApps)
        doneEditing.isHidden = true
        background.addSubview(doneEditing)

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
        guard NSApp.modalWindow == nil, window?.attachedSheet == nil else { return event }
        if event.type == .keyDown, event.keyCode == 53, NSApp.isActive {
            if isEditingApps { finishEditingApps() }
            else { closeLauncher() }
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
            resetPointerInteraction()
            if searchSurface.frame.contains(backgroundPoint)
                || settings.frame.contains(backgroundPoint)
                || libraryTabs.frame.contains(backgroundPoint)
                || (!doneEditing.isHidden && doneEditing.frame.contains(backgroundPoint))
                || pageIndicators.hitTest(backgroundPoint) is NSButton {
                return event
            }
            let hit = grid.hitTest(backgroundPoint)
            let tile = hit as? AppTile
            if hit is NSButton && tile == nil { return event }
            if preferences.isShown && tile != nil { return event }
            dragStart = point
            dragDistance = 0
            pressedTile = tile
            if let tile, !isEditingApps {
                let work = DispatchWorkItem { [weak self, weak tile] in
                    guard let self, let tile, self.pressedTile === tile, tile.superview === self.grid,
                          self.dragDistance < 8, self.isPresented else { return }
                    self.isEditingApps = true
                    self.doneEditing.isHidden = false
                    self.drawPage()
                }
                longPress = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            }
            return nil
        case .leftMouseDragged:
            guard let start = dragStart else { return event }
            dragDistance = max(dragDistance, hypot(point.x - start.x, point.y - start.y))
            if dragDistance >= 8 { longPress?.cancel() }
            return nil
        case .leftMouseUp:
            guard let start = dragStart else { return event }
            let tile = pressedTile
            resetPointerInteraction()
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
                } else if isEditingApps {
                    finishEditingApps()
                } else {
                    closeLauncher()
                }
            }
            return nil
        default:
            return event
        }
    }
    func resetPointerInteraction() {
        longPress?.cancel()
        longPress = nil
        dragStart = nil
        pressedTile = nil
    }
    @objc func finishEditingApps() {
        isEditingApps = false
        doneEditing.isHidden = true
        drawPage()
        window.makeFirstResponder(search)
    }
    func refreshCatalog() {
        updateCatalog(Item.installed())
    }
    func updateCatalog(_ installed: [Item]) {
        guard installed != apps else { return }
        apps = installed
        updateSearch(resetPage: false)
    }
    @objc func resetSearch() {
        search.stringValue = ""
        updateSearch()
        window.makeFirstResponder(search)
    }
    @objc func changeLibraryTab() {
        search.stringValue = ""
        updateSearch()
        window.makeFirstResponder(search)
    }
    func controlTextDidChange(_ notification: Notification) { updateSearch() }
    func updateSearch(resetPage: Bool = true) {
        let q = search.stringValue
        clearSearch.isHidden = q.isEmpty
        if q.isEmpty {
            results = showingFrequentApps ? AppUsage.frequentlyOpened(apps, usage: appUsage, at: Date()) : apps
        } else {
            results = apps.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.url.lastPathComponent.localizedCaseInsensitiveContains(q)
            }
        }
        if resetPage { page = 0 }
        drawPage()
    }
    func recordOpen(_ identifier: String) {
        guard apps.contains(where: { $0.identifier == identifier }) else { return }
        let now = Date()
        var usage = appUsage[identifier] ?? AppUsage()
        // A LaunchOS click can also generate a workspace launch notification.
        let elapsed = now.timeIntervalSince(usage.lastOpened)
        guard elapsed < 0 || elapsed >= 2 else { return }
        usage.record(at: now)
        appUsage[identifier] = usage
        if let data = try? JSONEncoder().encode(appUsage) {
            defaults.set(data, forKey: "appUsage")
        }
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
            if isEditingApps && item.canMoveToTrash {
                addTrashControl(for: tile, item: item)
            }
        }
        if results.isEmpty {
            let message = showingFrequentApps && search.stringValue.isEmpty
                ? "打开应用后，常用应用会显示在这里"
                : "没有找到应用"
            let label = NSTextField(labelWithString: message)
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
    func addTrashControl(for tile: AppTile, item: Item) {
        let frame = NSRect(x: tile.frame.minX, y: tile.frame.maxY - 23, width: 23, height: 23)
        if item == itemBeingMovedToTrash {
            let indicator = NSProgressIndicator(frame: frame.insetBy(dx: 3, dy: 3))
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.setAccessibilityLabel("正在移到废纸篓：" + item.name)
            grid.addSubview(indicator)
            indicator.startAnimation(nil)
            return
        }
        let button = NSButton(frame: frame)
        let label = "移到废纸篓：" + item.name
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: label)
        button.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = itemBeingMovedToTrash == nil
        button.tag = tile.tag
        button.target = self
        button.action = #selector(confirmTrash(_:))
        grid.addSubview(button)
    }
    @objc func confirmTrash(_ button: NSButton) {
        guard isEditingApps, itemBeingMovedToTrash == nil, results.indices.contains(button.tag) else { return }
        let item = results[button.tag]
        guard item.canMoveToTrash else { return }
        guard window.attachedSheet == nil else { return }

        let alert = NSAlert()
        alert.messageText = "将「\(item.name)」移到废纸篓？"
        alert.informativeText = item.url.path
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let moveButton = alert.addButton(withTitle: "移到废纸篓")
        moveButton.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.isPresented else { return }
            self.window.makeFirstResponder(self.search)
            if response == .alertSecondButtonReturn { self.moveToTrash(item) }
        }
    }

    func moveToTrash(_ item: Item) {
        itemBeingMovedToTrash = item
        drawPage()
        trashQueue.async { [weak self] in
            let installed = Item.installed()
            guard item.canMoveToTrash, installed.contains(item) else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishMovingToTrash(installed)
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Let Finder put any authorization prompt above the fullscreen grid.
                let launcherLevel = self.window.level
                self.window.level = .normal
                NSWorkspace.shared.recycle([item.url]) { [weak self] moved, error in
                    let failure = moved.isEmpty
                        ? (item, error?.localizedDescription ?? "macOS 未能将此应用移到废纸篓。")
                        : nil
                    self?.trashQueue.async { [weak self] in
                        let installed = Item.installed()
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.window.level = launcherLevel
                            self.trashFailure = failure
                            self.finishMovingToTrash(installed)
                            self.showTrashFailureIfNeeded()
                        }
                    }
                }
            }
        }
    }

    func finishMovingToTrash(_ installed: [Item]) {
        itemBeingMovedToTrash = nil
        if installed == apps {
            drawPage()
        } else {
            updateCatalog(installed)
        }
    }

    func showTrashFailureIfNeeded() {
        guard isPresented, window.attachedSheet == nil, let failure = trashFailure else { return }
        trashFailure = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法将「\(failure.item.name)」移到废纸篓"
        alert.informativeText = failure.message
        alert.addButton(withTitle: "好").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "在访达中显示")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.isPresented else { return }
            if response == .alertSecondButtonReturn {
                self.closeLauncher(animated: false)
                NSWorkspace.shared.activateFileViewerSelecting([failure.item.url])
            } else {
                self.window.makeFirstResponder(self.search)
            }
        }
    }

    @discardableResult
    func runLauncherAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // The launcher overlays the menu bar, above the default modal-panel level.
        alert.window.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        alert.window.collectionBehavior = window.collectionBehavior
        return alert.runModal()
    }

    @objc func dotClicked(_ sender: NSButton) { go(sender.tag) }
    @objc func clicked(_ sender: NSButton) { launch(sender.tag) }
    @objc func submit() { launch(page * capacity) }
    func launch(_ index: Int) {
        guard !isEditingApps, results.indices.contains(index) else { return }
        let item = results[index]
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.refreshCatalog()
                    self?.runLauncherAlert(NSAlert(error: error))
                }
                else {
                    self?.recordOpen(item.identifier)
                    self?.closeLauncher(animated: false)
                }
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
