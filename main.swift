// MenuCloak — hides the app menus (left side of the menu bar) behind a black overlay.
// Right-side status items / clock stay visible. Move the mouse into the covered
// area to reveal the menus; they re-cover when you leave.
//
// Technique (same family as MacTools' notch mask, unlike TopNotch's wallpaper repaint):
// a borderless black NSWindow at status-window level, click-through, spanning from
// the left screen edge to the leftmost status item. On a notched Mac the black
// strip merges with the notch.
//
// ponytail: primary display only; fullscreen Spaces stay uncovered (menu bar
// auto-hides there anyway). Upgrade path: one overlay per NSScreen.

import AppKit

enum Fade {
    static let duration: TimeInterval = 0.15

    static func alpha(from: CGFloat, to: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let progress = CGFloat(min(max(elapsed / duration, 0), 1))
        return from + (to - from) * progress
    }
}

enum FocusText {
    static func displayText(_ raw: String) -> String {
        raw.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum MenuCloakURLAction: Equatable {
    case toggle
    case turnOn
    case turnOff
    case openSettings
    case setFocus(String)

    static func parse(_ url: URL) -> MenuCloakURLAction? {
        guard url.scheme?.lowercased() == "menucloak" else { return nil }
        switch url.host?.lowercased() {
        case "toggle": return .toggle
        case "on": return .turnOn
        case "off": return .turnOff
        case "settings": return .openSettings
        case "set":
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            return .setFocus(text)
        default: return nil
        }
    }
}

enum LegacyOneThing {
    // Raycast's Cache journal maps a key to the opaque file that stores its value:
    // `onething <filename> <byte-count>`.
    static func cacheFilename(inJournal journal: String) -> String? {
        for line in journal.split(whereSeparator: \Character.isNewline).reversed() {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2, fields[0] == "onething" else { continue }
            let filename = String(fields[1])
            guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else { continue }
            return filename
        }
        return nil
    }

}

enum MenuBarIcon {
    static func make() -> NSImage {
        let url = Bundle.main.url(
            forResource: "MenuCloakMenuTemplate",
            withExtension: "png"
        )
        let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: .init(width: 18, height: 18))
        image.size = .init(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "MenuCloak"
        return image
    }
}

final class LegacyOneThingStore {
    private let fileManager = FileManager.default
    private var valueURL: URL?

    func read() -> String? {
        if valueURL == nil || !fileManager.fileExists(atPath: valueURL!.path) {
            valueURL = discoverValueURL()
        }
        guard let url = valueURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = FocusText.displayText(raw)
        return text.isEmpty ? nil : text
    }

    private func discoverValueURL() -> URL? {
        let extensions = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.raycast.macos/extensions", isDirectory: true)
        guard let extensionDirs = try? fileManager.contentsOfDirectory(
            at: extensions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(date: Date, url: URL)] = []
        for extensionDir in extensionDirs {
            let cacheDir = extensionDir.appendingPathComponent("com.raycast.api.cache", isDirectory: true)
            let journalURL = cacheDir.appendingPathComponent("journal")
            guard let journal = try? String(contentsOf: journalURL, encoding: .utf8),
                  let filename = LegacyOneThing.cacheFilename(inJournal: journal) else { continue }
            let date = (try? journalURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((date, cacheDir.appendingPathComponent(filename)))
        }
        return candidates.max(by: { $0.date < $1.date })?.url
    }
}

final class FocusTextStore {
    private static let textKey = "MenuCloakFocusText"
    private static let legacyMigrationKey = "MenuCloakDidMigrateOneThing"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMigratingLegacyIfNeeded() -> String {
        if let saved = defaults.string(forKey: Self.textKey) {
            return FocusText.displayText(saved)
        }

        guard !defaults.bool(forKey: Self.legacyMigrationKey) else { return "" }
        let imported = LegacyOneThingStore().read() ?? ""
        defaults.set(imported, forKey: Self.textKey)
        defaults.set(true, forKey: Self.legacyMigrationKey)
        return imported
    }

    @discardableResult
    func save(_ raw: String) -> String {
        let text = FocusText.displayText(raw)
        defaults.set(text, forKey: Self.textKey)
        return text
    }
}

// MARK: private CGS/SkyLight — pin the overlay into its own always-shown space
// at an absolute level above the managed desktops, so desktop-switch slide
// animations (which composite managed-space snapshots over normal windows)
// can never occlude it. Precedent: Übersicht, Pock. Symbols verified present
// on this OS via `dyld_info -exports` (CoreGraphics re-exports SLS* as CGS*).
typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64
@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate") func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: UnsafeMutableRawPointer?, _ options: CFDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy") func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel") func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int32)
@_silgen_name("CGSAddWindowsToSpaces") func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSRemoveWindowsFromSpaces") func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("CGSShowSpaces") func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> CFArray?

enum Geometry {
    // Cover from the left edge up to the leftmost status item; fall back to 60%
    // of the screen when detection returns nothing sane.
    static func coverWidth(statusMinX: CGFloat?, screenWidth: CGFloat) -> CGFloat {
        guard let x = statusMinX, x > 100, x <= screenWidth else { return screenWidth * 0.6 }
        return x
    }

    // Mouse inside the covered strip (global bottom-left coords), with a little slack.
    static func isInStrip(mouse: CGPoint, screenTopY: CGFloat, barHeight: CGFloat, coverWidth: CGFloat) -> Bool {
        mouse.y >= screenTopY - barHeight - 4 && mouse.x <= coverWidth + 12
    }

    static func isMenuBarBackdrop(frame: CGRect, screenWidth: CGFloat, nativeBarHeight: CGFloat) -> Bool {
        nativeBarHeight > 5 && frame.minY <= 0 && frame.width >= screenWidth - 1
            && abs(frame.height - nativeBarHeight) <= 1
    }

    static func isMenuBarPopup(frame: CGRect, barHeight: CGFloat, coverWidth: CGFloat) -> Bool {
        let hangsFromMenuBar = frame.minY <= barHeight + 8
        let nearMenuBarSubmenu = frame.minY <= barHeight + frame.height + 30
        return frame.minX < coverWidth && (hangsFromMenuBar || nearMenuBarSubmenu)
    }
}

// --selftest: the one runnable check for the pure logic.
if CommandLine.arguments.contains("--selftest") {
    precondition(Geometry.coverWidth(statusMinX: 900, screenWidth: 1512) == 900)
    precondition(Geometry.coverWidth(statusMinX: nil, screenWidth: 1512) == 1512 * 0.6)
    precondition(Geometry.coverWidth(statusMinX: 50, screenWidth: 1512) == 1512 * 0.6)
    precondition(Geometry.coverWidth(statusMinX: 2000, screenWidth: 1512) == 1512 * 0.6)
    precondition(Geometry.isInStrip(mouse: .init(x: 100, y: 978), screenTopY: 982, barHeight: 37, coverWidth: 800))
    precondition(!Geometry.isInStrip(mouse: .init(x: 100, y: 500), screenTopY: 982, barHeight: 37, coverWidth: 800))
    precondition(!Geometry.isInStrip(mouse: .init(x: 900, y: 978), screenTopY: 982, barHeight: 37, coverWidth: 800))
    precondition(Geometry.isMenuBarBackdrop(frame: .init(x: 0, y: 0, width: 1352, height: 30),
                                            screenWidth: 1352, nativeBarHeight: 30))
    precondition(!Geometry.isMenuBarBackdrop(frame: .init(x: 0, y: 0, width: 1352, height: 878),
                                             screenWidth: 1352, nativeBarHeight: 30))
    precondition(Geometry.isMenuBarPopup(frame: .init(x: 100, y: 33, width: 111, height: 58), barHeight: 30, coverWidth: 869))
    precondition(Geometry.isMenuBarPopup(frame: .init(x: 204, y: 107, width: 101, height: 53), barHeight: 30, coverWidth: 869))
    precondition(!Geometry.isMenuBarPopup(frame: .init(x: 676, y: 434, width: 111, height: 58), barHeight: 30, coverWidth: 869))
    precondition(!Geometry.isMenuBarPopup(frame: .init(x: 968, y: 30, width: 320, height: 718), barHeight: 30, coverWidth: 869))
    precondition(Fade.alpha(from: 1, to: 0, elapsed: 0) == 1)
    precondition(Fade.alpha(from: 1, to: 0, elapsed: 0.075) == 0.5)
    precondition(Fade.alpha(from: 1, to: 0, elapsed: 0.15) == 0)
    precondition(LegacyOneThing.cacheFilename(inJournal: "onething opaque-file 6\n") == "opaque-file")
    precondition(LegacyOneThing.cacheFilename(inJournal: "other abc 1\nonething newest 4\n") == "newest")
    precondition(LegacyOneThing.cacheFilename(inJournal: "onething ../escape 1\n") == nil)
    precondition(FocusText.displayText("  Finish the project  \n today ") == "Finish the project today")
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://toggle")!) == .toggle)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://on")!) == .turnOn)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://off")!) == .turnOff)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://settings")!) == .openSettings)
    precondition(MenuCloakURLAction.parse(URL(string: "menucloak://set?text=Build%20the%20thing")!) == .setFocus("Build the thing"))
    precondition(MenuCloakURLAction.parse(URL(string: "https://example.com")!) == nil)
    precondition(MenuBarIcon.make().isTemplate)
    precondition(MenuBarIcon.make().size == .init(width: 18, height: 18))
    print("selftest ok")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private static let enabledDefaultsKey = "MenuCloakEnabled"
    private var overlay: NSWindow!
    private var focusLabel: NSTextField!
    private var statusItem: NSStatusItem!
    private var statusToggleItem: NSMenuItem!
    private var controlWindow: NSWindow?
    private var controlSwitch: NSSwitch?
    private var controlStateLabel: NSTextField?
    private var controlFocusField: NSTextField?
    private var timer: Timer?
    private var fadeTimer: Timer?
    // cover starts after the Apple-menu capsule so the  stays visible;
    // MENUCLOAK_LEFT overrides (0 = cover it too)
    private let leftInset = CGFloat(Double(ProcessInfo.processInfo.environment["MENUCLOAK_LEFT"] ?? "") ?? 46)
    private var enabled: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: AppDelegate.enabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: AppDelegate.enabledDefaultsKey)
    }()
    private var covered = false
    private var coverWidth: CGFloat?
    private var menuBarH: CGFloat?
    private var tickCount = 0
    private var missSince: Date?   // when probes started not seeing the menu bar
    private var lastHold = Date.distantPast
    private let focusTextStore = FocusTextStore()
    private var focusText = ""

