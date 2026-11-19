import AppKit
import SwiftUI

/// System-wide Now Playing (any app: Music, Spotify, browsers…) read through the perl bridge in Bridge/NowPlaying.m.
@Observable
final class MediaService {
    var title = ""
    var artist = ""
    var playing = false
    var duration = 0.0
    var artwork: NSImage? { didSet { palette = artwork.map(Self.palette) ?? [.white] } }
    var palette: [Color] = [.white] // the artwork's two most vivid colours, for the live-activity bars
    var lyrics: [(time: Double, line: String)] = []
    var hasTrack: Bool { !title.isEmpty }

    @ObservationIgnored private var elapsedAt = (elapsed: 0.0, date: Date())
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private let bridge = Bundle.main.url(forResource: "libNowPlaying", withExtension: "dylib")
    private static let loader = #"use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); my $s = DynaLoader::dl_find_symbol($l, "np_main") or die "no symbol"; DynaLoader::dl_install_xsub("main::np", $s); np();"#

    enum Command: Int { case togglePlayPause = 2, next = 4, previous = 5 }

    init() {
        assert(Self.parseLRC("[01:02.50] Hi\n[ar: x]").map(\.time) == [62.5]) // LRC parser self-check
        watch()
    }

    func elapsed(at now: Date) -> Double {
        min(duration, elapsedAt.elapsed + (playing ? now.timeIntervalSince(elapsedAt.date) : 0))
    }

    func lyric(at t: Double) -> String? { Prefs.shared.lyrics ? lyrics.last { $0.time <= t }?.line : nil }

    func seek(to t: Double) {
        try? perl(["NP_MODE": "seek", "NP_TIME": String(t)])?.run()
        elapsedAt = (t, Date()) // optimistic; the bridge's next line confirms it
    }

    func send(_ command: Command) {
        try? perl(["NP_MODE": "send", "NP_CMD": String(command.rawValue)])?.run()
        if command == .togglePlayPause { playing.toggle() } // optimistic; the next line from the bridge corrects it
    }

    private func perl(_ env: [String: String]) -> Process? {
        guard let bridge else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, bridge.path]
        p.environment = env
        return p
    }

    private func watch() {
        guard let p = perl(["NP_MODE": "watch"]) else { return }
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in // restart if the bridge dies
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.watch() }
        }
        try? p.run()
        process = p
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(json) }
        }
    }

    private func apply(_ j: [String: Any]) {
        let t = j["title"] as? String ?? "", a = j["artist"] as? String ?? ""
        if t != title || a != artist {
            title = t; artist = a; artwork = nil; lyrics = []
            if !t.isEmpty { fetchLyrics() }
        }
        playing = j["playing"] as? Bool ?? false
        duration = j["duration"] as? Double ?? 0
        elapsedAt = (j["elapsed"] as? Double ?? 0, Date())
        if let b64 = j["artwork"] as? String, let d = Data(base64Encoded: b64) { artwork = NSImage(data: d) }
    }

    /// The two most vivid, clearly different hues in the artwork (like the iPhone island's tinted waveform), brightened
    /// so they read on black. Black-and-white covers give white bars.
    static func palette(of image: NSImage) -> [Color] {
        let side = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return [.white] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        let pixels = (0..<side * side).compactMap { rep.colorAt(x: $0 % side, y: $0 / side)?.usingColorSpace(.sRGB) }
            .filter { $0.saturationComponent > 0.2 && $0.brightnessComponent > 0.2 }
            .sorted { $0.saturationComponent * $0.brightnessComponent > $1.saturationComponent * $1.brightnessComponent }
        guard let first = pixels.first else { return [.white] }
        let hueGap = { (a: NSColor, b: NSColor) in let d = abs(a.hueComponent - b.hueComponent); return min(d, 1 - d) }
        let second = pixels.first { hueGap($0, first) > 0.08 } ?? first
        return [first, second].map {
            Color(hue: $0.hueComponent, saturation: min(1, $0.saturationComponent * 1.1), brightness: max(0.8, $0.brightnessComponent))
        }
    }

    /// Synced lyrics from lrclib.net (free, no key). Sends the track title and artist to that service.
    private func fetchLyrics() {
        guard Prefs.shared.lyrics else { return } // off: nothing is sent to lrclib.net
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        let track = title
        Task { @MainActor in
            guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
                  let synced = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["syncedLyrics"] as? String,
                  track == title else { return }
            lyrics = Self.parseLRC(synced)
        }
    }

    /// "[mm:ss.xx] line" rows; tag rows like "[ar: name]" are skipped.
    static func parseLRC(_ text: String) -> [(time: Double, line: String)] {
        text.split(separator: "\n").compactMap { row in
            guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else { return nil }
            let stamp = row[row.index(after: row.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Double(stamp[0]), let s = Double(stamp[1]) else { return nil }
            return (m * 60 + s, row[row.index(after: close)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

// MARK: Views

/// Thin system-volume slider under the play controls. Re-reads the volume every second so the keys stay in sync.
struct MiniVolume: View {
    let audio: AudioService
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let v = dragging ?? audio.volume
            HStack(spacing: 6) {
                Image(systemName: v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .leading)
                Scrubber(fraction: v) { f, done in
                    dragging = done ? nil : f
                    audio.volume = f
                }
            }
        }
    }
}

/// Song progress bar: click or drag anywhere to jump. It thickens while hovered or dragged, like the system player.
struct Scrubber: View {
    let fraction: Double
    let onChange: (_ fraction: Double, _ done: Bool) -> Void
    @State private var active = false

    var body: some View {
        GeometryReader { g in
            let clamp = { (x: CGFloat) in min(1, max(0, Double(x / g.size.width))) }
            Capsule().fill(.white.opacity(0.2))
                .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: g.size.width * min(1, max(0, fraction))) }
                .frame(height: active ? 7 : 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { active = true; onChange(clamp($0.location.x), false) }
                    .onEnded { active = false; onChange(clamp($0.location.x), true) })
                .onHover { active = $0 }
        }
        .frame(height: 12)
        .animation(.snappy(duration: 0.2), value: active)
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.1)) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Animated bars like the iPhone island's, tinted with the album's colours; decorative, not driven by the real audio signal.
struct Equalizer: View {
    let playing: Bool
    var colors: [Color] = [.white]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().frame(width: 3, height: playing ? 4 + 10 * abs(sin(t * (2.6 + Double(i) * 0.7) + Double(i))) : 3)
                }
            }
            .frame(height: 14)
        }
        .foregroundStyle(LinearGradient(colors: colors.count > 1 ? colors : colors + colors, startPoint: .leading, endPoint: .trailing))
        .animation(.easeInOut(duration: 0.6), value: colors)
    }
}

