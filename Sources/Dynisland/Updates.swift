import AppKit
import Security

/// Updates straight from GitHub Releases, no framework. Asks GitHub for the latest release; if it's newer, downloads its
/// DMG, checks the app inside is signed with the same certificate as this copy (so no one else's build can be installed,
/// and macOS keeps every permission), swaps it in place of this app and relaunches.
enum Updates {
    private static let api = URL(string: "https://api.github.com/repos/AleSignorile12/Dynisland/releases/latest")!
    private static var busy = false
    static var automatic: Bool { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }

    /// A check shortly after launch, then once a day. Silent unless there's an update.
    static func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if automatic { run(manual: false) } }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in if automatic { run(manual: false) } }
    }

    /// From the Check for Updates… buttons: also says when it's up to date or something failed.
    static func check() { run(manual: true) }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func run(manual: Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            var installing = false
            do {
                var req = URLRequest(url: api)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub didn't answer (try again later).") }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = String(release.tag_name.trimmingPrefix("v"))
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                guard latest.compare(current, options: .numeric) == .orderedDescending,
                      let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                    if manual { alert("Dynisland is up to date", "You have the latest version, \(current).") }
                    return
                }
                NSApp.activate() // an agent app: bring the alert to the front
                let a = NSAlert()
                a.messageText = "Dynisland \(latest) is available"
                a.informativeText = "You have \(current). It downloads, installs and relaunches by itself, keeping your settings and permissions."
                a.addButton(withTitle: "Install and Relaunch")
                a.addButton(withTitle: "Later")
                a.addButton(withTitle: "What's New")
                switch a.runModal() {
                case .alertFirstButtonReturn: installing = true; try await install(dmg.browser_download_url)
                case .alertThirdButtonReturn: NSWorkspace.shared.open(release.html_url)
                default: break
                }
            } catch {
                if manual || installing { alert("Couldn't update Dynisland", error.localizedDescription) }
            }
        }
    }

    @MainActor private static func install(_ url: URL) async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "DynislandUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appending(path: "update.dmg"), mount = dir.appending(path: "mnt"), staged = dir.appending(path: "Dynisland.app")

        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download failed.") }
        try fm.moveItem(at: file, to: dmg)
        try await run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path)
        var copyError: Error?
        do { try await run("/usr/bin/ditto", mount.appending(path: "Dynisland.app").path, staged.path) } catch { copyError = error }
        try? await run("/usr/bin/hdiutil", "detach", "-force", mount.path)
        if let copyError { throw copyError }
        try verify(staged)

        let app = Bundle.main.bundleURL
        _ = try fm.replaceItemAt(app, withItemAt: staged) // the running copy keeps working until it quits
        let relaunch = Process() // waits for this process to end, then opens the new copy
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try relaunch.run()
        try? fm.removeItem(at: dir) // terminate() exits before the defer runs
        NSApp.terminate(nil)
    }

    /// The new app must satisfy this app's designated requirement: same bundle ID, same signing certificate.
    private static func verify(_ app: URL) throws {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new
        else { throw Failure("Couldn't read the code signatures.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(new, flags, requirement) == errSecSuccess else {
            throw Failure("The download isn't signed with the same certificate as this copy of Dynisland, so it wasn't installed.")
        }
    }

    private static func run(_ args: String...) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0])
            p.arguments = Array(args.dropFirst())
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw Failure("\(URL(fileURLWithPath: args[0]).lastPathComponent) failed (\(p.terminationStatus)).") }
        }.value
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