    private var screen: NSScreen? { NSScreen.screens.first }

    func applicationDidFinishLaunching(_ note: Notification) {
        let backgroundLaunch = CommandLine.arguments.contains("--background")
        NSApp.setActivationPolicy(backgroundLaunch ? .accessory : .regular)
        makeOverlay()
        makeStatusItem()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAndLayout() }
        // the instant a desktop switch lands, snap to black — no fade, no blink
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.refreshAndLayout()
            if self.menuBarH != nil, self.coverWidth != nil {
                self.setCovered(true, animate: false)
            }
        }
        setFocusText(focusTextStore.loadMigratingLegacyIfNeeded(), persist: false)
        refreshAndLayout()
        setCovered(enabled, animate: false)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        if !backgroundLaunch { showControlWindow() }
        if ProcessInfo.processInfo.environment["MENUCLOAK_DEBUG"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                let btn = statusItem.button
                FileHandle.standardError.write(Data(
                    ("statusItem visible=\(statusItem.isVisible) length=\(statusItem.length) " +
                     "btnWindow=\(btn?.window?.frame ?? .zero) num=\(btn?.window?.windowNumber ?? -1) " +
                     "img=\(String(describing: btn?.image))\n").utf8))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            DispatchQueue.main.async { [weak self] in self?.handle(url) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === controlWindow else { return }
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: setup

    private var cgsSpace: CGSSpaceID = 0

    private func makeOverlay() {
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 24),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.alphaValue = 0
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.isHidden = true
        label.setAccessibilityLabel("MenuCloak focus")
        w.contentView?.addSubview(label)
        w.orderFrontRegardless()
        overlay = w
        focusLabel = label
        bindToPrivateSpace(w)
    }

    private func bindToPrivateSpace(_ w: NSWindow) {
        let cid = CGSMainConnectionID()
        let space = CGSSpaceCreate(cid, UnsafeMutableRawPointer(bitPattern: 1), nil)
        guard space != 0 else { return }   // fallback: stay a canJoinAllSpaces window
        let levelEnv = ProcessInfo.processInfo.environment["MENUCLOAK_SPACE_LEVEL"]
        let level = Int32(levelEnv ?? "") ?? 100
        CGSSpaceSetAbsoluteLevel(cid, space, level)
        let wins = [CGWindowID(w.windowNumber)] as CFArray
        // move (not copy): pull it out of the managed desktops first, or the
        // slide animation still owns a copy of it
        if let owned = CGSCopySpacesForWindows(cid, 7, wins) as? [CGSSpaceID], !owned.isEmpty {
            CGSRemoveWindowsFromSpaces(cid, wins, owned as CFArray)
        }
        CGSAddWindowsToSpaces(cid, wins, [space] as CFArray)
        CGSShowSpaces(cid, [space] as CFArray)
        w.collectionBehavior = [.stationary, .ignoresCycle]   // AppKit must not re-tag it
        cgsSpace = space
    }

    func applicationWillTerminate(_ notification: Notification) {
        if cgsSpace != 0 { CGSSpaceDestroy(CGSMainConnectionID(), cgsSpace) }
    }

    private func makeStatusItem() {
        // A fixed one-unit slot avoids the extra-wide hover capsule that
        // squareLength can produce when a menu-bar manager is active.
        statusItem = NSStatusBar.system.statusItem(withLength: 22)
        // Separate from the full-color app icon: template images are rendered
        // white on a dark menu bar and black on a light one, matching macOS.
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open MenuCloak…", action: #selector(openControlWindow(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "MenuCloak On", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = enabled ? .on : .off
        statusToggleItem = toggle
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MenuCloak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openControlWindow(_ sender: Any?) {
        showControlWindow()
    }

    @objc private func toggleEnabled(_ item: NSMenuItem) {
        setEnabled(!enabled)
    }

    @objc private func controlSwitchChanged(_ sender: NSSwitch) {
        setEnabled(sender.state == .on)
    }

    private func setEnabled(_ newValue: Bool) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
        statusToggleItem?.state = newValue ? .on : .off
        updateControlState()
        if newValue {
            refreshAndLayout()
            setCovered(true, animate: false)
        } else {
            setCovered(false, animate: false)
        }
    }

    private func handle(_ url: URL) {
        guard let action = MenuCloakURLAction.parse(url) else { return }
        switch action {
        case .toggle:
            setEnabled(!enabled)
        case .turnOn:
            setEnabled(true)
        case .turnOff:
            setEnabled(false)
        case .openSettings:
            showControlWindow()
        case let .setFocus(text):
            setFocusText(text, persist: true)
            controlFocusField?.stringValue = focusText
        }
    }

    private func showControlWindow() {
        if controlWindow == nil { makeControlWindow() }
        updateControlState()
        NSApp.setActivationPolicy(.regular)
        controlWindow?.center()
        controlWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeControlWindow() {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 390, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MenuCloak"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: .init(x: 0, y: 0, width: 390, height: 260))
        window.contentView = content

        let title = NSTextField(labelWithString: "MenuCloak")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = .init(x: 28, y: 207, width: 330, height: 29)
        content.addSubview(title)

        let detail = NSTextField(wrappingLabelWithString: "Keep one clear focus in the left side of your menu bar.")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detail.frame = .init(x: 28, y: 174, width: 330, height: 34)
        content.addSubview(detail)

        let focusTitle = NSTextField(labelWithString: "Focus text")
        focusTitle.font = .systemFont(ofSize: 13, weight: .medium)
        focusTitle.frame = .init(x: 28, y: 145, width: 330, height: 20)
        content.addSubview(focusTitle)

        let focusField = NSTextField(frame: .init(x: 28, y: 110, width: 334, height: 28))
        focusField.placeholderString = "What deserves your attention?"
        focusField.stringValue = focusText
        focusField.delegate = self
        focusField.setAccessibilityLabel("Focus text")
        content.addSubview(focusField)
        controlFocusField = focusField

        let toggle = NSSwitch(frame: .init(x: 28, y: 56, width: 42, height: 24))
        toggle.target = self
        toggle.action = #selector(controlSwitchChanged(_:))
        toggle.setAccessibilityLabel("Turn MenuCloak on or off")
        content.addSubview(toggle)
        controlSwitch = toggle

        let state = NSTextField(labelWithString: "")
        state.font = .systemFont(ofSize: 14, weight: .medium)
        state.frame = .init(x: 84, y: 58, width: 275, height: 22)
        content.addSubview(state)
        controlStateLabel = state

        let quit = NSButton(title: "Quit MenuCloak", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.frame = .init(x: 242, y: 16, width: 120, height: 30)
        content.addSubview(quit)

        controlWindow = window
    }

    private func updateControlState() {
        controlSwitch?.state = enabled ? .on : .off
        controlStateLabel?.stringValue = enabled
            ? "On — menus are covered"
            : "Off — menus are visible"
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === controlFocusField,
              let field = controlFocusField else { return }
        setFocusText(field.stringValue, persist: true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === controlFocusField else { return }
        controlFocusField?.stringValue = focusText
    }

    // MARK: window-list probes (no special permissions needed for layer/bounds/pid)

    private func windowInfos() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private func refreshCoverWidth() {
        guard let s = screen else { coverWidth = nil; menuBarH = nil; return }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let nativeBarH = s.frame.maxY - s.visibleFrame.maxY
        var minX: CGFloat?
        var barH: CGFloat?
        for info in windowInfos() {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == statusLevel || layer == barLevel,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if layer == barLevel {
                // the menu bar backdrop itself — full width at the top; gives the exact height
                if Geometry.isMenuBarBackdrop(frame: r, screenWidth: s.frame.width,
                                              nativeBarHeight: nativeBarH) { barH = r.height }
                continue
            }
            guard (info[kCGWindowOwnerPID as String] as? Int) != myPID else { continue }
            // status items in the top strip of the primary display only
            guard r.minY < 50, r.minX >= 0, r.maxX <= s.frame.width + 1,
                  r.width > 0, r.width < s.frame.width * 0.8 else { continue }
            minX = min(minX ?? .greatestFiniteMagnitude, r.minX)
        }
        // nil (menu bar / status items not visible) doubles as "fullscreen Space",
        // but it also happens transiently during space-switch animations
        menuBarH = barH
        coverWidth = minX.map { Geometry.coverWidth(statusMinX: $0, screenWidth: s.frame.width) }
        if barH == nil || coverWidth == nil {
            if missSince == nil { missSince = Date() }
        } else {
            missSince = nil
        }
    }

    // only dropdowns hanging off the covered part of the menu bar count —
    // right-click context menus (same window level, but anchored at the cursor)
    // must not lift the cover
    private func menuBarMenuOpen(barH: CGFloat, coverWidth: CGFloat) -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        for info in windowInfos() {
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.05,
                  let bd = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if Geometry.isMenuBarPopup(frame: r, barHeight: barH, coverWidth: coverWidth) { return true }
        }
        return false
    }

    // MARK: layout & state

    private func refreshAndLayout() {
        refreshCoverWidth()
        guard let s = screen, let cw = coverWidth, let bh = menuBarH, bh > 5 else { return }
        overlay.setFrame(.init(x: s.frame.minX + leftInset, y: s.frame.maxY - bh,
                               width: max(cw - leftInset, 0), height: bh), display: true)
        layoutFocusText(on: s, barHeight: bh)
    }

    private func layoutFocusText(on screen: NSScreen, barHeight: CGFloat) {
        let padding: CGFloat = 12
        let overlayFrame = overlay.frame
        // On a notched display, keep the text entirely in the usable top-left area.
        // Without a notch, the label can use the whole cloak.
        let safeMaxX = screen.auxiliaryTopLeftArea?.maxX ?? overlayFrame.maxX
        let maxX = min(overlayFrame.maxX - padding, safeMaxX - padding)
        let minX = overlayFrame.minX + padding
        let labelHeight: CGFloat = 18
        focusLabel.frame = .init(
            x: padding,
            y: floor((barHeight - labelHeight) / 2),
            width: max(maxX - minX, 0),
            height: labelHeight
        )
    }

    private func setFocusText(_ raw: String, persist: Bool) {
        let text = persist ? focusTextStore.save(raw) : FocusText.displayText(raw)
        guard text != focusText else { return }
        focusText = text
        focusLabel.stringValue = text
        focusLabel.toolTip = text.isEmpty ? nil : text
        focusLabel.isHidden = text.isEmpty
    }

    private func setCovered(_ on: Bool, animate: Bool) {
        guard covered != on else { return }
        covered = on
        fadeTimer?.invalidate()
        let target: CGFloat = on ? 1 : 0
        guard animate else {
            overlay.alphaValue = target
            return
        }
        let startAlpha = overlay.alphaValue
        let startTime = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(startTime)
            self.overlay.alphaValue = Fade.alpha(from: startAlpha, to: target, elapsed: elapsed)
            if elapsed >= Fade.duration {
                timer.invalidate()
                self.fadeTimer = nil
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard enabled, let s = screen else { setCovered(false, animate: false); return }
        tickCount += 1
        if tickCount % 3 == 0 {
            refreshAndLayout()
        }   // 0.3s probe cadence
        guard let bh = menuBarH, bh > 5, let cw = coverWidth else {
            // black by default: stay covered through transient probe gaps
            // (space-switch animations flap the window list for ≤0.4s);
            // uncover only when the menu bar stays gone (real fullscreen Space)
            if let m = missSince, Date().timeIntervalSince(m) > 0.8 {
                setCovered(false, animate: false)
            }
            return
        }
        // menu-open probe: every tick while revealed, every 0.5s while covered
        // (catches keyboard-opened menus without a 10Hz window-list scan)
        let hold = Geometry.isInStrip(mouse: NSEvent.mouseLocation, screenTopY: s.frame.maxY,
                                      barHeight: bh, coverWidth: cw)
            || ((!covered || tickCount % 5 == 0) && menuBarMenuOpen(barH: bh, coverWidth: cw))
        if hold {
            lastHold = Date()
            setCovered(false, animate: true)
        } else if Date().timeIntervalSince(lastHold) > 0.6 {
            setCovered(true, animate: true)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
