import AppKit
import AVFoundation
import EventKit
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: Window

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, modules, timers, nowPlaying, agents, scores, captions, permissions
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .modules: "Modules"
        case .timers: "Timers"
        case .nowPlaying: "Now Playing"
        case .agents: "AI Agents"
        case .scores: "Scores"
        case .captions: "Captions & Prompter"
        case .permissions: "Permissions"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .modules: "square.grid.2x2.fill"
        case .timers: "timer"
        case .nowPlaying: "music.note"
        case .agents: "sparkles"
        case .scores: "sportscourt.fill"
        case .captions: "captions.bubble.fill"
        case .permissions: "hand.raised.fill"
        }
    }
    var tint: Color {
        switch self {
        case .general, .modules: .gray
        case .appearance: .blue
        case .timers: .orange
        case .nowPlaying: .pink
        case .agents: .purple
        case .scores: .green
        case .captions: .teal
        case .permissions: .indigo
        }
    }
}

/// System Settings–style window: a sidebar of panes, the selected pane on the right.
enum SettingsWindow {
    static func make(model: IslandModel) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: SettingsRoot(model: model))
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 680, height: 460)
        w.setContentSize(NSSize(width: 760, height: 580))
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }
}

private struct SettingsRoot: View {
    let model: IslandModel
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section { ForEach([SettingsPane.general, .appearance, .modules]) { row($0) } }
                Section("Module settings") { ForEach([SettingsPane.timers, .nowPlaying, .agents, .scores, .captions]) { row($0) } }
                Section { row(.permissions) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .modules: ModulesSettings(model: model)
                case .timers: TimerSettings()
                case .nowPlaying: NowPlayingSettings()
                case .agents: AgentSettings()
                case .scores: ScoresSettings(sports: model.sports)
                case .captions: CaptionSettings(captions: model.captions, prompter: model.prompter)
                case .permissions: PermissionsSettings()
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private func row(_ p: SettingsPane) -> some View {
        Label {
            Text(p.title)
        } icon: {
            Image(systemName: p.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(p.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .tag(p)
    }
}

private let appVersion = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"

// MARK: General

private struct GeneralSettings: View {
    @Bindable var prefs = Prefs.shared
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = false
    @State private var showHistory = false

    var body: some View {
        Form {
            Section {
                Toggle("Show the island", isOn: $prefs.showIsland)
                Toggle("Launch Dynisland at login", isOn: Binding(get: { atLogin }, set: setLogin))
                Toggle("Hide the island from screen sharing", isOn: $prefs.hideFromSharing)
            } footer: {
                if !prefs.showIsland { note("Hidden. Open Dynisland again from Finder or Spotlight to get back here.") }
                if loginError { note("macOS refused the login item. Move Dynisland to Applications and try again.") }
            }
            Section {
                Toggle("Open only when I click the notch", isOn: $prefs.clickToOpen)
                Toggle("Keep it open after I click it", isOn: $prefs.keepOpenAfterClick)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $prefs.hoverDelay, in: 0...1, step: 0.05).frame(width: 180).disabled(prefs.clickToOpen)
                        Text(String(format: "%.2f s", prefs.hoverDelay)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle("Haptic feedback when it opens", isOn: $prefs.haptics)
                Toggle("Sounds when it opens and closes", isOn: $prefs.sounds)
            } header: {
                Text("Opening")
            } footer: {
                note(prefs.keepOpenAfterClick ? "After a click the island stays open until you click somewhere else."
                                              : "The island closes as soon as the pointer leaves it.")
            }
            Section {
                LabeledContent("Version") {
                    HStack {
                        Text(appVersion).textSelection(.enabled)
                        Button("What's New") { showHistory = true }
                            .popover(isPresented: $showHistory, arrowEdge: .bottom) { WhatsNew().frame(width: 340, height: 360) }
                    }
                }
                LabeledContent("Quit") { Button("Quit Dynisland") { NSApp.terminate(nil) } }
            }
        }
        .formStyle(.grouped)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = false
        } catch { loginError = true }
        atLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct WhatsNew: View {
    /// Newest first. Add an entry whenever MARKETING_VERSION goes up.
    private let history: [(String, [String])] = [
        ("1.1", ["Settings with a sidebar, live island preview and per-module pages", "Follow many leagues incl. EuroLeague and EuroCup, live score in the closed notch", "Prompter under the camera, hidden from screen sharing", "Captions can start by themselves", "Mirror centred under the camera with a bigger light", "Color presets, island and accent colors", "Click-to-open, keep open, hover delay, haptics, sounds",
                 "Pomodoro timer", "Mirror light and flip", "Internet speed test on the System page", "Clipboard inside the Shelf page",
                 "Settings page in the island", "Sports scores", "Live captions hidden from screen sharing", "Arrow keys switch pages",
                 "Smoother volume & brightness HUD"]),
        ("1.0", ["Music with lyrics, scrubber and volume", "Shelf & AirDrop", "Calendar, timer, clipboard, mirror", "Quick controls, system stats, volume mixer",
                 "AI agent live activities", "Charging, downloads, notifications and accessory cards"]),
    ]
    var body: some View {
        List {
            ForEach(history, id: \.0) { v, notes in
                Section("Version \(v)") { ForEach(notes, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout) } }
            }
        }
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @Bindable var prefs = Prefs.shared

    var body: some View {
        Form {
            Section { IslandPreview().frame(maxWidth: .infinity).padding(.vertical, 10) }
            Section("Presets") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Prefs.presets) { PresetButton(preset: $0) }
                }
                .padding(.vertical, 4)
            }
            Section {
                colorRow("Island", hex: prefs.islandHex, set: prefs.setIsland)
                colorRow("Accent", hex: prefs.accentHex) { prefs.accentHex = $0.hex }
            } header: {
                Text("Colors")
            } footer: {
                note("The closed island always stays black so it blends into the notch. Island colors are kept dark so text stays readable.")
            }
            Section("Island") {
                Picker("Open size", selection: $prefs.size) {
                    ForEach(Prefs.Size.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Bouncy animations", isOn: $prefs.bouncy)
            }
            Section {
                HStack {
                    note("Defaults: black island, orange accent, regular size.")
                    Spacer()
                    Button("Reset") { prefs.resetAppearance() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func colorRow(_ title: String, hex: String, set: @escaping (Color) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(hex).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: set), supportsOpacity: false).labelsHidden()
            }
        }
    }
}

private struct PresetButton: View {
    let preset: Prefs.Preset
    let prefs = Prefs.shared
    var body: some View {
        let on = preset.island == prefs.islandHex && preset.accent == prefs.accentHex
        let fill = Color(hex: preset.island).opacity(preset.island == "#000000" ? 0.25 : 0.9)
        Button { prefs.apply(preset) } label: {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: preset.accent)).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                Text(preset.name).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// A small open island drawn with the current colors and animation, so changes show before you hover the real one.
private struct IslandPreview: View {
    let prefs = Prefs.shared
    @State private var progress = 0.82
    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(ear: 10, bottom: 22).fill(prefs.island)
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Capsule().fill(prefs.accent).frame(width: 52, height: 16)
                        .overlay(Label("Timer", systemImage: "timer").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.8)))
                    Image(systemName: "music.note")
                    Image(systemName: "speaker.wave.2.fill")
                    Spacer()
                    Capsule().fill(.black).frame(width: 70, height: 16) // the camera housing
                    Spacer()
                    Image(systemName: "sparkles")
                    Image(systemName: "gearshape.fill")
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ProgressRing(fraction: progress, tint: prefs.accent, lineWidth: 4).frame(width: 34, height: 34)
                    Text("24:57").font(.system(size: 28, weight: .semibold).monospacedDigit()).foregroundStyle(prefs.accent)
                    Spacer()
                    Text("Start").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).frame(height: 28).background(prefs.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 26).padding(.top, 8)
        }
        .frame(width: 380, height: 110)
        .environment(\.colorScheme, .dark)
        .animation(.islandOpen, value: prefs.accentHex)
        .animation(.islandOpen, value: prefs.islandHex)
        .onTapGesture { withAnimation(.islandOpen) { progress = progress > 0.5 ? 0.25 : 0.82 } }
        .help("Click to try the animation")
    }
}

// MARK: Modules

private struct ModulesSettings: View {
    let model: IslandModel

