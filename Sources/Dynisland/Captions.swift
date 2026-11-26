import AppKit
import AVFoundation
import CoreAudio
import Observation
import Speech
import SwiftUI

/// Live captions for whatever the Mac is playing: a Core Audio tap on all system audio (sound keeps playing) feeds
/// on-device speech recognition; the text shows in a bar at the bottom of the screen that screen sharing doesn't capture.
@Observable
final class CaptionsService {
    static let languages = [("en-US", "English"), ("it-IT", "Italiano"), ("es-ES", "Español"), ("fr-FR", "Français"), ("de-DE", "Deutsch")]

    var on = false
    var text = ""        // current sentence, updated as words arrive
    var previous = ""    // last finished sentence, kept as the upper line
    var problem: String?
    var language = UserDefaults.standard.string(forKey: "captionsLanguage") ?? (Locale.current.language.languageCode?.identifier == "it" ? "it-IT" : "en-US") {
        didSet { UserDefaults.standard.set(language, forKey: "captionsLanguage"); if on { stop(); start() } }
    }

    @ObservationIgnored private var tap = AudioObjectID(0)
    @ObservationIgnored private var aggregate = AudioObjectID(0)
    @ObservationIgnored private var proc: AudioDeviceIOProcID?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest? // swapped on main, read on the audio thread
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var autoStarted = false   // started by the watcher, so the watcher may stop it
    @ObservationIgnored private var userStopped = false   // turned off by hand: don't restart until the audio stops
    @ObservationIgnored private var quietSince: Date?

    init() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.watchAudio() }
    }

    func toggle() {
        if on { userStopped = true; autoStarted = false; stop() } else { start() }
    }

    /// "Start automatically": captions come on when any app plays sound and go off after 15 s of silence.
    private func watchAudio() {
        guard Prefs.shared.captionsAuto else { return }
        let playing = CA.list(CA.system, kAudioHardwarePropertyProcessObjectList).contains { obj in
            CA.get(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 && CA.get(obj, kAudioProcessPropertyPID, default: pid_t(-1)) != getpid()
        }
        if playing {
            quietSince = nil
            if !on, !starting, !userStopped, problem == nil { autoStarted = true; start() }
        } else {
            userStopped = false
            guard on, autoStarted else { return }
            if quietSince == nil { quietSince = .now }
            if let q = quietSince, -q.timeIntervalSinceNow > 15 { autoStarted = false; stop() }
        }
    }

    func start() {
        problem = nil
        starting = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                defer { self.starting = false }
                guard status == .authorized else { self.problem = "Allow Speech Recognition in System Settings"; return }
                guard let r = SFSpeechRecognizer(locale: Locale(identifier: self.language)), r.isAvailable else {
                    self.problem = "Language not available"; return
                }
                self.recognizer = r
                guard self.startTap() else { self.problem = "Allow System Audio Recording in System Settings"; self.stopTap(); return }
                self.on = true
                self.newRequest()
                self.showPanel()
            }
        }
    }

    func stop() {
        on = false
        stopTap()
        task?.cancel()
        task = nil
        setRequest(nil)
        text = ""
        previous = ""
        panel?.orderOut(nil)
    }

    // MARK: Recognition

    /// One request lasts until the recognizer finalises it (pause in speech, or about a minute); then a fresh one starts.
    private func newRequest() {
        guard on, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true } // audio never leaves the Mac
        setRequest(req)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.on, self.request === req else { return }
                if let result { self.text = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true {
                    if !self.text.isEmpty { self.previous = self.text }
                    self.text = ""
                    req.endAudio()
                    self.newRequest()
                }
            }
        }
    }

    private func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }

    // MARK: System audio tap

    private func startTap() -> Bool {
        guard let outputUID = CA.string(CA.defaultOutput, kAudioDevicePropertyDeviceUID) else { return false }
        let own = CA.processObject(getpid()) // skip our own output (the equalizer's replay), or captions would hear everything twice
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == 0 ? [] : [own])
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return false }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = CA.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { return false }
        format = fmt

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Dynisland Captions",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate) == noErr else { return false }

        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [weak self] _, input, _, _, _ in
            guard let self, let format = self.format else { return }
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = src.first, format.streamDescription.pointee.mBytesPerFrame > 0 else { return }
            let frames = first.mDataByteSize / format.streamDescription.pointee.mBytesPerFrame
            // shortcut: allocates a buffer per callback on the audio thread; fine for captions, not for playback.
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buf.frameLength = frames
            for (s, d) in zip(src, UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)) {
                if let sp = s.mData, let dp = d.mData { memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize))) }
            }
            self.lock.lock()
            let req = self.request
            self.lock.unlock()
            req?.append(buf)
        }
        return status == noErr && AudioDeviceStart(aggregate, proc) == noErr
    }

    private func stopTap() {
        if let proc { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc); self.proc = nil }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    // MARK: Caption bar

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.sharingType = .none // left out of screenshots, recordings and screen sharing
            p.contentView = NSHostingView(rootView: CaptionBar(captions: self))
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame, w = min(820, f.width - 80), h: CGFloat = 110
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 40, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

/// Two lines, newest at the bottom, on a dark rounded backdrop like the system's own captions.
struct CaptionBar: View {
    let captions: CaptionsService
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if !(captions.previous + captions.text).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !captions.previous.isEmpty { line(captions.previous).foregroundStyle(.white.opacity(0.6)) }
                    if !captions.text.isEmpty { line(captions.text).foregroundStyle(.white) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: captions.previous.isEmpty && captions.text.isEmpty)
    }

    /// Long sentences keep only their tail so the bar never grows past two lines.
    private func line(_ s: String) -> some View {
        Text(s.count > 110 ? "…" + s.suffix(110) : s).font(.system(size: Prefs.shared.captionSize, weight: .medium)).lineLimit(1).truncationMode(.head)
    }
}

/// The Captions page: live captions, or the prompter (a script that scrolls under the notch). Both stay out of screen sharing.
struct CaptionsSection: View {
    let captions: CaptionsService
    let prompter: PrompterService
    let openSettings: () -> Void
    @AppStorage("captionsPageMode") private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text("Captions").tag(0)
                Text("Prompter").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190).controlSize(.small)
            if mode == 0 { captionsControls } else { PrompterControls(prompter: prompter, openSettings: openSettings) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var captionsControls: some View {
        HStack(spacing: 16) {
            Button { captions.toggle() } label: {
                Image(systemName: captions.on ? "captions.bubble.fill" : "captions.bubble").font(.system(size: 18, weight: .medium))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(captions.on ? .black : .white)
                    .background(captions.on ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Circle())
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(captions.on ? "Captions on" : "Live Captions").font(.system(size: 13, weight: .semibold))
                    Menu {
                        ForEach(CaptionsService.languages, id: \.0) { code, name in Button(name) { captions.language = code } }
                    } label: {
                        Text(CaptionsService.languages.first { $0.0 == captions.language }?.1 ?? captions.language).font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Toggle("Auto", isOn: Binding(get: { Prefs.shared.captionsAuto }, set: { Prefs.shared.captionsAuto = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                        .help("Start captions by themselves when something plays")
                }
                Text(captions.problem ?? (captions.on ? (captions.text.isEmpty ? (captions.previous.isEmpty ? "Listening…" : captions.previous) : captions.text)
                                          : "Subtitles for any audio, hidden from screen sharing"))
                    .font(.system(size: 11)).foregroundStyle(captions.problem == nil ? .secondary : Color.red)
                    .lineLimit(2).truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
    }
}
