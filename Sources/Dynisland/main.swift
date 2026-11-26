import AppKit
import SwiftUI

/// Borderless, non-activating panel that floats above the menu bar, centred on the notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let canvas = CGSize(width: 680, height: 380) // room for the welcome tour (the tallest island) + spring overshoot
    let model = IslandModel()
    var panel: NotchPanel!
    var screen: NSScreen?
    var settingsWindow: NSWindow?
    var hidden = false // fullscreen app in front, or "Show the island" off

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear // transparent pixels let clicks fall through to the menu bar
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        panel.sharingType = Prefs.shared.hideFromSharing ? .none : .readOnly
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openOnboarding = { [weak self] in self?.showOnboarding() }
        DistributedNotificationCenter.default().addObserver(forName: IslandModel.shelfHandoff, object: nil, queue: .main) { [weak self] note in
            self?.model.receiveShelfHandoff(note.userInfo?["paths"] as? [String] ?? [])
        }
        place()
        panel.orderFrontRegardless()
        // Opening by distance needs every mouse move: global for other apps' windows, local for our own. No permission needed.
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in self?.model.mouseMoved(to: NSEvent.mouseLocation) }
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] e in self?.model.mouseMoved(to: NSEvent.mouseLocation); return e }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self?.model.swipe(e) == true ? nil : e }
        if !UserDefaults.standard.bool(forKey: "onboarded") { showOnboarding() }

        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.changed, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(self, selector: #selector(frontmostChanged), name: name, object: nil)
        }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshSurroundings() }
        refreshSurroundings()
    }

    /// Pins the canvas to the top-centre of the notched screen and measures the notch.
    @objc func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        self.screen = screen
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.notch = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
            model.prompter.notch = model.notch
        } else {
            model.notch = CGSize(width: 190, height: NSStatusBar.system.thickness) // no notch: fake one under the menu bar
        }
        let reach: CGFloat = 90 // how far outside the open island an incoming drag starts opening it
        let open = model.expandedSize
        model.approachZone = NSRect(x: f.midX - open.width / 2 - reach, y: f.maxY - open.height - reach,
                                    width: open.width + reach * 2, height: open.height + reach)
        model.screenTop = CGPoint(x: f.midX, y: f.maxY)
        let c = Self.canvas
        panel.setFrame(NSRect(x: f.midX - c.width / 2, y: f.maxY - c.height, width: c.width, height: c.height), display: true)
    }

    @objc func prefsChanged() {
        place() // open size may have changed
        panel.sharingType = Prefs.shared.hideFromSharing ? .none : .readOnly
        refreshSurroundings() // "Show the island" may have changed
    }

    /// Opening the app again (Finder, Spotlight) shows Settings: the way back when the island is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc func frontmostChanged() {
        // A fullscreen transition finishes a moment after the notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refreshSurroundings() }
    }

    func refreshSurroundings() {
        guard let screen, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        updateFullscreen(screen, windows)
        updateMenuRoom(screen, windows)
    }

    /// Hides the island while the frontmost app fills the notched screen (fullscreen video, games, fullscreen apps).
    private func updateFullscreen(_ screen: NSScreen, _ windows: [[String: Any]]) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let full = windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { return false }
            return r.size == screen.frame.size && r.minX == screen.frame.minX
        }
        let hide = full || !Prefs.shared.showIsland
        guard hide != hidden else { return }
        hidden = hide
        hide ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    /// Caps the live-activity wings so they never cover the app's menus (left) or status items (right).
    private func updateMenuRoom(_ screen: NSScreen, _ windows: [[String: Any]]) {
        let notchMin = screen.frame.midX - model.notch.width / 2, notchMax = screen.frame.midX + model.notch.width / 2
        var menusEnd = screen.frame.minX
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
           let bar = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute),
           let items = axValue(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] {
            for item in items { // menus that don't fit jump to the right of the notch; only those left of it matter
                guard let f = axFrame(item), f.maxX <= notchMax else { continue }
                menusEnd = max(menusEnd, f.maxX)
            }
        }
        let statusStart = windows.compactMap { w -> CGFloat? in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.minY <= 1, r.minX >= notchMax else { return nil }
            return r.minX
        }.min() ?? screen.frame.maxX
        model.sideLimit = max(0, min(notchMin - menusEnd, statusStart - notchMax) - 6)
    }

    private func axFrame(_ e: AXUIElement) -> CGRect? {
        guard let p = axValue(e, kAXPositionAttribute), let s = axValue(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// The welcome tour runs inside the island itself.
    func showOnboarding() {
        model.startOnboarding()
    }

    func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow.make(model: model) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
