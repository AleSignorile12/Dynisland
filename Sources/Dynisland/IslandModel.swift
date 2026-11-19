import AppKit
import IOKit.ps
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ShelfItem: Hashable, Identifiable {
    case file(URL), link(URL), text(String)
    var id: Self { self }
}

struct DownloadItem: Identifiable {
    let id: ObjectIdentifier
    var name: String
    var fraction: Double
    var detail: String
}

enum DropZone { case airdrop, shelf }

/// A page of the expanded island. Order and visibility are user settings.
enum IslandSection: String, CaseIterable, Identifiable {
    case media, shelf, calendar, timer, mirror, controls, system, mixer, agents, sports, captions, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .media: "Music"
        case .shelf: "Shelf, AirDrop & Clipboard"
        case .calendar: "Calendar"
        case .timer: "Timer"
        case .mirror: "Mirror"
        case .controls: "Quick Controls"
        case .system: "System"
        case .mixer: "Volume Mixer"
        case .agents: "AI Agents"
        case .sports: "Sports"
        case .captions: "Captions & Prompter"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .media: "music.note"
        case .shelf: "tray.full.fill"
        case .calendar: "calendar"
        case .timer: "timer"
        case .mirror: "person.crop.square"
        case .controls: "switch.2"
        case .system: "cpu"
        case .mixer: "slider.vertical.3"
        case .agents: "sparkles"
        case .sports: "sportscourt.fill"
        case .captions: "captions.bubble.fill"
        case .settings: "gearshape.fill"
        }
    }
    /// App opened by clicking the page, until changed in Settings. Agents open their own apps.
    var defaultApp: String? {
        switch self {
        case .media: "com.spotify.client"
        case .shelf: "com.apple.finder"
        case .calendar: "com.apple.iCal"
        case .mirror: "com.apple.PhotoBooth"
        case .system: "com.apple.ActivityMonitor"
        default: nil
        }
    }
}

/// A short-lived card under the notch (notification, accessory, finished timer or agent).
struct Banner: Equatable {
    var icon: String
    var title: String
    var subtitle = ""
    var tint = Color.white
    var image: NSImage? // app icon, shown instead of the symbol
}

struct HUD: Equatable {
    var icon: String
    var level: Double
}

@Observable
final class IslandModel {
    var notch = CGSize(width: 190, height: 32)
    var hovering = false
    var dragging = false
    var dragNear = false // a content drag elsewhere is approaching the island
    var zone = DropZone.shelf
    var shelf: [ShelfItem] = []
    var landing = 0        // dropped items still arriving (a screenshot's promised file takes a moment); shown as loading tiles
    var holdOpen = false   // keeps the island open briefly after a drop so you see the item land
    var pinnedOpen = false // "Keep it open after I click it": stays open until a click elsewhere
    var downloads: [DownloadItem] = []
    var charging: Int? // battery % while the charging activity is on screen
    var banner: Banner?
    var hud: HUD?
    var sideLimit = CGFloat.infinity // room the menus and status items leave beside the notch
    var selected = IslandSection.media
    var shelfShowsClipboard = false // the Shelf page's second half: clipboard history instead of dropped files

    var sectionOrder: [IslandSection] {
        didSet { UserDefaults.standard.set(sectionOrder.map(\.rawValue), forKey: "sectionOrder") }
    }
    var disabledSections: Set<IslandSection> {
        didSet { UserDefaults.standard.set(disabledSections.map(\.rawValue), forKey: "disabledSections") }
    }
    /// Section -> bundle id opened on click; "" means nothing. Missing keys use the section's default.
    var clickApps: [String: String] {
        didSet { UserDefaults.standard.set(clickApps, forKey: "clickApps") }
    }
    var sections: [IslandSection] { sectionOrder.filter { !disabledSections.contains($0) } }
    /// Drags always land on the shelf page, whatever page was open.
    var shownSection: IslandSection {
        if dragging || dragNear || holdOpen { return .shelf }
        return sections.contains(selected) ? selected : (sections.first ?? .shelf)
    }

