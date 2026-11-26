import SwiftUI

/// Battery levels of connected Bluetooth devices (AirPods, Magic Mouse/Keyboard/Trackpad, other headphones), read from
/// `system_profiler` every 5 minutes (it takes about a second, so not more often), and a card when one drops below 20%.
@Observable
final class BluetoothService {
    struct Device: Identifiable, Equatable {
        var name: String
        var kind: String          // device_minorType: Headphones, Mouse, Keyboard, Trackpad…
        var level: Int            // lowest of main / left / right
        var detail: String        // "L 80% · R 75% · Case 40%" for earbuds
        var id: String { name }
        var symbol: String {
            let k = kind.lowercased(), n = name.lowercased()
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if k.contains("mouse") { return "magicmouse.fill" }
            if k.contains("keyboard") { return "keyboard.fill" }
            if k.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
            if k.contains("headphone") || k.contains("headset") { return "headphones" }
            return "dot.radiowaves.left.and.right"
        }
    }
    var devices: [Device] = []
    @ObservationIgnored var onLow: (Device) -> Void = { _ in }
    @ObservationIgnored private var warned: Set<String> = []
    @ObservationIgnored private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        Task.detached { [weak self] in
            let found = Self.read()
            await MainActor.run { self?.update(found) }
        }
    }

    private func update(_ found: [Device]) {
        devices = found
        for d in found {
            if d.level < 20, !warned.contains(d.name) {
                warned.insert(d.name)
                if Prefs.shared.lowBatteryCards { onLow(d) }
            } else if d.level >= 30 {
                warned.remove(d.name) // charged again: warn next time it runs low
            }
        }
    }

    private static func read() -> [Device] {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [Device] = []
        for c in controllers {
            for entry in c["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? { (info[key] as? String).flatMap { Int($0.filter(\.isNumber)) } }
                    let main = level("device_batteryLevelMain"), left = level("device_batteryLevelLeft"),
                        right = level("device_batteryLevelRight"), box = level("device_batteryLevelCase")
                    let parts = [left.map { "L \($0)%" }, right.map { "R \($0)%" }, box.map { "Case \($0)%" }].compactMap { $0 }
                    guard let lowest = [main, left, right].compactMap({ $0 }).min() else { continue } // no battery reported
                    result.append(Device(name: name, kind: info["device_minorType"] as? String ?? "", level: lowest,
                                         detail: parts.isEmpty ? "\(lowest)%" : parts.joined(separator: " · ")))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }
}

/// System page column: one row per connected device.
struct BluetoothColumn: View {
    let bluetooth: BluetoothService
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(bluetooth.devices.prefix(3)) { d in
                HStack(spacing: 6) {
                    Image(systemName: d.symbol).font(.system(size: 12)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Text(d.detail).font(.system(size: 9).monospacedDigit()).foregroundStyle(d.level < 20 ? .red : .secondary).lineLimit(1)
                    }
                }
                .help("\(d.name): \(d.detail)")
            }
        }
        .frame(width: 112, alignment: .leading)
    }
}
