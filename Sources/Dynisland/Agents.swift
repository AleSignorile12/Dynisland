import AppKit
import CoreServices
import OSLog
import SwiftUI

enum AgentKind: String, CaseIterable, Identifiable {
    case claudeCode, claude, codex, chatgpt
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claude: "Claude"
        case .codex: "Codex"
        case .chatgpt: "ChatGPT"
        }
    }
    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .claude: "bubble.left.and.text.bubble.right.fill"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .chatgpt: "bubble.left.fill"
        }
    }
    /// Apps that host the agent, preferred first. The current ChatGPT app (com.openai.codex) holds both chats and Codex;
    /// Claude Code runs in the Claude app's Code tab.
    var bundles: [String] {
        switch self {
        case .claudeCode, .claude: ["com.anthropic.claudefordesktop"]
        case .codex, .chatgpt: ["com.openai.codex", "com.openai.chat"]
        }
    }
    var appURL: URL? { bundles.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first }

    /// Opens the agent's app; false when it isn't installed.
    @discardableResult
    func open() -> Bool {
        guard let url = appURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        return true
    }
}

/// An AI app you added in Settings. It's tracked by watching its Stop button, like the Claude and ChatGPT chats.
struct CustomAgent: Codable, Hashable {
    var id: String
    var name: String
    var bundleID: String
}

/// Live state of AI agents, event-driven so activities start and finish the moment they do:
/// - Claude Code (terminal and the Claude app's Code tab): FSEvents on its session transcripts.
/// - The ChatGPT app (and the Codex CLI) write every thread to ~/.codex/sessions. A thread with no project (the app's
///   scratch folder ~/Documents/Codex) is a ChatGPT chat; one in a real project folder is Codex. The app's own background
///   "guardian review" threads are ignored. A turn starts with `task_started` and ends with `task_complete`.
/// - Claude chats, the older ChatGPT app and agents you add: no files, so the app's Stop button is watched through Accessibility.
@Observable
final class AgentService {
    struct Agent: Identifiable {
        let key: String          // AgentKind raw value, or a custom agent's id
        let kind: AgentKind?     // nil for agents you added
        let name: String
        let symbol: String
        let bundles: [String]    // apps that host it, preferred first
        var icon: NSImage?
        var id: String { key }
        var running = false
        var project = ""
        var lastActive: Date?
    }

    var agents: [Agent] = []      // the enabled ones, in order
    var all: [Agent] = []         // built-in and added, enabled or not (for Settings)
    var onFinish: (Agent) -> Void = { _ in }
    var active: Agent? { agents.first(where: \.running) }

    var custom: [CustomAgent] {
        didSet { save(); rebuild() }
    }
    var disabled: Set<String> {
        didSet { save(); rebuild() }
    }
    /// Agent key -> bundle id of the app a click opens instead of the agent's own app.
    var links: [String: String] {
        didSet { save(); rebuild() }
    }

    private static let log = Logger(subsystem: "com.local.dynisland", category: "agents")
    private static let genericStops: Set<String> = ["stop", "stop generating", "stop generation", "stop response", "stop streaming"]

    private struct Session { var kind: AgentKind; var running = false; var project = ""; var lastWrite = Date() }

    @ObservationIgnored private let home = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private var kinds: [String: AgentKind] = [:] // Codex file -> who it belongs to
    @ObservationIgnored private var ignored = Set<String>()          // background threads
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private let chats = ChatWatcher()
    @ObservationIgnored private var chatRunning: [String: Bool] = [:]
    @ObservationIgnored private var chatLast: [String: Date] = [:]
    @ObservationIgnored private var timers: [Timer] = []

