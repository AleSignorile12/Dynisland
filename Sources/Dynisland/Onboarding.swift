import AppKit
import AVFoundation
import EventKit
import ServiceManagement
import Speech
import SwiftUI

/// First-launch welcome: what the island does, which pages to keep, the look, and the permissions, each with a reason.
/// Shown once (closing it early counts); Settings → General → Welcome tour brings it back.
enum Onboarding {
    static func window(model: IslandModel, finish: @escaping () -> Void) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(model: model, finish: finish))
        w.center()
        return w
    }
}

private struct OnboardingView: View {
    let model: IslandModel
    let finish: () -> Void
    @State private var page = 0
    @State private var forward = true
    private let pages = 6

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Group {
                    switch page {
                    case 0: WelcomePage()
                    case 1: HowPage()
                    case 2: PagesPage(model: model)
                    case 3: LookPage()
                    case 4: PermissionsPage()
                    default: DonePage()
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                Button("Back") { go(-1) }.opacity(page == 0 ? 0 : 1).disabled(page == 0)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == page ? Color.primary : Color.secondary.opacity(0.35)).frame(width: i == page ? 18 : 7, height: 7)
                    }
                }
                Spacer()
                Button(page == pages - 1 ? "Start Using Dynisland" : "Continue") { page == pages - 1 ? finish() : go(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 620, height: 520)
        .animation(.spring(duration: 0.45, bounce: 0.15), value: page)
    }

    private func go(_ d: Int) {
        forward = d > 0
        page = min(max(page + d, 0), pages - 1)
    }
}

private struct Header: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30, weight: .semibold)).foregroundStyle(Prefs.shared.accent)
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .padding(.top, 44)
    }
}

private struct WelcomePage: View {
    @State private var shown = false
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                .scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0)
            Text("Welcome to Dynisland").font(.system(size: 30, weight: .bold))
            Text("Your notch becomes a live island: music, files, timers, AI agents, scores and more, right where your eyes already are.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            Spacer()
        }
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.35).delay(0.1)) { shown = true } }
    }
}

private struct HowPage: View {
    var body: some View {
        VStack(spacing: 26) {
            Header(icon: "hand.point.up.left.fill", title: "Meet the island", subtitle: "Everything lives in the black shape around your camera.")
            VStack(alignment: .leading, spacing: 16) {
                tip("cursorarrow.motionlines", "Bring the pointer near the notch", "It opens on its own and closes when you move away.")
                tip("arrow.left.arrow.right", "Switch pages", "Click the icons at the top, or press ← → while the pointer is on it.")
                tip("tray.and.arrow.down.fill", "Drop anything on it", "Files, links and text land on the shelf. The left tile sends them by AirDrop.")
                tip("rectangle.inset.topright.filled", "Live activities", "Music, timers, AI agents, downloads and live scores show beside the notch while it's closed.")
                tip("contextualmenu.and.cursorarrow", "Right-click for Settings", "Or use the gear page inside the island.")
            }
            .frame(maxWidth: 460)
            Spacer()
        }
    }
    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Prefs.shared.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PagesPage: View {
    let model: IslandModel
    var body: some View {
        VStack(spacing: 22) {
            Header(icon: "square.grid.2x2.fill", title: "Pick your pages", subtitle: "Keep only what you use. You can change this and the order later in Settings → Modules.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(model.sectionOrder) { s in
                    let on = !model.disabledSections.contains(s)
                    Button {
                        if on { model.disabledSections.insert(s) } else { model.disabledSections.remove(s) }
                    } label: {
                        HStack(spacing: 8) {
                            ModuleIcon(section: s).saturation(on ? 1 : 0).opacity(on ? 1 : 0.5)
                            Text(s.title).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Prefs.shared.accent : .secondary)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(on ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 540)
            Spacer()
        }
    }
}

private struct LookPage: View {
    @Bindable var prefs = Prefs.shared
    var body: some View {
        VStack(spacing: 22) {
            Header(icon: "paintpalette.fill", title: "Make it yours", subtitle: "Pick a look. The closed island always stays black so it blends into the notch.")
            IslandPreview()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Prefs.presets) { PresetButton(preset: $0) }
            }
            .frame(maxWidth: 480)
            Picker("Open size", selection: $prefs.size) {
                ForEach(Prefs.Size.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 300)
            Spacer()
        }
    }
}

private struct PermissionsPage: View {
    var body: some View {
        VStack(spacing: 18) {
            Header(icon: "hand.raised.fill", title: "Permissions", subtitle: "Each one unlocks a feature. All optional: skip any, and grant it later from Settings → Permissions.")
            TimelineView(.periodic(from: .now, by: 1)) { _ in // statuses refresh as you grant them
                VStack(spacing: 0) {
                    row("keyboard", "Accessibility", "Volume & brightness keys, ← →, notifications, AI chats", AXIsProcessTrusted()) {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    Divider()
                    row("camera.fill", "Camera", "Mirror", AVCaptureDevice.authorizationStatus(for: .video) == .authorized) {
                        AVCaptureDevice.requestAccess(for: .video) { _ in }
                    }
                    Divider()
                    row("calendar", "Calendars", "Calendar page", EKEventStore.authorizationStatus(for: .event) == .fullAccess) {
                        EKEventStore().requestFullAccessToEvents { _, _ in }
                    }
                    Divider()
                    row("waveform", "Speech Recognition", "Live captions", SFSpeechRecognizer.authorizationStatus() == .authorized) {
                        SFSpeechRecognizer.requestAuthorization { _ in }
                    }
                    Divider()
                    row("speaker.wave.2.fill", "System Audio Recording", "Volume mixer and captions (macOS asks on first use)", nil) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                }
                .padding(.horizontal, 14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 520)
            }
            Spacer()
        }
    }

    private func row(_ icon: String, _ name: String, _ use: String, _ granted: Bool?, ask: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Prefs.shared.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.headline)
                Text(use).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted == true {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button(granted == nil ? "Open…" : "Allow", action: ask)
            }
        }
        .padding(.vertical, 9)
    }
}

private struct DonePage: View {
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Prefs.shared.accent)
                .symbolEffect(.bounce, value: atLogin)
            Text("You're all set").font(.system(size: 28, weight: .bold))
            Text("The island will open for a moment so you can see where it lives.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Launch Dynisland at login", isOn: Binding(get: { atLogin }, set: { on in
                _ = try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                atLogin = SMAppService.mainApp.status == .enabled
            }))
            .toggleStyle(.switch)
            .padding(.top, 6)
            Spacer()
        }
    }
}
