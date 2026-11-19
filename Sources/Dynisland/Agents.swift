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

/// Live state of AI agents, event-driven so activities start and finish the moment they do:
/// - Claude Code (terminal and the Claude app's Code tab) and Codex (CLI and app): FSEvents on their session transcripts.
///   A typed prompt is written immediately; a turn ends with `end_turn` / `stop_hook_summary` (Claude) or `task_complete` (Codex).
/// - Claude and ChatGPT chats: no files, so the app's Stop button is watched through Accessibility.
@Observable
final class AgentService {
    struct Agent: Identifiable {
        let kind: AgentKind
        let icon: NSImage?
        var id: AgentKind { kind }
        var running = false
        var project = ""
        var lastActive: Date?
    }

    var agents: [Agent] = []
    var onFinish: (Agent) -> Void = { _ in }
    var active: Agent? { agents.first(where: \.running) }
    private static let log = Logger(subsystem: "com.local.dynisland", category: "agents")

    private struct Session { var kind: AgentKind; var running = false; var project = ""; var lastWrite = Date() }

    @ObservationIgnored private let home = FileManager.default.homeDirectoryForCurrentUser
    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private var offsets: [String: UInt64] = [:]
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private let chats = ChatWatcher()
    @ObservationIgnored private var chatRunning: [AgentKind: Bool] = [:]
    @ObservationIgnored private var timers: [Timer] = []

    init() {
        let fm = FileManager.default
        let claudeDir = home.appending(path: ".claude/projects").path, codexDir = home.appending(path: ".codex/sessions").path
        agents = AgentKind.allCases.map { Agent(kind: $0, icon: $0.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }) }
        watch([claudeDir, codexDir].filter { fm.fileExists(atPath: $0) })
        Self.log.info("accessibility trusted: \(AXIsProcessTrusted(), privacy: .public)")

        chats.onChange = { [weak self] kind, running in self?.chatChanged(kind, running) }
        // Interrupted turns write no end marker; drop sessions silent for 10 minutes (no banner).
        timers.append(.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (path, s) in sessions where s.running && Date().timeIntervalSince(s.lastWrite) > 600 { sessions[path]?.running = false }
            refresh()
        })
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

    /// Reads the lines appended since the last read. A file seen for the first time is read from its last 64 KB,
    /// which is enough to know whether its turn is still running.
    private func read(_ path: String) {
        let kind: AgentKind
        if path.contains("/.claude/projects/") {
            // Only <project>/<session>.jsonl; subagent transcripts live deeper and must not end the main turn.
            guard path.split(separator: "/").count == home.pathComponents.count + 3 else { return }
            kind = .claudeCode
        } else { kind = .codex }

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
        if was != running { Self.log.info("\(kind.rawValue, privacy: .public) \(running ? "started" : "finished", privacy: .public)") }
        s.running = running
        s.lastWrite = Date()
        sessions[path] = s
        if was, !running, banner, let agent = agents.first(where: { $0.kind == kind }) {
            var finished = agent
            finished.project = kind == .codex ? (codexThreadName(path) ?? s.project) : s.project
            onFinish(finished)
        }
    }

    /// Codex/ChatGPT keep thread titles in ~/.codex/session_index.jsonl, keyed by the id at the end of the file name.
    private func codexThreadName(_ path: String) -> String? {
        let id = String((path as NSString).deletingPathExtension.suffix(36))
        guard let index = try? String(contentsOf: home.appending(path: ".codex/session_index.jsonl"), encoding: .utf8) else { return nil }
        return index.split(separator: "\n").reversed().lazy.compactMap { line -> String? in
            guard line.contains(id), let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return j["thread_name"] as? String
        }.first
    }

    // MARK: Chats

    private func chatChanged(_ kind: AgentKind, _ running: Bool) {
        // The Claude app's Code tab and ChatGPT's Codex threads show the same Stop button; those turns are already tracked.
        let code: AgentKind = kind == .claude ? .claudeCode : .codex
        let isCode = sessions.values.contains { $0.kind == code && ($0.running || Date().timeIntervalSince($0.lastWrite) < 3) }
        let was = chatRunning[kind] ?? false
        Self.log.info("\(kind.rawValue, privacy: .public) chat \(running ? "started" : "finished", privacy: .public) code=\(isCode, privacy: .public)")
        chatRunning[kind] = running && !isCode
        if was, !running, !isCode, let agent = agents.first(where: { $0.kind == kind }) { onFinish(agent) }
        refresh()
    }

    private func refresh() {
        for i in agents.indices {
            let kind = agents[i].kind
            switch kind {
            case .claudeCode, .codex:
                let mine = sessions.values.filter { $0.kind == kind }
                agents[i].running = mine.contains(where: \.running)
                if let latest = mine.max(by: { $0.lastWrite < $1.lastWrite }) {
                    agents[i].project = latest.project
                    agents[i].lastActive = latest.lastWrite
                }
            case .claude, .chatgpt:
                let running = chatRunning[kind] ?? false
                if agents[i].running && !running { agents[i].lastActive = Date() }
                agents[i].running = running
            }
        }
    }
}