    init() {
        let d = UserDefaults.standard
        custom = (d.data(forKey: "customAgents")).flatMap { try? JSONDecoder().decode([CustomAgent].self, from: $0) } ?? []
        disabled = Set(d.stringArray(forKey: "disabledAgents") ?? [])
        links = d.dictionary(forKey: "agentLinks") as? [String: String] ?? [:]
        rebuild()
        let fm = FileManager.default
        let claudeDir = home.appending(path: ".claude/projects").path, codexDir = home.appending(path: ".codex/sessions").path
        watch([claudeDir, codexDir].filter { fm.fileExists(atPath: $0) })
        Self.log.info("accessibility trusted: \(AXIsProcessTrusted(), privacy: .public)")

        chats.onChange = { [weak self] key, running in self?.chatChanged(key, running) }
        // Interrupted turns write no end marker; drop sessions silent for 10 minutes (no banner).
        timers.append(.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (path, s) in sessions where s.running && Date().timeIntervalSince(s.lastWrite) > 600 { sessions[path]?.running = false }
            refresh()
        })
    }

    // MARK: Agents list

    func add(appAt url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, !custom.contains(where: { $0.bundleID == id }) else { return }
        custom.append(CustomAgent(id: UUID().uuidString, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), bundleID: id))
    }

    func remove(_ key: String) {
        custom.removeAll { $0.id == key }
        links[key] = nil
    }

    /// The app a click on this agent opens: your link if set, else the agent's own app.
    func appURL(for a: Agent) -> URL? {
        let ids = (links[a.key].map { [$0] } ?? []) + a.bundles
        return ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(custom), forKey: "customAgents")
        d.set(Array(disabled), forKey: "disabledAgents")
        d.set(links, forKey: "agentLinks")
    }

    /// Rebuilds the lists (keeping live state) and tells the Stop-button watcher which apps to look at.
    private func rebuild() {
        let builtIn = AgentKind.allCases.map { Agent(key: $0.rawValue, kind: $0, name: $0.name, symbol: $0.symbol, bundles: $0.bundles) }
        let added = custom.map { Agent(key: $0.id, kind: nil, name: $0.name, symbol: "sparkles", bundles: [$0.bundleID]) }
        let old = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        all = (builtIn + added).map { a in
            var a = a
            if let o = old[a.key] { a.running = o.running; a.project = o.project; a.lastActive = o.lastActive }
            a.icon = appURL(for: a).map { NSWorkspace.shared.icon(forFile: $0.path) }
            return a
        }
        agents = all.filter { !disabled.contains($0.key) }
        var targets: [ChatWatcher.Target] = []
        if !disabled.contains(AgentKind.claude.rawValue) {
            targets.append(.init(key: AgentKind.claude.rawValue, bundles: ["com.anthropic.claudefordesktop"], labels: ["stop response", "stop generating", "stop"]))
        }
        if !disabled.contains(AgentKind.chatgpt.rawValue) { // the older chat-only app; the current one is covered by its session files
            targets.append(.init(key: AgentKind.chatgpt.rawValue, bundles: ["com.openai.chat"], labels: ["stop", "stop generation", "stop generating", "stop streaming"]))
        }
        for c in custom where !disabled.contains(c.id) { targets.append(.init(key: c.id, bundles: [c.bundleID], labels: Self.genericStops)) }
        chats.targets = targets
    }

    // MARK: Transcripts

    private func watch(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            let me = Unmanaged<AgentService>.fromOpaque(info!).takeUnretainedValue()
            for path in unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [] where path.hasSuffix(".jsonl") { me.read(path) }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        stream = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03, FSEventStreamCreateFlags(flags))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    /// Who a Codex session file belongs to, from its first line (session_meta). nil: a background thread to ignore.
    private func codexOwner(_ path: String) -> AgentKind? {
        if let k = kinds[path] { return k }
        if ignored.contains(path) { return nil }
        guard let h = FileHandle(forReadingAtPath: path) else { return .codex }
        defer { try? h.close() }
        var head = Data()
        while head.count < 4_000_000, !head.contains(0x0A), let chunk = try? h.read(upToCount: 65_536), !chunk.isEmpty { head += chunk }
        let first = head.split(separator: 0x0A, maxSplits: 1).first.map { Data($0) } ?? Data()
        let meta = ((try? JSONSerialization.jsonObject(with: first)) as? [String: Any])?["payload"] as? [String: Any] ?? [:]
        guard let kind = Self.codexOwner(meta: meta, home: home.path) else { ignored.insert(path); return nil }
        kinds[path] = kind
        return kind
    }

    static func codexOwner(meta: [String: Any], home: String) -> AgentKind? {
        if let source = meta["thread_source"] as? String, source != "user" { return nil } // e.g. guardian_review
        let cwd = meta["cwd"] as? String ?? ""
        return cwd.hasPrefix(home + "/Documents/Codex/") ? .chatgpt : .codex
    }

    /// Reads the lines appended since the last read. A file seen for the first time is read from its last 64 KB,
    /// which is enough to know whether its turn is still running.
    private func read(_ path: String) {
        let kind: AgentKind
        if path.contains("/.claude/projects/") {
            // Only <project>/<session>.jsonl; subagent transcripts live deeper and must not end the main turn.
            guard path.split(separator: "/").count == home.pathComponents.count + 3 else { return }
            kind = .claudeCode
        } else {
            guard let owner = codexOwner(path) else { return }
            kind = owner
        }
        guard !disabled.contains(kind.rawValue) else { return }

        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let firstSight = offsets[path] == nil
        var start = offsets[path] ?? (size > 65_536 ? size - 65_536 : 0)
        if start > size { start = 0 } // file was rewritten
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return } // wait for a full line
        offsets[path] = start + UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)

        for line in data[..<lastNewline].split(separator: 0x0A) {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let event = kind == .claudeCode ? Self.claudeEvent(j) : Self.codexEvent(j)
            if let project = event.project { sessions[path, default: Session(kind: kind)].project = project }
            if let running = event.running { set(path, kind, running: running, banner: event.banner && !firstSight) }
        }
        refresh()
    }

    typealias Event = (running: Bool?, banner: Bool, project: String?)

    /// Claude Code transcript line -> state change. Metadata lines (titles, modes, snapshots) change nothing.
    static func claudeEvent(_ j: [String: Any]) -> Event {
        let project = (j["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        if j["isSidechain"] as? Bool == true || j["isMeta"] as? Bool == true { return (nil, false, project) }
        let message = j["message"] as? [String: Any]
        switch j["type"] as? String {
        case "user":
            let content = message?["content"]
            let text = content as? String ?? (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.first
            if text?.hasPrefix("[Request interrupted") == true { return (false, false, project) } // you pressed Stop: no banner
            return (true, false, project)
        case "assistant":
            return (message?["stop_reason"] as? String != "end_turn", true, project)
        case "system" where j["subtype"] as? String == "stop_hook_summary":
            return (false, true, project)
        default:
            return (nil, false, project)
        }
    }

    /// Codex rollout line -> state change.
    static func codexEvent(_ j: [String: Any]) -> Event {
        let payload = j["payload"] as? [String: Any]
        let project = (payload?["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        guard j["type"] as? String == "event_msg" else { return (nil, false, project) }
        switch payload?["type"] as? String {
        case "task_started": return (true, false, project)
        case "task_complete": return (false, true, project)
        case "turn_aborted": return (false, false, project)
        default: return (nil, false, project)
        }
    }

    private func set(_ path: String, _ kind: AgentKind, running: Bool, banner: Bool) {
        var s = sessions[path] ?? Session(kind: kind)
        let was = s.running
        if was != running { Self.log.notice("\(kind.rawValue, privacy: .public) \(running ? "started" : "finished", privacy: .public)") }
        s.running = running
        s.lastWrite = Date()
        sessions[path] = s
        if was, !running, banner, let agent = agents.first(where: { $0.kind == kind }) {
            var finished = agent
            finished.project = kind == .claudeCode ? s.project : (codexThreadName(path) ?? (kind == .chatgpt ? "" : s.project))
            onFinish(finished)
        }
    }

    /// The ChatGPT app keeps thread titles in ~/.codex/session_index.jsonl, keyed by the id at the end of the file name.
    private func codexThreadName(_ path: String) -> String? {
        let id = String((path as NSString).deletingPathExtension.suffix(36))
        guard let index = try? String(contentsOf: home.appending(path: ".codex/session_index.jsonl"), encoding: .utf8) else { return nil }
        return index.split(separator: "\n").reversed().lazy.compactMap { line -> String? in
            guard line.contains(id), let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return j["thread_name"] as? String
        }.first
    }

    // MARK: Chats

    private func chatChanged(_ key: String, _ running: Bool) {
        // The Claude app's Code tab shows the same Stop button as its chats; those turns are already tracked from files.
        let isCode = key == AgentKind.claude.rawValue
            && sessions.values.contains { $0.kind == .claudeCode && ($0.running || Date().timeIntervalSince($0.lastWrite) < 3) }
        let was = chatRunning[key] ?? false
        Self.log.notice("\(key, privacy: .public) chat \(running ? "started" : "finished", privacy: .public) code=\(isCode, privacy: .public)")
        chatRunning[key] = running && !isCode
        if was, !running { chatLast[key] = Date() }
        if was, !running, !isCode, let agent = agents.first(where: { $0.key == key }) { onFinish(agent) }
        refresh()
    }

    private func refresh() {
        for list in [\AgentService.all, \AgentService.agents] as [ReferenceWritableKeyPath<AgentService, [Agent]>] {
            for i in self[keyPath: list].indices {
                var a = self[keyPath: list][i]
                let mine = sessions.values.filter { $0.kind == a.kind && a.kind != nil }
                let chat = chatRunning[a.key] ?? false
                a.running = chat || mine.contains(where: \.running)
                if let latest = mine.max(by: { $0.lastWrite < $1.lastWrite }) {
                    a.project = latest.project
                    a.lastActive = latest.lastWrite
                }
                if let c = chatLast[a.key], c > (a.lastActive ?? .distantPast) { a.lastActive = c }
                self[keyPath: list][i] = a
            }
        }
    }
}

/// Watches apps for their "Stop" button (shown only while a reply is being generated).
/// A full accessibility scan runs only while that app is frontmost, which is where a prompt gets sent; once found, the
/// button element itself is re-checked cheaply until it disappears, even after you switch away.
final class ChatWatcher {
    struct Target {
        let key: String
        let bundles: [String]
        let labels: Set<String> // exact Stop labels: apps have other "Stop …" buttons (dictation, voice) that must not count
    }
    var onChange: (String, Bool) -> Void = { _, _ in }
    var targets: [Target] = [] // set on the main thread

    private var found: [String: AXUIElement] = [:]
    private var seen: [String: Int] = [:] // consecutive polls with a Stop button, to ignore one-frame flickers
    private var running: [String: Bool] = [:]
    private var enabledPIDs = Set<pid_t>()
    private let queue = DispatchQueue(label: "dynisland.chat-watcher")
    private var timer: Timer?

    init() {
        timer = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var live: [(Target, pid_t, Bool)] = []
        for t in targets {
            for bundle in t.bundles {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
                live.append((t, app.processIdentifier, bundle == front))
                break
            }
        }
        let keys = Set(targets.map(\.key))
        queue.async { [self] in
            for (t, pid, frontmost) in live {
                let root = AXUIElementCreateApplication(pid)
                if !enabledPIDs.contains(pid) { // Electron apps only expose their web UI once asked
                    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    enabledPIDs.insert(pid)
                }
                if let button = found[t.key], !Self.isStop(button, t.labels) { found[t.key] = nil }
                if found[t.key] == nil, frontmost { found[t.key] = Self.findStop(in: root, t.labels) }
                seen[t.key] = found[t.key] == nil ? 0 : (seen[t.key] ?? 0) + 1
                let now = (seen[t.key] ?? 0) >= 2
                if now != (running[t.key] ?? false) {
                    running[t.key] = now
                    DispatchQueue.main.async { self.onChange(t.key, now) }
                }
            }
            // An app that quit (or was removed) mid-reply has stopped too.
            for (key, on) in running where on && (!keys.contains(key) || !live.contains(where: { $0.0.key == key })) {
                running[key] = false; found[key] = nil
                DispatchQueue.main.async { self.onChange(key, false) }
            }
        }
    }

    private static let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray

    private static func values(_ e: AXUIElement) -> [AnyObject]? {
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success else { return nil }
        return out as [AnyObject]?
    }

    private static func isStopLabel(_ v: [AnyObject], _ labels: Set<String>) -> Bool {
        guard v[0] as? String == kAXButtonRole else { return false }
        return [v[1], v[2]].contains { labels.contains(($0 as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    static func isStop(_ e: AXUIElement, _ labels: Set<String>) -> Bool { values(e).map { isStopLabel($0, labels) } ?? false }

    /// Depth-first, last child first: the composer and its Stop button sit at the end of the window's tree.
    static func findStop(in root: AXUIElement, _ labels: Set<String>) -> AXUIElement? {
        var stack = (values(root)?[3] as? [AXUIElement]) ?? []
        if let windows = axValue(root, kAXWindowsAttribute) as? [AXUIElement] { stack = windows }
        var budget = 8000
        while let e = stack.popLast(), budget > 0 {
            budget -= 1
            guard let v = values(e) else { continue }
            if isStopLabel(v, labels) { return e }
            stack.append(contentsOf: (v[3] as? [AXUIElement]) ?? [])
        }
        return nil
    }
}

struct AgentsSection: View {
    let agents: AgentService
    let open: (AgentService.Agent) -> Void

    var body: some View {
        // Two rows; more than four agents scroll sideways.
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(50), spacing: 10), GridItem(.fixed(50), spacing: 10)], spacing: 10) {
                ForEach(agents.agents) { a in
                    Button { open(a) } label: {
                        HStack(spacing: 10) {
                            AgentIcon(agent: a, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                status(a).font(.system(size: 10)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(width: agents.agents.count > 4 ? 200 : 264, height: 50)
                        .background(.white.opacity(a.running ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(a.name)")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private func status(_ a: AgentService.Agent) -> some View {
        if a.icon == nil {
            Text("App not installed").foregroundStyle(.secondary)
        } else if a.running {
            Text(a.project.isEmpty ? "Working…" : "Working · \(a.project)").foregroundStyle(Prefs.shared.accent)
        } else if let last = a.lastActive {
            Text("Done \(last, format: .relative(presentation: .named))").foregroundStyle(.secondary)
        } else {
            Text("Idle").foregroundStyle(.secondary)
        }
    }
}

/// The agent's app icon, breathing while it works.
struct AgentIcon: View {
    let agent: AgentService.Agent
    let size: CGFloat
    var body: some View {
        Group {
            if let icon = agent.icon { Image(nsImage: icon).resizable() }
            else { Image(systemName: agent.symbol).resizable().scaledToFit().padding(size * 0.2).foregroundStyle(Prefs.shared.accent) }
        }
        .frame(width: size, height: size)
        .phaseAnimator(agent.running ? [1.0, 0.5] : [1.0]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
    }
}
