import AppKit
import AudioToolbox
import CoreAudio
import SwiftUI

/// Thin helpers over the Core Audio property C API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let output = kAudioDevicePropertyScopeOutput

    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(sel, scope), v = value, size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : value
    }
    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: T) -> Bool {
        var addr = address(sel, scope), v = value
        return AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }
    static func settable(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(sel, scope), ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(obj, &addr, &ok) == noErr && ok.boolValue
    }
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Optional<Unmanaged<CFString>>>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }
    static func list(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(sel), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr ? ids : []
    }
    static var defaultOutput: AudioObjectID { CA.get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0)) }
}

// MARK: Volume / brightness HUD and accessory popups

/// Shows volume and brightness in the island. With Accessibility granted it takes over the media keys (so the system HUD
/// stays hidden); without it, it still mirrors every volume change next to the system HUD.
final class AudioService {
    var onHUD: (HUD) -> Void = { _ in }
    var onAccessory: (String) -> Void = { _ in }
    var onArrow: (Int) -> Bool = { _ in false } // -1 left, +1 right; true swallows the key

    private var device = CA.defaultOutput
    private var tap: CFMachPort?
    private static let volume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    init() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { [weak self] _, _ in self?.outputChanged() }
        listen(to: device)
        startKeyTap(prompt: UserDefaults.standard.bool(forKey: "onboarded")) // on first launch onboarding asks, with an explanation
    }

    private func outputChanged() {
        let new = CA.defaultOutput
        guard new != device else { return }
        device = new
        listen(to: new)
        let transport = CA.get(new, kAudioDevicePropertyTransportType, default: UInt32(0))
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
           let name = CA.string(new, kAudioObjectPropertyName) { onAccessory(name) }
    }

    private func listen(to dev: AudioObjectID) {
        for sel in [Self.volume, kAudioDevicePropertyMute] {
            var addr = CA.address(sel, CA.output)
            AudioObjectAddPropertyListenerBlock(dev, &addr, .main) { [weak self] _, _ in
                guard let self, dev == device else { return } // listeners on previous devices stay registered; ignore them
                showVolume()
            }
        }
    }

    private func showVolume() {
        let v = Double(CA.get(device, Self.volume, CA.output, default: Float32(0)))
        let muted = CA.get(device, kAudioDevicePropertyMute, CA.output, default: UInt32(0)) != 0
        let icon = muted || v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        onHUD(HUD(icon: icon, level: muted ? 0 : v))
    }

    // MARK: Media keys

    private func startKeyTap(prompt: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startKeyTap(prompt: false) } // picks up a later grant
            return
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << 14 | 1 << 10), // NX_SYSDEFINED (media/brightness keys) + key down (arrows)
                                callback: { _, type, event, ctx in
            let me = Unmanaged<AudioService>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return me.handleKey(event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true when the key was handled here and must not reach the system (which would draw its own HUD).
    private func handleKey(_ event: CGEvent) -> Bool {
        if event.type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode) // 123 left, 124 right
            guard code == 123 || code == 124, event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty else { return false }
            return onArrow(code == 123 ? -1 : 1)
        }
        guard let e = NSEvent(cgEvent: event), e.type == .systemDefined, e.subtype.rawValue == 8 else { return false }
        let code = (e.data1 & 0xFFFF0000) >> 16, down = (e.data1 & 0xFF00) >> 8 == 0x0A
        switch code {
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP, SOUND_DOWN, MUTE
            guard CA.settable(device, Self.volume, CA.output) else { return false }
            if down { code == 7 ? toggleMute() : stepVolume(code == 0 ? 1 : -1) }
            return true
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP, BRIGHTNESS_DOWN
            guard let get = brightnessGet, let set = brightnessSet else { return false }
            if down {
                var b: Float = 0
                _ = get(CGMainDisplayID(), &b)
                b = min(1, max(0, (b * 16).rounded() / 16 + (code == 2 ? 1 : -1) / 16))
                _ = set(CGMainDisplayID(), b)
                onHUD(HUD(icon: b < 0.5 ? "sun.min.fill" : "sun.max.fill", level: Double(b)))
            }
            return true
        default:
            return false
        }
    }

    private func stepVolume(_ dir: Float32) {
        let v = CA.get(device, Self.volume, CA.output, default: Float32(0.5))
        CA.set(device, kAudioDevicePropertyMute, CA.output, UInt32(0))
        CA.set(device, Self.volume, CA.output, min(1, max(0, (v * 16).rounded() / 16 + dir / 16)))
        showVolume()
    }

    private func toggleMute() {
        let muted = CA.get(device, kAudioDevicePropertyMute, CA.output, default: UInt32(0))
        CA.set(device, kAudioDevicePropertyMute, CA.output, UInt32(muted == 0 ? 1 : 0))
        showVolume()
    }

    // MARK: Sliders (Quick Controls tab)

    var volume: Double {
        get { Double(CA.get(device, Self.volume, CA.output, default: Float32(0))) }
        set {
            CA.set(device, kAudioDevicePropertyMute, CA.output, UInt32(0))
            CA.set(device, Self.volume, CA.output, Float32(newValue))
        }
    }

    var hasBrightness: Bool { brightnessSet != nil }
    var brightness: Double {
        get { var b: Float = 0; _ = brightnessGet?(CGMainDisplayID(), &b); return Double(b) }
        set { _ = brightnessSet?(CGMainDisplayID(), Float(newValue)) }
    }

    // Built-in display brightness lives in the private DisplayServices framework.
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private lazy var brightnessGet = dlsym(displayServices, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
    private lazy var brightnessSet = dlsym(displayServices, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
}

// MARK: Per-app volume mixer

@Observable
final class MixerService {
    struct App: Identifiable { let id: pid_t; let name: String; let icon: NSImage? }
    var apps: [App] = []
    var gains: [pid_t: Float] = [:]
    @ObservationIgnored private var routes: [pid_t: Route] = [:]

    /// Processes currently sending audio to an output.
    func refresh() {
        apps = CA.list(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard CA.get(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 else { return nil }
            let pid = CA.get(obj, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid != getpid() else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return App(id: pid, name: app?.localizedName ?? CA.string(obj, kAudioProcessPropertyBundleID) ?? "PID \(pid)", icon: app?.icon)
        }
    }

    func gain(_ pid: pid_t) -> Float { gains[pid] ?? 1 }

    func setGain(_ g: Float, for pid: pid_t) {
        gains[pid] = g
        if abs(g - 1) < 0.02 { routes[pid] = nil; return } // back at 100%: drop the tap, the app plays natively again
        if let route = routes[pid] { route.gain.pointee = g } else { routes[pid] = Route(pid: pid, gain: g) }
    }
}

/// Mutes one process at the source with a Core Audio process tap and replays its audio, scaled, on the current output.
/// shortcut: built for the output device active when the slider moved; rebuild routes on output change if that matters.
final class Route {
    let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1) // read on the audio thread; a plain Float store is fine here
    private var tap = AudioObjectID(0), aggregate = AudioObjectID(0), proc: AudioDeviceIOProcID?

    init?(pid: pid_t, gain g: Float) {
        gain.pointee = g
        var qualifier = pid, process = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        guard AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &process) == noErr,
              process != 0, let outputUID = CA.string(CA.defaultOutput, kAudioDevicePropertyDeviceUID) else { return nil }

        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { cleanup(); return nil }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynisland Mixer \(pid)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else { cleanup(); return nil }

        let gain = self.gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            for (i, o) in zip(ins, outs) {
                guard let src = i.mData?.assumingMemoryBound(to: Float.self), let dst = o.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(min(i.mDataByteSize, o.mDataByteSize)) / MemoryLayout<Float>.size
                let g = gain.pointee
                for k in 0..<n { dst[k] = src[k] * g }
            }
        }
        guard status == noErr, AudioDeviceStart(aggregate, proc) == noErr else { cleanup(); return nil }
    }

    deinit { cleanup(); gain.deallocate() }

    private func cleanup() {
        if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc); self.proc = nil }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
}

struct MixerSection: View {
    let mixer: MixerService
    var body: some View {
        Group {
            if mixer.apps.isEmpty {
                Placeholder(icon: "speaker.slash", text: "No app is playing audio")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(mixer.apps) { app in
                            HStack(spacing: 10) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 120, alignment: .leading)
                                Slider(value: Binding(get: { Double(mixer.gain(app.id)) }, set: { mixer.setGain(Float($0), for: app.id) }), in: 0...2)
                                    .controlSize(.small)
                                Text("\(Int(mixer.gain(app.id) * 100))%").font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                mixer.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
