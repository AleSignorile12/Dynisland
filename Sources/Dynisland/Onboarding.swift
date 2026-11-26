import AppKit
import AVFoundation
import EventKit
import ServiceManagement
import Speech
import SwiftUI

/// First-launch welcome tour, drawn inside the island itself: it grows out of the notch into a large card and walks
/// through what it does, which pages to keep, the look (the island recolours live) and the permissions, each with a reason.
/// Skipping counts as done; Settings → General → Welcome tour shows it again.
struct OnboardingIsland: View {
    let model: IslandModel
    @State private var forward = true
    private let pages = 6
    private var page: Int { model.onboarding ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { // the row beside the camera
                HStack(spacing: 5) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == page ? Prefs.shared.accent : .white.opacity(0.25)).frame(width: i == page ? 16 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
                Color.clear.frame(width: model.notch.width)
                Button("Skip") { model.finishOnboarding() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 22)
                    .opacity(page == pages - 1 ? 0 : 1)
            }
            .frame(height: model.notch.height)

            ZStack {
                Group {
                    switch page {
                    case 0: WelcomeStep()
                    case 1: HowStep()
                    case 2: PagesStep(model: model)
                    case 3: LookStep()
                    case 4: PermissionsStep()
                    default: DoneStep()
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                pill("Back", primary: false) { go(-1) }.opacity(page == 0 ? 0 : 1).disabled(page == 0)
                Spacer()
                pill(page == pages - 1 ? "Start Using Dynisland" : "Continue", primary: true) {
                    page == pages - 1 ? model.finishOnboarding() : go(1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: page)
    }

    private func go(_ d: Int) {
        forward = d > 0
        model.onboarding = min(max(page + d, 0), pages - 1)
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16).frame(height: 30)
                .foregroundStyle(primary ? Color.black : .white)
                .background(primary ? AnyShapeStyle(Prefs.shared.accent) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct StepTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 19, weight: .bold))
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .padding(.top, 10)
    }
}

private struct WelcomeStep: View {
    @State private var shown = false
    var body: some View {
        HStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 92, height: 92)
                .scaleEffect(shown ? 1 : 0.5).opacity(shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Dynisland").font(.system(size: 24, weight: .bold))
                Text("Your notch is now a live island: music, files, timers, AI agents, scores and more, right where your eyes already are.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: 340, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.35).delay(0.15)) { shown = true } }
    }
}

private struct HowStep: View {
    var body: some View {
        VStack(spacing: 14) {
            StepTitle(title: "Meet the island", subtitle: "Everything lives in this black shape around your camera.")
            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                GridRow {
                    tip("cursorarrow.motionlines", "Come close", "It opens when the pointer nears the notch, closes when you leave.")
                    tip("arrow.left.arrow.right", "Switch pages", "Click the icons at the top, or press ← → while on it.")
                }
                GridRow {
                    tip("tray.and.arrow.down.fill", "Drop anything", "Files, links and text land on the shelf, or go by AirDrop.")
                    tip("rectangle.inset.topright.filled", "Live activities", "Music, timers, agents and scores sit beside the notch.")
                }
            }
            .padding(.horizontal, 30)
            Spacer(minLength: 0)
        }
    }
    private func tip(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Prefs.shared.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PagesStep: View {
    let model: IslandModel
    var body: some View {
        VStack(spacing: 12) {
            StepTitle(title: "Pick your pages", subtitle: "Keep only what you use. Order and more options are in Settings → Modules.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(model.sectionOrder) { s in
                    let on = !model.disabledSections.contains(s)
                    Button {
                        if on { model.disabledSections.insert(s) } else { model.disabledSections.remove(s) }
                    } label: {
                        HStack(spacing: 7) {
                            ModuleIcon(section: s).scaleEffect(0.8).frame(width: 22, height: 22)
                                .saturation(on ? 1 : 0).opacity(on ? 1 : 0.45)
                            Text(s.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                                .foregroundStyle(on ? .white : .secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7).frame(height: 32)
                        .background(.white.opacity(on ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Prefs.shared.accent.opacity(on ? 0.6 : 0), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
    }
}

private struct LookStep: View {
    @Bindable var prefs = Prefs.shared
    var body: some View {
        VStack(spacing: 14) {
            StepTitle(title: "Make it yours", subtitle: "Pick a look: the island changes as you choose. When closed it stays black to blend into the notch.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Prefs.presets) { p in
                    let on = p.island == prefs.islandHex && p.accent == prefs.accentHex
                    Button { prefs.apply(p) } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Color(hex: p.accent)).frame(width: 12, height: 12)
                            Text(p.name).font(.system(size: 11, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(Color(hex: p.island).opacity(0.9), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(on ? Color(hex: p.accent) : .white.opacity(0.15), lineWidth: on ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40)
            Picker("", selection: $prefs.size) {
                ForEach(Prefs.Size.allCases) { Text($0.rawValue.capitalized + " size").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            Spacer(minLength: 0)
        }
        .animation(.islandOpen, value: prefs.accentHex)
    }
}

private struct PermissionsStep: View {
    var body: some View {
        VStack(spacing: 10) {
            StepTitle(title: "Permissions", subtitle: "Each one unlocks a feature. All optional: grant any later in Settings → Permissions.")
            TimelineView(.periodic(from: .now, by: 1)) { _ in // statuses refresh as you grant them
                VStack(spacing: 0) {
                    row("keyboard", "Accessibility", "Media keys, ← →, notifications, AI chats", AXIsProcessTrusted()) {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                    row("camera.fill", "Camera", "Mirror", AVCaptureDevice.authorizationStatus(for: .video) == .authorized) {
                        AVCaptureDevice.requestAccess(for: .video) { _ in }
                    }
                    row("calendar", "Calendars", "Calendar page", EKEventStore.authorizationStatus(for: .event) == .fullAccess) {
                        EKEventStore().requestFullAccessToEvents { _, _ in }
                    }
                    row("waveform", "Speech Recognition", "Live captions", SFSpeechRecognizer.authorizationStatus() == .authorized) {
                        SFSpeechRecognizer.requestAuthorization { _ in }
                    }
                    row("speaker.wave.2.fill", "System Audio", "Mixer and captions (asked on first use)", nil) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                }
                .padding(.horizontal, 12)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 40)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ icon: String, _ name: String, _ use: String, _ granted: Bool?, ask: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Prefs.shared.accent).frame(width: 18)
            Text(name).font(.system(size: 11.5, weight: .semibold))
            Text(use).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if granted == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(action: ask) {
                    Text(granted == nil ? "Open…" : "Allow").font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 20)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 29)
    }
}

private struct DoneStep: View {
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Prefs.shared.accent)
                .symbolEffect(.bounce, value: atLogin)
            Text("You're all set").font(.system(size: 22, weight: .bold))
            Text("Bring the pointer to the notch any time. Right-click the island for Settings.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("Launch Dynisland at login", isOn: Binding(get: { atLogin }, set: { on in
                _ = try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                atLogin = SMAppService.mainApp.status == .enabled
            }))
            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }
}
