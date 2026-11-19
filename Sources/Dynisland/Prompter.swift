import AppKit
import Observation
import SwiftUI

/// A teleprompter right under the notch, next to the camera so your eyes stay on it. Hidden from screen sharing.
/// The script scrolls through once in `duration` seconds; pausing and changing the time keep your place.
@Observable
final class PrompterService {
    var script: String { didSet { UserDefaults.standard.set(script, forKey: "prompterScript") } }
    var duration: Double { didSet { UserDefaults.standard.set(duration, forKey: "prompterDuration") } } // seconds for the whole script
    var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "prompterFont") } }
    var countdown: Bool { didSet { UserDefaults.standard.set(countdown, forKey: "prompterCountdown") } }
    var mirrored: Bool { didSet { UserDefaults.standard.set(mirrored, forKey: "prompterMirrored") } } // for a beam-splitter glass
    var height: Double { didSet { UserDefaults.standard.set(height, forKey: "prompterHeight"); place() } }

    var start: Date?        // set while scrolling
    var base = 0.0          // progress (0…1) banked before the last start
    var counting: Int?      // 3, 2, 1 before it starts
    var visible = false

    var playing: Bool { start != nil || counting != nil }
    var words: Int { script.split { $0.isWhitespace }.count }
    var wordsPerMinute: Int { duration > 0 ? Int(Double(words) / (duration / 60)) : 0 }

    @ObservationIgnored var notch = CGSize(width: 190, height: 32) // set by the model so the bar hangs right under it
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var countTask: Task<Void, Never>?

    init() {
        let d = UserDefaults.standard
        script = d.string(forKey: "prompterScript") ?? "Paste your script in Settings → Captions & Prompter.\n\nIt scrolls right under the camera, so you can read while looking at the people you talk to. Nobody sees it in a screen share."
        duration = d.object(forKey: "prompterDuration") as? Double ?? 120
        fontSize = d.object(forKey: "prompterFont") as? Double ?? 22
        countdown = d.object(forKey: "prompterCountdown") as? Bool ?? true
        mirrored = d.bool(forKey: "prompterMirrored")
        height = d.object(forKey: "prompterHeight") as? Double ?? 150
    }

    func progress(at now: Date) -> Double {
        min(1, base + (start.map { now.timeIntervalSince($0) / max(duration, 1) } ?? 0))
    }

    func play() {
        show()
        if base >= 1 { base = 0 }
        guard countdown else { start = .now; return }
        countTask?.cancel()
        countTask = Task { @MainActor in
            for n in [3, 2, 1] {
                counting = n
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            counting = nil
            start = .now
        }
    }

    func pause() {
        countTask?.cancel()
        counting = nil
        base = progress(at: .now)
        start = nil
    }

    func restart() {
        base = 0
        if start != nil { start = .now }
    }

    /// Changing the time mid-scroll keeps the current line in place and only changes the speed from here on.
    func setDuration(_ d: Double) {
        if start != nil { base = progress(at: .now); start = .now }
        duration = max(10, d)
    }

    func close() {
        pause()
        visible = false
        panel?.orderOut(nil)
    }

    func finished() {
        start = nil
        base = 1
    }

    private func show() {
        visible = true
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2) // just below the island, which covers it when open
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.sharingType = .none // left out of screenshots, recordings and screen sharing
            p.contentView = NSHostingView(rootView: PrompterView(prompter: self))
            panel = p
        }
        place()
        panel?.orderFrontRegardless()
    }

    private func place() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = screen.frame, w: CGFloat = 560, h = CGFloat(height)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.maxY - notch.height - h, width: w, height: h), display: true)
    }
}

/// Black bar that continues the notch downwards; text scrolls up past a reading line a third of the way down.
struct PrompterView: View {
    let prompter: PrompterService
    @State private var textHeight: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            TimelineView(.animation(paused: prompter.start == nil)) { ctx in
                let p = prompter.progress(at: ctx.date)
                ZStack(alignment: .top) {
                    Text(prompter.script)
                        .font(.system(size: prompter.fontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineSpacing(prompter.fontSize * 0.25)
                        .frame(width: g.size.width - 48, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { t in Color.clear.preference(key: TextHeight.self, value: t.size.height) })
                        .offset(y: g.size.height / 3 - p * textHeight)
                        .scaleEffect(x: prompter.mirrored ? -1 : 1)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                             .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: p >= 1) { _, done in if done { prompter.finished() } }
            }
            .overlay(alignment: .leading) { // reading line marker
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 9)).foregroundStyle(Prefs.shared.accent)
                    .offset(x: 8, y: g.size.height / 3 + prompter.fontSize * 0.6 - g.size.height / 2)
            }
            .overlay {
                if let n = prompter.counting {
                    Text("\(n)").font(.system(size: 54, weight: .bold).monospacedDigit()).foregroundStyle(Prefs.shared.accent)
                        .contentTransition(.numericText(countsDown: true))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black.opacity(0.7))
                }
            }
        }
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous).fill(.black))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22, style: .continuous))
        .onPreferenceChange(TextHeight.self) { textHeight = $0 }
        .animation(.snappy, value: prompter.counting)
        .environment(\.colorScheme, .dark)
    }
}

private struct TextHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Prompter half of the Captions page in the island.
struct PrompterControls: View {
    let prompter: PrompterService
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            round(prompter.playing ? "pause.fill" : "play.fill", big: true) { prompter.playing ? prompter.pause() : prompter.play() }
            round("backward.end.fill") { prompter.restart() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    round("minus", small: true) { prompter.setDuration(prompter.duration - 15) }
                    Text(TimerService.format(prompter.duration)).font(.system(size: 15, weight: .semibold).monospacedDigit()).frame(minWidth: 44)
                    round("plus", small: true) { prompter.setDuration(prompter.duration + 15) }
                }
                Text("\(prompter.words) words · \(prompter.wordsPerMinute) wpm").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                pill("Edit Script", action: openSettings)
                if prompter.visible { pill("Hide") { prompter.close() } }
            }
        }
    }

    private func round(_ icon: String, big: Bool = false, small: Bool = false, action: @escaping () -> Void) -> some View {
        let d: CGFloat = big ? 48 : small ? 22 : 36
        return Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 18 : small ? 9 : 13, weight: .bold))
                .frame(width: d, height: d)
                .foregroundStyle(big ? .black : .white)
                .background(big ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).frame(height: 24)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