    var body: some View {
        Form {
            Section {
                ForEach(Array(model.sectionOrder.enumerated()), id: \.element) { i, s in
                    ModuleRow(model: model, section: s, index: i)
                }
            } header: {
                Text("Pages in the island")
            } footer: {
                note("Arrows change the order of the tabs. The menu picks the app a click on the page's empty area opens. In the island, ← → switch pages while the pointer is on it.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Icon tile with its own colour, so it stays visible whatever accent you pick.
struct ModuleIcon: View {
    let section: IslandSection
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(section.tint.gradient)
            Image(systemName: section.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
        }
        .frame(width: 28, height: 28)
    }
}

private struct ModuleRow: View {
    let model: IslandModel
    let section: IslandSection
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            ModuleIcon(section: section)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                Text(section.permissions == "no permissions" ? "No permissions needed" : "Needs \(section.permissions)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if section.clickable { appMenu }
            VStack(spacing: 0) {
                arrow("chevron.up", to: index - 1)
                arrow("chevron.down", to: index + 1)
            }
            Toggle("", isOn: Binding(
                get: { !model.disabledSections.contains(section) },
                set: { on in if on { model.disabledSections.remove(section) } else { model.disabledSections.insert(section) } }
            ))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    private func arrow(_ icon: String, to j: Int) -> some View {
        Button {
            withAnimation(.snappy) { model.sectionOrder.swapAt(index, j) }
        } label: {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).frame(width: 18, height: 12)
        }
        .buttonStyle(.borderless)
        .disabled(j < 0 || j >= model.sectionOrder.count)
    }

    private var appMenu: some View {
        let current = model.clickApp(for: section)
        return Menu {
            Button("Nothing") { model.clickApps[section.rawValue] = "" }
            if let d = section.defaultApp, d != current { Button("Default (\(IslandModel.appName(d)))") { model.clickApps[section.rawValue] = nil } }
            Divider()
            Button("Choose App…") { choose() }
        } label: {
            Text(current.map(IslandModel.appName) ?? "Opens nothing")
        }
        .fixedSize()
        .help("App opened by clicking an empty area of this page")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.clickApps[section.rawValue] = id
    }
}

extension IslandSection {
    /// What macOS will ask for the first time the page is used.
    var permissions: String {
        switch self {
        case .calendar: "Calendars"
        case .mirror: "Camera"
        case .controls: "Automation"
        case .mixer: "System Audio Recording"
        case .agents: "Accessibility"
        case .captions: "Speech Recognition, System Audio Recording"
        case .sports: "internet, no permissions"
        default: "no permissions"
        }
    }
    var clickable: Bool { self != .agents && self != .settings }
    var tint: Color {
        switch self {
        case .media: .pink
        case .shelf: .blue
        case .calendar: .red
        case .timer: .orange
        case .mirror: .cyan
        case .controls: .gray
        case .system: .indigo
        case .mixer: .purple
        case .agents: .orange
        case .sports: .green
        case .captions: .teal
        case .settings: .gray
        }
    }
}

// MARK: Module settings

private struct TimerSettings: View {
    @Bindable var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Stepper("Focus: \(prefs.focusMinutes) min", value: $prefs.focusMinutes, in: 5...120, step: 5)
                Stepper("Short break: \(prefs.shortBreakMinutes) min", value: $prefs.shortBreakMinutes, in: 1...30)
                Stepper("Long break: \(prefs.longBreakMinutes) min", value: $prefs.longBreakMinutes, in: 5...60, step: 5)
            } header: {
                Text("Pomodoro")
            } footer: {
                note("Four focus sessions, a short break after each, a long break after the fourth. Changes apply to the next phase.")
            }
            Section { Toggle("Play a sound when a timer ends", isOn: $prefs.timerSound) }
        }
        .formStyle(.grouped)
    }
}

private struct NowPlayingSettings: View {
    @Bindable var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Toggle("Show live activity while music plays", isOn: $prefs.musicActivity)
                Toggle("Tint the equalizer with album colors", isOn: $prefs.albumTint)
            }
            Section {
                Toggle("Show synced lyrics", isOn: $prefs.lyrics)
            } footer: {
                note("Lyrics come from lrclib.net, which receives the song title and artist. Off: nothing is sent.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    @Bindable var prefs = Prefs.shared
    var body: some View {
        Form {
            Section {
                Toggle("Show live activity while an agent works", isOn: $prefs.agentActivity)
                Toggle("Show a card when an agent is done", isOn: $prefs.agentCards)
            } footer: {
                note("Tracks Claude Code, Claude, Codex and ChatGPT. Chats need Accessibility to spot the Stop button.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScoresSettings: View {
    let sports: SportsService
    @State private var query = ""

    var body: some View {
        Form {
            Section("Add") {
                TextField("", text: $query, prompt: Text("Search leagues: NBA, EuroLeague, Serie A…"))
                    .textFieldStyle(.roundedBorder)
                let hits = SportsService.catalog.filter { !query.isEmpty && $0.name.localizedCaseInsensitiveContains(query) && !sports.followed.contains($0) }
                ForEach(hits) { l in
                    HStack {
                        Label(l.name, systemImage: l.sport.icon)
                        Spacer()
                        Button("Follow") { sports.follow(l); query = "" }
                    }
                }
                if !query.isEmpty && hits.isEmpty { note("No match among the leagues not followed yet.") }
            }
            Section("Following") {
                if sports.followed.isEmpty { note("Nothing yet. Add a league above or switch one on below.") }
                ForEach(sports.followed) { l in
                    HStack {
                        Label(l.name, systemImage: l.sport.icon)
                        Spacer()
                        Button("Remove") { sports.unfollow(l) }
                    }
                }
                .onMove { sports.followed.move(fromOffsets: $0, toOffset: $1) }
                Picker("Show in the closed notch", selection: Binding(get: { sports.notchLeague }, set: { sports.notchLeague = $0 })) {
                    Text("Nothing").tag("")
                    Text("Any followed league").tag("*")
                    Divider()
                    ForEach(sports.followed) { Text($0.name).tag($0.id) }
                }
            }
            ForEach(Sport.allCases) { sport in
                Section {
                    ForEach(SportsService.catalog.filter { $0.sport == sport }) { l in
                        Toggle(l.name, isOn: Binding(get: { sports.followed.contains(l) }, set: { $0 ? sports.follow(l) : sports.unfollow(l) }))
                    }
                } header: {
                    Label(sport.title, systemImage: sport.icon)
                }
            }
            Section {
                note("Live scores from ESPN's public scoreboards, the official EuroLeague API (EuroLeague, EuroCup) and legabasket.it (LBA, from the site's own data, so it can break if they change their site). Serie A2 has no score feed: it shows as a button that opens LNP's site. The closed notch shows a live game's score while one is on.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CaptionSettings: View {
    let captions: CaptionsService
    @Bindable var prompter: PrompterService
    @Bindable var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Toggle("Start automatically when something plays", isOn: $prefs.captionsAuto)
                Picker("Language", selection: Binding(get: { captions.language }, set: { captions.language = $0 })) {
                    ForEach(CaptionsService.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $prefs.captionSize, in: 14...32, step: 1).frame(width: 180)
                        Text("\(Int(prefs.captionSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Live Captions")
            } footer: {
                note("Automatic captions turn on when any app plays sound and off after 15 s of silence. Turning them off by hand keeps them off until the sound stops.")
            }
            Section {
                TextEditor(text: $prompter.script)
                    .font(.system(size: 13))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                LabeledContent("Scroll time") {
                    HStack {
                        Stepper(TimerService.format(prompter.duration), value: Binding(get: { prompter.duration }, set: { prompter.setDuration($0) }),
                                in: 10...3600, step: 15)
                            .monospacedDigit()
                        Text("· \(prompter.words) words, \(prompter.wordsPerMinute) wpm").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $prompter.fontSize, in: 14...44, step: 1).frame(width: 180)
                        Text("\(Int(prompter.fontSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Height") {
                    HStack {
                        Slider(value: $prompter.height, in: 90...320, step: 10).frame(width: 180)
                        Text("\(Int(prompter.height)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle("3-second countdown before it scrolls", isOn: $prompter.countdown)
                Toggle("Mirror the text (for a teleprompter glass)", isOn: $prompter.mirrored)
                HStack {
                    Button(prompter.playing ? "Pause" : "Start") { prompter.playing ? prompter.pause() : prompter.play() }
                    Button("Restart") { prompter.restart() }
                    if prompter.visible { Button("Hide") { prompter.close() } }
                }
            } header: {
                Text("Prompter")
            } footer: {
                note("The script scrolls through once in the scroll time, right under the camera so you look at the people you talk to. Changing the time while it runs keeps your place. Captions and prompter are left out of screenshots and screen sharing.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsSettings: View {
    @State private var tick = 0 // re-read statuses when the window comes back

    var body: some View {
        Form {
            Section {
                row("Accessibility", "Volume & brightness keys, arrow keys, notifications, AI chat tracking, keeping clear of menus.",
                    AXIsProcessTrusted(), "Privacy_Accessibility")
                row("Camera", "Mirror.", AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "Privacy_Camera")
                row("Calendars", "Calendar page.", EKEventStore.authorizationStatus(for: .event) == .fullAccess, "Privacy_Calendars")
                row("Speech Recognition", "Live captions.", SFSpeechRecognizer.authorizationStatus() == .authorized, "Privacy_SpeechRecognition")
                row("System Audio Recording", "Volume mixer and live captions.", nil, "Privacy_AudioCapture")
                row("Automation", "Dark mode toggle in Quick Controls.", nil, "Privacy_Automation")
            } footer: {
                note("macOS asks for each one the first time a page needs it. Turning them on or off happens in System Settings.")
            }
        }
        .formStyle(.grouped)
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in tick += 1 }
    }

    /// `granted` nil: macOS has no way to ask, so no badge.
    private func row(_ name: String, _ use: String, _ granted: Bool?, _ pane: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(use).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let granted {
                Label(granted ? "Allowed" : "Not allowed", systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption).foregroundStyle(granted ? .green : .secondary)
            }
            Button("Open…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
        }
    }
}

private func note(_ s: String) -> some View {
    Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

// MARK: In-island page

/// The gear page inside the island: the settings you flip most, as Control Center–style toggles, plus colour presets.
struct SettingsModule: View {
    @Bindable var prefs = Prefs.shared
    let openAll: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                toggle("cursorarrow.click", "Click to open", $prefs.clickToOpen)
                toggle("pin.fill", "Keep open", $prefs.keepOpenAfterClick)
                toggle("water.waves", "Haptics", $prefs.haptics)
                toggle("speaker.wave.2.fill", "Sounds", $prefs.sounds)
                toggle("eye.slash.fill", "Hide in shares", $prefs.hideFromSharing)
                toggle("captions.bubble.fill", "Auto captions", $prefs.captionsAuto)
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) { ForEach(Prefs.presets) { dot($0) } }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(.white.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
                Text(appVersion).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                Button(action: openAll) {
                    Label("Settings", systemImage: "gearshape.fill").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ icon: String, _ title: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(on.wrappedValue ? Color.black : .white)
                    .background(on.wrappedValue ? AnyShapeStyle(prefs.accent) : AnyShapeStyle(.white.opacity(0.12)), in: Circle())
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: on.wrappedValue)
    }

    private func dot(_ p: Prefs.Preset) -> some View {
        let on = prefs.accentHex == p.accent && prefs.islandHex == p.island
        return Circle().fill(Color(hex: p.accent)).frame(width: 14, height: 14)
            .overlay { Circle().strokeBorder(.white, lineWidth: on ? 2 : 0).padding(-3) }
            .contentShape(Circle())
            .onTapGesture { prefs.apply(p) }
            .help(p.name)
    }
}