    var expanded: Bool { hovering || pinnedOpen || dragging || dragNear || holdOpen }
    var expandedSize: CGSize { CGSize(width: Prefs.shared.size.width, height: notch.height + 140) }
    /// Screen area (AppKit coordinates) where an incoming drag already opens the island; set by AppDelegate.place().
    @ObservationIgnored var approachZone = CGRect.zero
    @ObservationIgnored var openSettings: () -> Void = {}

    let media = MediaService()
    let calendar = CalendarService()
    let timer = TimerService()
    let clipboard = ClipboardService()
    let controls = ControlsService()
    let mixer = MixerService()
    let agents = AgentService()
    let network = NetworkService()
    let sports = SportsService()
    let captions = CaptionsService()
    let prompter = PrompterService()
    @ObservationIgnored let audio = AudioService()
    @ObservationIgnored let notifications = NotificationWatcher()

    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var onAC = false
    @ObservationIgnored private var expiries: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadSubscriber: Any?
    @ObservationIgnored private var progressWatchers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var dragBaseline = NSPasteboard(name: .drag).changeCount
    @ObservationIgnored private var dragWatchdog: Timer?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    init() {
        let saved = (UserDefaults.standard.stringArray(forKey: "sectionOrder") ?? []).compactMap(IslandSection.init)
        sectionOrder = saved + IslandSection.allCases.filter { !saved.contains($0) } // sections added in updates go last
        disabledSections = Set((UserDefaults.standard.stringArray(forKey: "disabledSections") ?? []).compactMap(IslandSection.init))
        clickApps = UserDefaults.standard.dictionary(forKey: "clickApps") as? [String: String] ?? [:]

        timer.onDone = { [weak self] title, subtitle in self?.show(Banner(icon: "timer", title: title, subtitle: subtitle, tint: Prefs.shared.accent)) }
        agents.onFinish = { [weak self] a in
            guard Prefs.shared.agentCards else { return }
            self?.show(Banner(icon: a.kind.symbol, title: "\(a.kind.name) is done", subtitle: a.project.isEmpty ? "Reply ready" : a.project, tint: Prefs.shared.accent, image: a.icon))
        }
        audio.onArrow = { [weak self] step in // ← → switch pages while the pointer is on the open island
            guard let self, hovering, !dragging else { return false }
            let all = sections
            guard let i = all.firstIndex(of: shownSection), !all.isEmpty else { return false }
            selected = all[(i + step + all.count) % all.count]
            return true
        }
        audio.onHUD = { [weak self] h in
            guard self?.expanded == false else { return } // changed from the island's own sliders: no HUD needed
            self?.hud = h
            self?.expire("hud", after: 1.5) { self?.hud = nil }
        }
        audio.onAccessory = { [weak self] name in
            self?.show(Banner(icon: name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones", title: name, subtitle: "Connected"))
        }
        notifications.onBanner = { [weak self] title, body in self?.show(Banner(icon: "bell.badge.fill", title: title, subtitle: body)) }

        startPowerMonitor()
        startDownloadMonitor()
        startDragApproachMonitor()
    }

    /// Shows a card under the notch for 4 s. If the island is open at that moment the card waits and its 4 s start
    /// once the island closes, so a "done" card is never swallowed while you're hovering.
    func show(_ b: Banner) {
        banner = b
        expiries["banner"]?.cancel()
        expiries["banner"] = Task { @MainActor in
            while expanded { try? await Task.sleep(for: .seconds(0.25)) }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { banner = nil }
        }
    }

    /// Opens an app by bundle id, or says it isn't installed.
    func openApp(_ bundleID: String, name: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            show(Banner(icon: "questionmark.app.dashed", title: "App not installed", subtitle: name))
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func clickApp(for s: IslandSection) -> String? {
        let id = clickApps[s.rawValue] ?? s.defaultApp
        return id?.isEmpty == false ? id : nil
    }

    /// Click on a page's empty area. Finder gets a new window (activating it alone shows nothing).
    func openClickApp(for s: IslandSection) {
        guard let id = clickApp(for: s) else { return }
        if id == "com.apple.finder" { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser); return }
        openApp(id, name: Self.appName(id))
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func open(_ agent: AgentKind) {
        if !agent.open() { show(Banner(icon: agent.symbol, title: "App not installed", subtitle: agent.name)) }
    }

    // MARK: Opening

    /// Pointer entered or left the island. Opens after the hover delay, or waits for a click in click-to-open mode.
    func pointer(inside: Bool) {
        hoverTask?.cancel()
        guard inside else { hovering = false; return }
        let p = Prefs.shared
        if p.clickToOpen { return }
        if p.hoverDelay <= 0 { hovering = true; return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(p.hoverDelay))
            if !Task.isCancelled { hovering = true }
        }
    }

    func clicked() {
        if !expanded { hoverTask?.cancel(); hovering = true }
        if Prefs.shared.keepOpenAfterClick { pinnedOpen = true }
    }

    /// Optional haptic tick and soft sound as the island opens or closes.
    func feedback(opened: Bool) {
        let p = Prefs.shared
        if p.haptics, opened { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        if p.sounds, let s = NSSound(named: opened ? "Pop" : "Tink")?.copy() as? NSSound { s.volume = 0.25; s.play() }
    }

    /// Runs `clear` after `seconds`, replacing any pending expiry with the same key.
    private func expire(_ key: String, after seconds: Double, _ clear: @escaping () -> Void) {
        expiries[key]?.cancel()
        expiries[key] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { clear() }
        }
    }

    // MARK: Drag approach

    /// Opens the island while a file/link/text drag is still on its way, so the drop zones are there before the
    /// pointer reaches the screen edge. A drag that writes nothing to the drag pasteboard (moving a window) is ignored.
    /// Mouse monitors need no Accessibility permission.
    private func startDragApproachMonitor() {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self else { return }
            let count = NSPasteboard(name: .drag).changeCount
            if event.type == .leftMouseDown { dragBaseline = count; pinnedOpen = false; return } // a click in another app closes a pinned island
            let near = count != dragBaseline && approachZone.contains(NSEvent.mouseLocation)
            guard near != dragNear else { return }
            dragNear = near
            if near { watchDragEnd() }
        }
    }

    /// The mouse-up that ends a drag is often swallowed by the drag session, so poll the button instead.
    private func watchDragEnd() {
        dragWatchdog?.invalidate()
        dragWatchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            dragNear = false
            dragBaseline = NSPasteboard(name: .drag).changeCount
        }
    }