/// Watches the Claude and ChatGPT apps for their "Stop" button (shown only while a reply is being generated).
/// A full accessibility scan runs only while that app is frontmost, which is where a prompt gets sent; once found, the
/// button element itself is re-checked cheaply until it disappears, even after you switch away.
final class ChatWatcher {
    var onChange: (AgentKind, Bool) -> Void = { _, _ in }
    private let apps: [(AgentKind, String)] = [(.claude, "com.anthropic.claudefordesktop"), (.chatgpt, "com.openai.codex"), (.chatgpt, "com.openai.chat")]
    /// The reply's Stop button label in each app. Exact matches only: both apps have many other "Stop …" buttons
    /// (dictation, sharing, read aloud, voice chat) that would otherwise read as a reply finishing.
    private static let labels: [AgentKind: Set<String>] = [
        .claude: ["stop response", "stop generating", "stop"],
        .chatgpt: ["stop", "stop generation", "stop generating", "stop streaming"],
    ]
    private var found: [AgentKind: AXUIElement] = [:]
    private var seen: [AgentKind: Int] = [:] // consecutive polls with a Stop button, to ignore one-frame flickers
    private var running: [AgentKind: Bool] = [:]
    private var enabledPIDs = Set<pid_t>()
    private let queue = DispatchQueue(label: "dynisland.chat-watcher")
    private var timer: Timer?

    init() {
        timer = .scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var targets: [(AgentKind, pid_t, Bool)] = []
        for (kind, bundle) in apps where !targets.contains(where: { $0.0 == kind }) { // first running app per agent
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                targets.append((kind, app.processIdentifier, bundle == front))
            }
        }
        queue.async { [self] in
            for (kind, pid, frontmost) in targets {
                let root = AXUIElementCreateApplication(pid)
                if !enabledPIDs.contains(pid) { // Electron (Claude) only exposes its web UI once asked
                    AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                    enabledPIDs.insert(pid)
                }
                let labels = Self.labels[kind] ?? []
                if let button = found[kind], !Self.isStop(button, labels) { found[kind] = nil }
                if found[kind] == nil, frontmost { found[kind] = Self.findStop(in: root, labels) }
                seen[kind] = found[kind] == nil ? 0 : (seen[kind] ?? 0) + 1
                let now = (seen[kind] ?? 0) >= 2
                if now != (running[kind] ?? false) {
                    running[kind] = now
                    DispatchQueue.main.async { self.onChange(kind, now) }
                }
            }
            // An app that quit mid-reply has stopped too.
            for (kind, _) in apps where running[kind] == true && !targets.contains(where: { $0.0 == kind }) {
                running[kind] = false; found[kind] = nil
                DispatchQueue.main.async { self.onChange(kind, false) }
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
    let open: (AgentKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(agents.agents) { a in
                Button { open(a.kind) } label: {
                    HStack(spacing: 10) {
                        AgentIcon(agent: a, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.kind.name).font(.system(size: 12, weight: .semibold))
                            status(a).font(.system(size: 10)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 50)
                    .background(.white.opacity(a.running ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(a.kind.name)")
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
            else { Image(systemName: agent.kind.symbol).resizable().scaledToFit().padding(size * 0.2).foregroundStyle(Prefs.shared.accent) }
        }
        .frame(width: size, height: size)
        .phaseAnimator(agent.running ? [1.0, 0.5] : [1.0]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
    }
}