struct MediaSection: View {
    let media: MediaService
    let audio: AudioService
    @State private var scrub: Double? // position under the finger while dragging the progress bar
    var body: some View {
        if !media.hasTrack {
            Placeholder(icon: "music.note", text: "Nothing playing")
        } else {
            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    Artwork(image: media.artwork, size: 56, radius: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(media.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            let line = media.lyric(at: scrub ?? media.elapsed(at: ctx.date)) ?? ""
                            Text(line.isEmpty ? " " : line).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1).id(line).transition(.blurReplace)
                                .animation(.smooth, value: line)
                        }
                    }
                    Spacer(minLength: 8)
                    // Level with the title, in the same right-hand column as the volume slider below.
                    HStack(spacing: 10) {
                        control("backward.fill", 16) { media.send(.previous) }
                        control(media.playing ? "pause.fill" : "play.fill", 20) { media.send(.togglePlayPause) }
                        control("forward.fill", 16) { media.send(.next) }
                    }
                    .frame(width: Self.volumeWidth)
                }
                // Song bar and volume on one row.
                HStack(spacing: 18) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let t = scrub ?? media.elapsed(at: ctx.date)
                        HStack(spacing: 8) {
                            time(t)
                            Scrubber(fraction: media.duration > 0 ? t / media.duration : 0) { f, done in
                                guard media.duration > 0 else { return }
                                scrub = f * media.duration
                                if done, let target = scrub { media.seek(to: target); scrub = nil }
                            }
                            time(-(media.duration - t))
                        }
                    }
                    MiniVolume(audio: audio).frame(width: Self.volumeWidth)
                }
            }
        }
    }

    private static let volumeWidth: CGFloat = 96

    /// "1:23" elapsed on the left, "-2:10" remaining on the right, like the system player.
    private func time(_ seconds: Double) -> some View {
        Text((seconds < 0 ? "-" : "") + Duration.seconds(abs(seconds)).formatted(.time(pattern: .minuteSecond)))
            .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: 32, alignment: seconds < 0 ? .leading : .trailing)
    }

    private func control(_ icon: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).frame(width: 25, height: 24).contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}
