import AppKit
import AVFoundation
import EventKit
import IOKit.pwr_mgt
import SwiftUI

// MARK: Calendar

@Observable
final class CalendarService {
    var events: [EKEvent] = [] // the whole current month
    var authorized = false
    @ObservationIgnored private let store = EKEventStore()

    /// Asks for access the first time the section is opened, then loads this month's events.
    func load() async {
        if !authorized { authorized = (try? await store.requestFullAccessToEvents()) ?? false }
        guard authorized, let month = Calendar.current.dateInterval(of: .month, for: .now) else { return }
        let predicate = store.predicateForEvents(withStart: month.start, end: month.end.addingTimeInterval(86400), calendars: nil) // +1 day: "next day" of the 31st
        events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func events(on day: Date) -> [EKEvent] {
        guard let range = Calendar.current.dateInterval(of: .day, for: day) else { return [] }
        return events.filter { $0.startDate < range.end && $0.endDate > range.start } // includes multi-day events
    }
}

struct CalendarSection: View {
    let calendar: CalendarService
    @State private var day = Calendar.current.startOfDay(for: .now)

    var body: some View {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        HStack(alignment: .top, spacing: 14) {
            MonthGrid(selected: $day, hasEvents: { !calendar.events(on: $0).isEmpty })
            if !calendar.authorized {
                Placeholder(icon: "calendar.badge.exclamationmark", text: "Allow Calendar access in System Settings")
            } else {
                DayColumn(day: day, events: calendar.events(on: day))
                DayColumn(day: next, events: calendar.events(on: next)).opacity(0.75)
            }
        }
        .animation(.snappy, value: day)
        .task { await calendar.load() }
    }
}

/// One day's events: a countdown for today ("in 12 min", "Now"), the time range otherwise.
struct DayColumn: View {
    let day: Date
    let events: [EKEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            if events.isEmpty {
                Text("No events").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(events, id: \.eventIdentifier) { e in
                            HStack(spacing: 8) {
                                Capsule().fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title ?? "Event").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(when(e)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(day)
        .transition(.blurReplace)
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func when(_ e: EKEvent) -> String {
        if e.isAllDay { return "All day" }
        let range = "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))"
        guard Calendar.current.isDateInToday(day), e.endDate > .now else { return range }
        if e.startDate <= .now { return "Now · until \(e.endDate.formatted(date: .omitted, time: .shortened))" }
        let mins = Int(e.startDate.timeIntervalSinceNow / 60)
        return mins < 60 ? "in \(mins) min · \(range)" : range
    }
}

/// This month; click a day to see its events. Days with events get a dot, today is red.
struct MonthGrid: View {
    @Binding var selected: Date
    let hasEvents: (Date) -> Bool

    var body: some View {
        let cal = Calendar.current, now = Date()
        let first = cal.dateInterval(of: .month, for: now)!.start
        let offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let days = cal.range(of: .day, in: .month, for: now)!.count
        let symbols = cal.veryShortWeekdaySymbols
        let header = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        VStack(alignment: .leading, spacing: 3) {
            Text(now.formatted(.dateTime.month(.wide))).font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 1), count: 7), spacing: 1) {
                ForEach(Array(header.enumerated()), id: \.offset) { Text($0.element).foregroundStyle(.secondary) }
                ForEach(0..<(offset + days), id: \.self) { i in
                    if i < offset {
                        Color.clear.frame(width: 17, height: 13)
                    } else {
                        let date = cal.date(byAdding: .day, value: i - offset, to: first)!
                        dayCell(date, today: cal.isDateInToday(date), on: cal.isDate(date, inSameDayAs: selected))
                    }
                }
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
        }
        .frame(width: 150)
    }

    private func dayCell(_ date: Date, today: Bool, on: Bool) -> some View {
        Button { selected = date } label: {
            Text("\(Calendar.current.component(.day, from: date))")
                .foregroundStyle(today ? .white : on ? .black : .primary)
                .frame(width: 17, height: 13)
                .background {
                    if today { Circle().fill(.red).frame(width: 15, height: 15) }
                    else if on { Circle().fill(.white).frame(width: 15, height: 15) }
                }
                .overlay(alignment: .bottom) {
                    if hasEvents(date) && !on && !today { Circle().fill(.secondary).frame(width: 2.5, height: 2.5).offset(y: 2) }
                }
                .overlay { if on && today { Circle().stroke(.white, lineWidth: 1.2).frame(width: 17, height: 17) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Timer

@Observable
final class TimerService {
    var end: Date?                  // set while counting down
    var pausedLeft: TimeInterval?   // set while paused
    var total: TimeInterval = 0
    var pomodoro: Pomodoro?         // set while a focus/break cycle runs
    var round = 1                   // focus session number; every 4th break is long
    var onDone: (_ title: String, _ subtitle: String) -> Void = { _, _ in }

    enum Pomodoro { case focus, rest }
    static var focusLength: TimeInterval { Double(Prefs.shared.focusMinutes) * 60 }
    private var breakLength: TimeInterval { Double(round % 4 == 0 ? Prefs.shared.longBreakMinutes : Prefs.shared.shortBreakMinutes) * 60 }
    @ObservationIgnored private var task: Task<Void, Never>?

    var isActive: Bool { end != nil || pausedLeft != nil }
    var isPaused: Bool { pausedLeft != nil }

    func start(seconds: TimeInterval) {
        total = seconds
        run(for: seconds)
    }

    func startPomodoro() {
        pomodoro = .focus
        round = 1
        start(seconds: Self.focusLength)
    }

    var phaseName: String? {
        switch pomodoro {
        case .focus: "Focus \(round)/4"
        case .rest: round % 4 == 0 ? "Long break" : "Break"
        case nil: nil
        }
    }

    func pause() {
        guard let end else { return }
        task?.cancel()
        pausedLeft = max(0, end.timeIntervalSinceNow)
        self.end = nil
    }

    func resume() {
        guard let left = pausedLeft else { return }
        run(for: left)
    }

    func stop() { task?.cancel(); end = nil; pausedLeft = nil; pomodoro = nil }

    func remaining(at now: Date) -> TimeInterval { pausedLeft ?? max(0, (end ?? now).timeIntervalSince(now)) }

    private func run(for seconds: TimeInterval) {
        pausedLeft = nil
        end = .now + seconds
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            end = nil
            if Prefs.shared.timerSound { NSSound(named: "Glass")?.play() }
            switch pomodoro { // a cycle rolls straight into its next phase
            case .focus:
                pomodoro = .rest
                start(seconds: breakLength)
                onDone("Time for a break", "\(Int(breakLength / 60)) minutes")
            case .rest:
                round = round % 4 + 1
                pomodoro = .focus
                start(seconds: Self.focusLength)
                onDone("Back to focus", "Session \(round) of 4")
            case nil:
                onDone("Timer done", "")
            }
        }
    }

    static func format(_ t: TimeInterval) -> String {
        Duration.seconds(t.rounded(.up)).formatted(.time(pattern: t >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

struct TimerSection: View {
    let timer: TimerService
    @State private var custom = false
    @State private var minutes = 20
    @State private var seconds = 0

    var body: some View {
        if timer.isActive {
            running
        } else if custom {
            customPicker
        } else {
            presets
        }
    }

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = timer.remaining(at: ctx.date)
            HStack(spacing: 20) {
                ProgressRing(fraction: timer.total > 0 ? left / timer.total : 0, tint: Prefs.shared.accent, lineWidth: 6).frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 0) {
                    if let phase = timer.phaseName {
                        Text(phase).font(.system(size: 12, weight: .semibold)).foregroundStyle(timer.pomodoro == .rest ? .green : .secondary)
                    }
                    Text(TimerService.format(left)).font(.system(size: 40, weight: .semibold).monospacedDigit())
                        .foregroundStyle(timer.isPaused ? .secondary : timer.pomodoro == .rest ? .green : Prefs.shared.accent)
                }
                Spacer()
                round(timer.isPaused ? "play.fill" : "pause.fill", tint: Prefs.shared.accent) { timer.isPaused ? timer.resume() : timer.pause() }
                round("xmark", tint: .white) { timer.stop() }
            }
            .padding(.horizontal, 8)
        }
    }

    private var presets: some View {
        VStack(spacing: 10) {
            Text("Start a timer").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([1, 5, 10, 15, 25], id: \.self) { m in
                    chip("\(m)m") { timer.start(seconds: Double(m) * 60) }
                }
                chip("Custom") { custom = true }
                chip("🍅 Pomodoro") { timer.startPomodoro() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hours aren't needed often; minutes go up to 600 (10 h).
    private var customPicker: some View {
        HStack(spacing: 18) {
            field("min", value: $minutes, range: 0...600)
            Text(":").font(.system(size: 30, weight: .semibold)).foregroundStyle(.secondary)
            field("sec", value: $seconds, range: 0...59)
            Spacer()
            round("xmark", tint: .white) { custom = false }
            round("play.fill", tint: Prefs.shared.accent) {
                let total = minutes * 60 + seconds
                guard total > 0 else { return }
                custom = false
                timer.start(seconds: Double(total))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }

    private func field(_ unit: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: value.wrappedValue) { _, v in value.wrappedValue = min(max(v, range.lowerBound), range.upperBound) }
                Stepper("", value: value, in: range).labelsHidden()
            }
            Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).frame(minWidth: 52).padding(.horizontal, 4).frame(height: 40)
                .background(Prefs.shared.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Prefs.shared.accent)
        }
        .buttonStyle(.plain)
    }

    private func round(_ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundStyle(tint)
                .frame(width: 44, height: 44).background(tint.opacity(0.15), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Quick controls

@Observable
final class ControlsService {
    var keepAwake = false {
        didSet {
            guard keepAwake != oldValue else { return }
            if keepAwake {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Dynisland Keep Awake" as CFString, &assertion)
            } else {
                IOPMAssertionRelease(assertion)
            }
        }
    }
    var darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    @ObservationIgnored private var assertion: IOPMAssertionID = 0

    func toggleDarkMode() {
        let script = NSAppleScript(source: "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if error == nil { darkMode.toggle() }
    }

    func screenshot() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"), configuration: .init())
    }

    func sleepDisplay() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
    }
}

struct ControlsSection: View {
    let controls: ControlsService
    let audio: AudioService
    @State private var volume = 0.0
    @State private var brightness = 0.0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 22) {
                toggle("cup.and.saucer.fill", "Keep Awake", on: controls.keepAwake) { controls.keepAwake.toggle() }
                toggle("circle.lefthalf.filled", "Dark Mode", on: controls.darkMode) { controls.toggleDarkMode() }
                toggle("camera.viewfinder", "Screenshot", on: false) { controls.screenshot() }
                toggle("moon.zzz.fill", "Sleep Display", on: false) { controls.sleepDisplay() }
            }
            HStack(spacing: 16) {
                if audio.hasBrightness {
                    ControlSlider(value: $brightness, low: "sun.min.fill", high: "sun.max.fill") { audio.brightness = $0 }
                }
                ControlSlider(value: $volume, low: "speaker.fill", high: "speaker.wave.3.fill") { audio.volume = $0 }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { volume = audio.volume; brightness = audio.brightness }
    }

    private func toggle(_ icon: String, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(width: 50, height: 50)
                    .foregroundStyle(on ? .black : .white)
                    .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12)), in: Circle())
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: on)
    }
}

/// Control Center–style capsule slider: drag or click anywhere on it.
struct ControlSlider: View {
    @Binding var value: Double
    let low: String
    let high: String
    let set: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(.white).frame(width: max(28, g.size.width * value))
                HStack {
                    Image(systemName: low).foregroundStyle(.black.opacity(value > 0.08 ? 0.6 : 0)).padding(.leading, 9)
                    Spacer()
                    Image(systemName: high).foregroundStyle(.white.opacity(value < 0.9 ? 0.6 : 0)).padding(.trailing, 9)
                }
                .font(.system(size: 10, weight: .semibold))
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = min(1, max(0, drag.location.x / g.size.width))
                set(value)
            })
        }
        .frame(height: 26)
        .animation(.snappy(duration: 0.15), value: value)
    }
}

// MARK: System stats

enum SystemStats {
    static func cpuTicks() -> (busy: Double, total: Double) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        let t = info.cpu_ticks // user, system, idle, nice
        let busy = Double(t.0) + Double(t.1) + Double(t.3)
        return (busy, busy + Double(t.2))
    }

