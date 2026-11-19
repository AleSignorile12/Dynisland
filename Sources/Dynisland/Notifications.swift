import AppKit

/// Mirrors macOS notification banners into the island by reading Notification Center's windows through Accessibility
/// (there is no public API for other apps' notifications). Needs the Accessibility permission.
/// shortcut: opening the Notification Center panel also reads as a new banner; filter by window size if that bothers.
final class NotificationWatcher {
    var onBanner: (_ title: String, _ body: String) -> Void = { _, _ in }
    private var last = ""
    private var timer: Timer?

    init() {
        timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
        else { return }
        var texts: [String] = []
        collectText(AXUIElementCreateApplication(nc.processIdentifier), into: &texts, depth: 0)
        let snapshot = texts.joined(separator: "\n")
        guard snapshot != last else { return }
        last = snapshot // empty once the banner leaves, so the next one shows even if identical
        if let title = texts.first { onBanner(title, texts.dropFirst().joined(separator: " · ")) }
    }

    private func collectText(_ e: AXUIElement, into texts: inout [String], depth: Int) {
        guard depth < 14, texts.count < 4 else { return }
        if axValue(e, kAXRoleAttribute) as? String == kAXStaticTextRole,
           let v = axValue(e, kAXValueAttribute) as? String, !v.isEmpty { texts.append(v) }
        for child in (axValue(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { collectText(child, into: &texts, depth: depth + 1) }
    }
}

func axValue(_ e: AXUIElement, _ attribute: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
}
