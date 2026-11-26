import CoreAudio
import SwiftUI

/// System-wide 10-band equalizer. Like the volume mixer it uses a Core Audio process tap: every app's audio (except
/// Dynisland's own) is muted at the source, run through ten peaking filters and played on the current output.
/// No audio driver to install. Needs System Audio Recording.
@Observable
final class EqualizerService {
    static let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let presets: [(name: String, gains: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Bass Reducer", [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Vocal", [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
        ("Podcast", [-4, -2, 0, 2, 4, 4, 3, 1, -1, -3]),
        ("Loudness", [5, 4, 1, 0, -1, 0, 1, 3, 4, 4]),
        ("Acoustic", [4, 3, 2, 1, 1, 1, 2, 3, 3, 2]),
        ("Electronic", [4, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        ("Rock", [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
    ]

    var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "eqOn"); apply() } }
    var gains: [Double] { didSet { UserDefaults.standard.set(gains, forKey: "eqGains"); route?.update(gains) } }
    var failed = false // the tap couldn't be made: usually System Audio Recording isn't allowed
    var preset: String? { Self.presets.first { $0.gains == gains }?.name }

    @ObservationIgnored private var route: EQRoute?

    init() {
        let d = UserDefaults.standard
        on = d.bool(forKey: "eqOn")
        let saved = d.array(forKey: "eqGains") as? [Double] ?? []
        gains = saved.count == Self.bands.count ? saved : Array(repeating: 0, count: Self.bands.count)
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in // rebuild for the new speakers/headphones
            guard let self, on else { return }
            route = nil
            apply()
        }
        apply()
    }

    func set(_ band: Int, _ db: Double) { gains[band] = (db * 2).rounded() / 2 } // half-dB steps
    func use(_ p: [Double]) { gains = p }

    private func apply() {
        if on {
            if route == nil { route = EQRoute(gains: gains) }
            failed = route == nil
        } else {
            route = nil
            failed = false
        }
    }
}

/// The tap, an aggregate device on the current output, and the filter chain running on the audio thread.
final class EQRoute {
    private static let maxChannels = 16
    private let coeffs = UnsafeMutablePointer<Float>.allocate(capacity: 10 * 5 + 1) // b0 b1 b2 a1 a2 per band, then preamp
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: maxChannels * 10 * 2)
    private var tap = AudioObjectID(0), aggregate = AudioObjectID(0), proc: AudioDeviceIOProcID?
    private var rate = 48_000.0

    init?(gains: [Double]) {
        state.initialize(repeating: 0, count: Self.maxChannels * 20)
        coeffs.initialize(repeating: 0, count: 51)
        guard let outputUID = CA.string(CA.defaultOutput, kAudioDevicePropertyDeviceUID) else { cleanup(); return nil }
        let own = CA.processObject(getpid())
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == 0 ? [] : [own]) // our own sound is the EQ's output
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { cleanup(); return nil }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynisland Equalizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else { cleanup(); return nil }
        rate = CA.get(aggregate, kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))
        update(gains)

        let coeffs = coeffs, state = state, maxCh = Self.maxChannels
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            let pre = coeffs[50]
            for (b, (i, o)) in zip(ins, outs).enumerated() {
                guard let src = i.mData?.assumingMemoryBound(to: Float.self), let dst = o.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(min(i.mDataByteSize, o.mDataByteSize)) / MemoryLayout<Float>.size
                let chans = max(1, Int(i.mNumberChannels))
                for k in 0..<n {
                    let ch = min(b * chans + k % chans, maxCh - 1)
                    var x = src[k] * pre
                    for band in 0..<10 { // transposed direct form II
                        let c = coeffs + band * 5, z = state + (ch * 10 + band) * 2
                        let y = c[0] * x + z[0]
                        z[0] = c[1] * x - c[3] * y + z[1]
                        z[1] = c[2] * x - c[4] * y
                        x = y
                    }
                    dst[k] = x
                }
            }
        }
        guard status == noErr, AudioDeviceStart(aggregate, proc) == noErr else { cleanup(); return nil }
    }

    /// RBJ cookbook peaking filters, Q 1.4. Written from the main thread while the audio thread reads: a buffer may
    /// mix old and new coefficients for one block, which is inaudible.
    func update(_ gains: [Double]) {
        for (band, (f, g)) in zip(EqualizerService.bands, gains).enumerated() {
            let a = pow(10, g / 40), w = 2 * Double.pi * min(f, rate * 0.45) / rate, alpha = sin(w) / (2 * 1.4)
            let a0 = 1 + alpha / a
            let c = coeffs + band * 5
            c[0] = Float((1 + alpha * a) / a0)
            c[1] = Float(-2 * cos(w) / a0)
            c[2] = Float((1 - alpha * a) / a0)
            c[3] = Float(-2 * cos(w) / a0)
            c[4] = Float((1 - alpha / a) / a0)
        }
        coeffs[50] = Float(pow(10, -max(0, gains.max() ?? 0) / 20)) // lower the input by the biggest boost so it can't clip
    }

    deinit { cleanup(); coeffs.deallocate(); state.deallocate() }

    private func cleanup() {
        if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc); self.proc = nil }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
}

struct EqualizerSection: View {
    let eq: EqualizerService

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { eq.on }, set: { eq.on = $0 })) {
                    Text("Equalizer").font(.system(size: 12, weight: .semibold))
                }
                .toggleStyle(.switch).controlSize(.mini)
                Menu {
                    ForEach(EqualizerService.presets, id: \.name) { p in Button(p.name) { eq.use(p.gains) } }
                } label: {
                    Text(eq.preset ?? "Custom").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 0)
                Text(eq.failed ? "Allow System Audio Recording in System Settings" : eq.on ? "All apps' sound" : "Off: sound plays untouched")
                    .font(.system(size: 9)).foregroundStyle(eq.failed ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 128, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 0) {
                ForEach(EqualizerService.bands.indices, id: \.self) { i in
                    BandSlider(db: eq.gains[i], label: label(EqualizerService.bands[i]), active: eq.on) { eq.set(i, $0) }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func label(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))K" : "\(Int(f))" }
}

/// One vertical band: drag to set −12…+12 dB, double-click for 0.
private struct BandSlider: View {
    let db: Double
    let label: String
    let active: Bool
    let set: (Double) -> Void
    private let range = 12.0

    var body: some View {
        VStack(spacing: 4) {
            Text(db == 0 ? "0" : String(format: "%+.0f", db)).font(.system(size: 8, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { g in
                let h = g.size.height, y = h / 2 - CGFloat(db / range) * h / 2
                ZStack(alignment: .top) {
                    Capsule().fill(.white.opacity(0.12)).frame(width: 4).frame(maxWidth: .infinity)
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 10, height: 1).offset(y: h / 2) // 0 dB line
                    Capsule().fill(active ? Prefs.shared.accent : .white.opacity(0.4))
                        .frame(width: 4, height: abs(y - h / 2))
                        .offset(y: min(y, h / 2))
                    Circle().fill(.white).frame(width: 12, height: 12).shadow(radius: 1).offset(y: y - 6)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    set(max(-range, min(range, Double((h / 2 - v.location.y) / (h / 2)) * range)))
                })
                .onTapGesture(count: 2) { set(0) }
            }
            Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}