    static func memory() -> (used: Double, total: Double) {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let used = (Double(s.active_count) + Double(s.wire_count) + Double(s.compressor_page_count)) * Double(vm_kernel_page_size)
        return (used, Double(ProcessInfo.processInfo.physicalMemory))
    }
}

struct SystemSection: View {
    let network: NetworkService
    @State private var cpu = 0.0
    @State private var memory = (used: 0.0, total: 1.0)
    @State private var battery = IslandModel.readPower()
    @State private var thermal = ProcessInfo.processInfo.thermalState

    var body: some View {
        HStack(spacing: 20) {
            gauge(cpu, "\(Int(cpu * 100))%", "CPU", .blue)
            gauge(memory.used / memory.total, String(format: "%.1f GB", memory.used / 1_073_741_824), "Memory", .purple)
            gauge(Double(battery.percent) / 100, "\(battery.percent)%", battery.onAC ? "Battery ⚡︎" : "Battery", .green)
            gauge(thermalLevel, thermalName, "Thermal", thermalLevel > 0.5 ? .orange : .mint)
            Divider().frame(height: 70).overlay(.white.opacity(0.15))
            SpeedTest(network: network)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            var last = SystemStats.cpuTicks()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                let now = SystemStats.cpuTicks()
                if now.total > last.total { cpu = (now.busy - last.busy) / (now.total - last.total) }
                last = now
                memory = SystemStats.memory()
                battery = IslandModel.readPower()
                thermal = ProcessInfo.processInfo.thermalState
            }
        }
    }

