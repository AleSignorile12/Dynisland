import AppKit
import SwiftUI

/// Colour picker page: an eyedropper for any pixel on screen, and the last colours picked.
@Observable
final class ColorPickerService {
    /// Most recent first, as "#RRGGBB".
    private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "pickedColors") ?? [] {
        didSet { UserDefaults.standard.set(recent, forKey: "pickedColors") }
    }
    var current: String? { recent.first }
    /// Called with the picked hex after it's copied (the model shows a card).
    @ObservationIgnored var onPick: ((String) -> Void)?

    func pick() {
        NSApp.activate() // the sampler's loupe needs the app in front
        NSColorSampler().show { [weak self] color in
            guard let self, let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
            use(hex)
            onPick?(hex)
        }
    }

    /// Moves the colour to the front and copies `text` (the hex unless another format is asked for).
    func use(_ hex: String, copying text: String? = nil) {
        recent = [hex] + recent.filter { $0 != hex }.prefix(11)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text ?? hex, forType: .string)
    }

    func clear() { recent = [] }
    func remove(_ hex: String) { recent.removeAll { $0 == hex } }

    static func formats(_ hex: String) -> [(name: String, value: String)] {
        let c = NSColor(Color(hex: hex)).usingColorSpace(.sRGB) ?? .black
        let r = Int(c.redComponent * 255 + 0.5), g = Int(c.greenComponent * 255 + 0.5), b = Int(c.blueComponent * 255 + 0.5)
        // HSL from RGB
        let mx = max(c.redComponent, c.greenComponent, c.blueComponent), mn = min(c.redComponent, c.greenComponent, c.blueComponent)
        let l = (mx + mn) / 2, d = mx - mn
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        return [("HEX", hex),
                ("RGB", "rgb(\(r), \(g), \(b))"),
                ("HSL", "hsl(\(Int(c.hueComponent * 360 + 0.5)), \(Int(s * 100 + 0.5))%, \(Int(l * 100 + 0.5))%)")]
    }
}

struct ColorPickerSection: View {
    let colors: ColorPickerService
    @State private var copied: String?

    var body: some View {
        HStack(spacing: 10) {
            // Current colour and its formats
            HStack(spacing: 12) {
                Button { colors.pick() } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colors.current.map { Color(hex: $0) } ?? .white.opacity(0.08))
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15))
                        Image(systemName: "eyedropper").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                    .frame(width: 76, height: 76)
                }
                .buttonStyle(.plain)
                .help("Pick a colour from the screen")

                VStack(alignment: .leading, spacing: 4) {
                    if let hex = colors.current {
                        ForEach(ColorPickerService.formats(hex), id: \.name) { f in
                            Button { colors.use(hex, copying: f.value); flash(f.name) } label: {
                                HStack(spacing: 6) {
                                    Text(f.name).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
                                    Text(f.value).font(.system(size: 12, weight: .medium).monospacedDigit()).lineLimit(1)
                                    Image(systemName: copied == f.name ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9)).foregroundStyle(copied == f.name ? .green : .secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy \(f.value)")
                        }
                    } else {
                        Text("Pick a colour").font(.system(size: 14, weight: .semibold))
                        Text("Click the eyedropper, then click anywhere on screen. The HEX is copied for you.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Recent colours
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if !colors.recent.isEmpty {
                        Button("Clear") { colors.clear() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 6), spacing: 6) {
                    ForEach(0..<12, id: \.self) { i in
                        if i < colors.recent.count {
                            let hex = colors.recent[i]
                            RecentSwatch(hex: hex, copy: { colors.use(hex); flash("HEX") }, remove: { withAnimation(.snappy) { colors.remove(hex) } })
                        } else {
                            Circle().strokeBorder(.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 22, height: 22)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 186)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func flash(_ name: String) {
        copied = name
        Task { try? await Task.sleep(for: .seconds(1.2)); if copied == name { copied = nil } }
    }
}

/// A recent colour: click copies it; hovering shows a small × that removes it.
private struct RecentSwatch: View {
    let hex: String
    let copy: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: copy) {
            Circle().fill(Color(hex: hex)).overlay(Circle().strokeBorder(.white.opacity(0.2)))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help("Copy \(hex)")
        .overlay(alignment: .topTrailing) {
            if hover {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 11, height: 11).background(Circle().fill(.black.opacity(0.85)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Remove \(hex)")
                .offset(x: 4, y: -4)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
    }
}
