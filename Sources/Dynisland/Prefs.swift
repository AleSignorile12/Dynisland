import AppKit
import Observation
import SwiftUI

/// Every user setting, saved to UserDefaults the moment it changes. Views read Prefs.shared directly.
@Observable
final class Prefs {
    static let shared = Prefs()
    static let changed = Notification.Name("DynislandPrefsChanged")

    enum Size: String, CaseIterable, Identifiable {
        case small, regular, large
        var id: Self { self }
        var width: CGFloat { switch self { case .small: 520; case .regular: 580; case .large: 640 } }
    }

    struct Preset: Identifiable {
        let name: String
        let island: String
        let accent: String
        var id: String { name }
    }
    static let presets = [
        Preset(name: "Classic", island: "#000000", accent: "#FF9F0A"),
        Preset(name: "Ember", island: "#000000", accent: "#FF3B30"),
        Preset(name: "Ocean", island: "#0A1A2F", accent: "#0A84FF"),
        Preset(name: "Forest", island: "#0B1F14", accent: "#30D158"),
        Preset(name: "Grape", island: "#1A0F2E", accent: "#BF5AF2"),
        Preset(name: "Lagoon", island: "#001A1A", accent: "#64D2FF"),
        Preset(name: "Dusk", island: "#1F0F0A", accent: "#FFD60A"),
        Preset(name: "Mono", island: "#000000", accent: "#FFFFFF"),
    ]
    static let defaults = presets[0]

    // Appearance
    var islandHex: String { didSet { save() } }
    var accentHex: String { didSet { save() } }
    var size: Size { didSet { save() } }
    var bouncy: Bool { didSet { save() } }
    // General
    var showIsland: Bool { didSet { save() } }
    var clickToOpen: Bool { didSet { save() } }
    var keepOpenAfterClick: Bool { didSet { save() } }
    var hoverDelay: Double { didSet { save() } }
    var openDistance: Double { didSet { save() } } // how close (pt) the pointer must come to the closed island to open it
    var haptics: Bool { didSet { save() } }
    var sounds: Bool { didSet { save() } }
    // Timers
    var focusMinutes: Int { didSet { save() } }
    var shortBreakMinutes: Int { didSet { save() } }
    var longBreakMinutes: Int { didSet { save() } }
    var timerSound: Bool { didSet { save() } }
    var pomodoroFocus: Bool { didSet { save() } }     // run the "Dynisland Focus On/Off" shortcuts as rounds change
    // Weather
    var weatherWing: Bool { didSet { save() } }       // temperature beside the notch when nothing else is showing
    var weatherCity: String { didSet { save() } }     // "" = this Mac's location
    // Scores
    var scoreStart: Bool { didSet { save() } }
    var scoreClose: Bool { didSet { save() } }
    var scoreFinal: Bool { didSet { save() } }
    // Bluetooth
    var lowBatteryCards: Bool { didSet { save() } }
    // Now Playing
    var lyrics: Bool { didSet { save() } }
    var albumTint: Bool { didSet { save() } }
    var musicActivity: Bool { didSet { save() } }
    // AI Agents
    var agentActivity: Bool { didSet { save() } }
    var agentCards: Bool { didSet { save() } }
    // Captions
    var captionSize: Double { didSet { save() } }
    var captionsAuto: Bool { didSet { save() } }      // start captions when something plays
    var hideFromSharing: Bool { didSet { save() } }   // keep the island itself out of screen sharing

    var accent: Color { Color(hex: accentHex) }
    /// The open island's fill. Kept dark (brightness ≤ 0.3) so the white text on it always reads.
    var island: Color { Color(hex: islandHex) }

    private static let keys = ["islandHex", "accentHex", "islandSize", "bouncy", "showIsland", "clickToOpen", "keepOpenAfterClick",
                               "hoverDelay", "openDistance", "haptics", "sounds", "focusMinutes", "shortBreakMinutes", "longBreakMinutes", "timerSound",
                               "lyrics", "albumTint", "musicActivity", "agentActivity", "agentCards", "captionSize", "captionsAuto", "hideFromSharing",
                               "pomodoroFocus", "weatherWing", "weatherCity", "scoreStart", "scoreClose", "scoreFinal", "lowBatteryCards"]

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ v: Bool) -> Bool { d.object(forKey: k) as? Bool ?? v }
        func int(_ k: String, _ v: Int) -> Int { d.object(forKey: k) as? Int ?? v }
        islandHex = d.string(forKey: "islandHex") ?? Self.defaults.island
        accentHex = d.string(forKey: "accentHex") ?? Self.defaults.accent
        size = Size(rawValue: d.string(forKey: "islandSize") ?? "") ?? .regular
        bouncy = bool("bouncy", true)
        showIsland = bool("showIsland", true)
        clickToOpen = bool("clickToOpen", false)
        keepOpenAfterClick = bool("keepOpenAfterClick", false)
        hoverDelay = d.object(forKey: "hoverDelay") as? Double ?? 0
        openDistance = d.object(forKey: "openDistance") as? Double ?? 24
        haptics = bool("haptics", false)
        sounds = bool("sounds", false)
        focusMinutes = int("focusMinutes", 25)
        shortBreakMinutes = int("shortBreakMinutes", 5)
        longBreakMinutes = int("longBreakMinutes", 15)
        timerSound = bool("timerSound", true)
        lyrics = bool("lyrics", true)
        albumTint = bool("albumTint", true)
        musicActivity = bool("musicActivity", true)
        agentActivity = bool("agentActivity", true)
        agentCards = bool("agentCards", true)
        captionSize = d.object(forKey: "captionSize") as? Double ?? 19
        captionsAuto = bool("captionsAuto", false)
        hideFromSharing = bool("hideFromSharing", false)
        pomodoroFocus = bool("pomodoroFocus", false)
        weatherWing = bool("weatherWing", true)
        weatherCity = d.string(forKey: "weatherCity") ?? ""
        scoreStart = bool("scoreStart", true)
        scoreClose = bool("scoreClose", true)
        scoreFinal = bool("scoreFinal", true)
        lowBatteryCards = bool("lowBatteryCards", true)
    }

    func setIsland(_ c: Color) { islandHex = c.darkened(max: 0.3).hex }
    func apply(_ p: Preset) { islandHex = p.island; accentHex = p.accent }
    func resetAppearance() { apply(Self.defaults); size = .regular; bouncy = true }

    private func save() {
        let d = UserDefaults.standard
        let values: [Any] = [islandHex, accentHex, size.rawValue, bouncy, showIsland, clickToOpen, keepOpenAfterClick, hoverDelay, openDistance, haptics,
                             sounds, focusMinutes, shortBreakMinutes, longBreakMinutes, timerSound, lyrics, albumTint, musicActivity,
                             agentActivity, agentCards, captionSize, captionsAuto, hideFromSharing,
                             pomodoroFocus, weatherWing, weatherCity, scoreStart, scoreClose, scoreFinal, lowBatteryCards]
        for (k, v) in zip(Self.keys, values) { d.set(v, forKey: k) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
    }
    func darkened(max limit: CGFloat) -> Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(nsColor: NSColor(hue: c.hueComponent, saturation: c.saturationComponent, brightness: min(c.brightnessComponent, limit), alpha: 1))
    }
}