    // Apple Silicon temperatures need private SMC/HID sensor APIs; the public thermal state is the honest proxy.
    private var thermalLevel: Double { Double(thermal.rawValue + 1) / 4 }
    private var thermalName: String { ["Cool", "Warm", "Hot", "Critical"][thermal.rawValue] }

    private func gauge(_ value: Double, _ text: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                ProgressRing(fraction: value, tint: tint, lineWidth: 5)
                Text(text).font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .frame(width: 62, height: 62)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Camera mirror

struct MirrorSection: View {
    let audio: AudioService
    @State private var granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @AppStorage("mirrorFlip") private var flip = true
    @State private var light = false
    @State private var savedBrightness: Double?

    var body: some View {
        Group {
            if granted {
                ZStack { // the camera sits dead centre, right under the real camera in the notch
                    if light { // the light fills the whole open island, not just a frame
                        RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white)
                            .shadow(color: .white, radius: 30)
                            .padding(-10)
                            .transition(.opacity)
                    }
                    CameraPreview(mirrored: flip).allowsHitTesting(false).frame(width: 200, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    VStack(spacing: 10) {
                        button(light ? "lightbulb.fill" : "lightbulb", "Light", on: light) { setLight(!light) }
                        button("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip", on: !flip) { flip.toggle() }
                    }
                    .padding(.trailing, 6)
                }
                .animation(.snappy, value: light)
            } else {
                Placeholder(icon: "video.slash", text: "Allow camera access to use the mirror")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { if !granted { granted = await AVCaptureDevice.requestAccess(for: .video) } }
        .onDisappear { setLight(false) }
    }

    /// The light also turns the display up to full, and puts your brightness back after.
    private func setLight(_ on: Bool) {
        guard on != light else { return }
        light = on
        if on, audio.hasBrightness {
            savedBrightness = audio.brightness
            audio.brightness = 1
        } else if let b = savedBrightness {
            audio.brightness = b
            savedBrightness = nil
        }
    }

    private func button(_ icon: String, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).frame(width: 16)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(width: 84, height: 32)
            .foregroundStyle(on ? (light ? .white : .black) : (light ? .black : .white))
            .background(on ? AnyShapeStyle(light ? .black : .white) : AnyShapeStyle((light ? Color.black : .white).opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Live, mirrored camera preview; the session runs only while the view is on screen.
struct CameraPreview: NSViewRepresentable {
    var mirrored = true
    final class Coordinator { let session = AVCaptureSession() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let session = context.coordinator.session
        if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirrored
        }
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let c = (view.layer as? AVCaptureVideoPreviewLayer)?.connection, c.isVideoMirroringSupported { c.isVideoMirrored = mirrored }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }
}