    // MARK: Drops

    /// `.image` covers the screenshot thumbnail and image drags from apps: they hand over a promised file or raw
    /// image data instead of a file URL.
    static let dropTypes: [UTType] = [.fileURL, .url, .image, .plainText]

    /// Where promised/in-memory drops are written so the shelf holds a real file you can drag out later.
    static let shelfFolder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.local.dynisland/Shelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Copies a temporary file into the shelf folder without overwriting an earlier item of the same name.
    static func keep(_ temp: URL) -> URL? {
        var dest = shelfFolder.appending(path: temp.lastPathComponent)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = shelfFolder.appending(path: "\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return (try? FileManager.default.copyItem(at: temp, to: dest)) != nil ? dest : nil
    }

    func handleDrop(_ providers: [NSItemProvider], zone: DropZone) {
        var urls: [URL] = []
        if zone == .shelf { holdOpen = true; landing = providers.count }
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            let isImage = p.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            // The temp file only lives inside the callback, so it is copied out before returning.
            let loadImage = {
                _ = p.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { temp, _ in
                    let kept = temp.flatMap(Self.keep)
                    DispatchQueue.main.async {
                        if let kept { urls.append(kept) }
                        group.leave()
                    }
                }
            }
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) { // file URLs conform to public.url too
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if url == nil, isImage { loadImage(); return } // a promised file may advertise a URL it can't give yet
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            } else if isImage {
                loadImage()
            } else {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    DispatchQueue.main.async {
                        if let text, !text.isEmpty { self.add(.text(text)) }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) {
            if zone == .airdrop {
                guard !urls.isEmpty, let airdrop = NSSharingService(named: .sendViaAirDrop) else { return }
                NSApp.activate(ignoringOtherApps: true) // the AirDrop sheet only shows for the active app
                airdrop.perform(withItems: urls)
            } else {
                urls.forEach { self.add($0.isFileURL ? .file($0) : .link($0)) }
                self.landing = 0
                self.expire("hold", after: 1.1) { [weak self] in self?.holdOpen = false } // let the new tile settle, then close
            }
        }
    }

    /// Takes items off the shelf. Copies Dynisland made itself (dropped screenshots) are deleted too; your originals never are.
    func remove(_ items: [ShelfItem]) {
        shelf.removeAll { items.contains($0) }
        for case .file(let url) in items where url.path.hasPrefix(Self.shelfFolder.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func add(_ item: ShelfItem) {
        if !shelf.contains(item) { shelf.append(item) } // dragging a tile out over the island must not duplicate it
    }

    /// Distributed notification other local apps (Snoopy) post with `userInfo["paths"]: [String]` to put files on the shelf.
    static let shelfHandoff = Notification.Name("com.local.dynisland.shelf.add")

    /// Any local process can post the hand-off, so only existing absolute file paths are taken, at most 50.
    func receiveShelfHandoff(_ paths: [String]) {
        let files = paths.prefix(50).filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return }
        holdOpen = true
        files.forEach { add(.file(URL(fileURLWithPath: $0))) }
        expire("hold", after: 1.6) { [weak self] in self?.holdOpen = false } // show the tiles land, like a direct drop
    }

    // MARK: Charging

    private func startPowerMonitor() {
        onAC = Self.readPower().onAC
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<IslandModel>.fromOpaque(ctx!).takeUnretainedValue().powerChanged()
        }, ctx)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    private func powerChanged() {
        let (ac, percent) = Self.readPower()
        defer { onAC = ac }
        guard ac, !onAC else { return } // only on the battery -> charger transition
        charging = percent
        expire("charging", after: 3.5) { [weak self] in self?.charging = nil }
    }

    static func readPower() -> (onAC: Bool, percent: Int) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let ac = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSACPowerValue
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (ac, cur * 100 / max)
        }
        return (ac, 100)
    }

    // MARK: Downloads

    /// Browsers publish an NSProgress for each file they write into ~/Downloads (it is what draws Finder's
    /// progress bars), so subscribing to the folder gives live progress for Safari, Chrome, Finder copies, etc.
    private func startDownloadMonitor() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        downloadSubscriber = Progress.addSubscriber(forFileURL: dir) { [weak self] progress in
            DispatchQueue.main.async { self?.track(progress) }
            return { DispatchQueue.main.async { self?.untrack(progress) } }
        }
    }

    private func track(_ p: Progress) {
        let id = ObjectIdentifier(p)
        var name = p.fileURL?.lastPathComponent ?? "Download"
        for ext in [".download", ".crdownload", ".part"] where name.hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        downloads.append(DownloadItem(id: id, name: name, fraction: p.fractionCompleted, detail: ""))
        progressWatchers[id] = p.observe(\.fractionCompleted, options: [.initial]) { [weak self] p, _ in
            let fraction = p.fractionCompleted, detail = p.localizedAdditionalDescription ?? ""
            DispatchQueue.main.async {
                guard let i = self?.downloads.firstIndex(where: { $0.id == id }) else { return }
                self?.downloads[i].fraction = fraction
                self?.downloads[i].detail = detail
            }
        }
    }

    private func untrack(_ p: Progress) {
        let id = ObjectIdentifier(p)
        progressWatchers[id] = nil
        downloads.removeAll { $0.id == id }
    }
}
