import AppKit
import Observation
import SwiftUI

// MARK: Internet speed

/// Runs macOS's own speed test (/usr/bin/networkQuality, the same one as System Settings' Wi-Fi details).
@Observable
final class NetworkService {
    struct Result {
        var down: Double   // Mbit/s
        var up: Double     // Mbit/s
        var rpm: Double    // round trips per minute under load ("responsiveness")
        var latency: Double // ms, idle
        var date: Date
    }
    var result: Result?
    var running = false
    var failed = false

    func test() {
        guard !running else { return }
        running = true
        failed = false
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
            p.arguments = ["-c", "-M", "15"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let r = d.flatMap { d -> Result? in
                guard let down = d["dl_throughput"] as? Double, let up = d["ul_throughput"] as? Double else { return nil }
                return Result(down: down / 1e6, up: up / 1e6, rpm: d["responsiveness"] as? Double ?? 0,
                              latency: d["base_rtt"] as? Double ?? 0, date: .now)
            }
            await MainActor.run {
                if let r { self.result = r } else { self.failed = true }
                self.running = false
            }
        }
    }
}

/// Compact speed test shown on the System page.
struct SpeedTest: View {
    let network: NetworkService

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Internet").font(.system(size: 10)).foregroundStyle(.secondary)
                row("arrow.down", network.result.map { mbps($0.down) }, .blue)
                row("arrow.up", network.result.map { mbps($0.up) }, .purple)
                Text(status).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)
            Button { network.test() } label: {
                Group {
                    if network.running { ProgressView().controlSize(.small) }
                    else { Image(systemName: network.result == nil ? "play.fill" : "arrow.clockwise").font(.system(size: 13, weight: .bold)) }
                }
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(network.running)
            .help("Run a speed test (about 15 s)")
        }
    }

    private var status: String {
        if network.running { return "Testing… ~15 s" }
        if network.failed { return "Test failed" }
        guard let r = network.result else { return "Speed test" }
        return "\(Int(r.latency)) ms · \(Int(r.rpm)) RPM"
    }

    private func mbps(_ v: Double) -> String { v >= 100 ? "\(Int(v)) Mbps" : String(format: "%.1f Mbps", v) }

    private func row(_ icon: String, _ value: String?, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            Text(value ?? "—").font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1)
                .contentTransition(.numericText())
        }
        .animation(.smooth, value: value)
    }
}

// MARK: Sports

enum Sport: String, CaseIterable, Identifiable {
    case basketball, soccer, football, hockey, baseball
    var id: Self { self }
    var title: String { rawValue == "football" ? "American Football" : rawValue.capitalized }
    var icon: String {
        switch self {
        case .basketball: "basketball.fill"
        case .soccer: "soccerball"
        case .football: "football.fill"
        case .hockey: "hockey.puck.fill"
        case .baseball: "baseball.fill"
        }
    }
}

/// Scores from ESPN's public scoreboards, the official EuroLeague API (EuroLeague, EuroCup) and legabasket.it (LBA).
/// Serie A2 has no feed at all, so it is a link to LNP's site. No keys needed.
@Observable
final class SportsService {
    struct League: Identifiable, Hashable {
        let id: String    // "espn:<sport>/<league>" or "euroleague:<E|U>"
        let name: String
        let short: String // badge on game cards
        let sport: Sport
    }

    static let catalog: [League] = {
        func espn(_ path: String, _ name: String, _ short: String, _ sport: Sport) -> League { League(id: "espn:\(path)", name: name, short: short, sport: sport) }
        return [
            espn("basketball/nba", "NBA", "NBA", .basketball),
            League(id: "euroleague:E", name: "EuroLeague", short: "EL", sport: .basketball),
            League(id: "euroleague:U", name: "EuroCup", short: "EC", sport: .basketball),
            League(id: "lba:A1", name: "LBA Serie A", short: "LBA", sport: .basketball),
            League(id: "link:https://www.legapallacanestro.com", name: "Serie A2 (LNP)", short: "A2", sport: .basketball),
            espn("basketball/wnba", "WNBA", "WNBA", .basketball),
            espn("basketball/nba-development", "NBA G League", "G-L", .basketball),
            espn("basketball/mens-college-basketball", "NCAA Men's", "NCAA", .basketball),
            espn("basketball/womens-college-basketball", "NCAA Women's", "NCAAW", .basketball),
            espn("basketball/fiba", "FIBA", "FIBA", .basketball),
            espn("soccer/ita.1", "Serie A", "SA", .soccer),
            espn("soccer/ita.2", "Serie B", "SB", .soccer),
            espn("soccer/ita.coppa_italia", "Coppa Italia", "CI", .soccer),
            espn("soccer/uefa.champions", "Champions League", "UCL", .soccer),
            espn("soccer/uefa.europa", "Europa League", "UEL", .soccer),
            espn("soccer/uefa.europa.conf", "Conference League", "UECL", .soccer),
            espn("soccer/eng.1", "Premier League", "PL", .soccer),
            espn("soccer/esp.1", "LaLiga", "LL", .soccer),
            espn("soccer/ger.1", "Bundesliga", "BL", .soccer),
            espn("soccer/fra.1", "Ligue 1", "L1", .soccer),
            espn("soccer/por.1", "Liga Portugal", "LP", .soccer),
            espn("soccer/ned.1", "Eredivisie", "ERE", .soccer),
            espn("soccer/usa.1", "MLS", "MLS", .soccer),
            espn("soccer/fifa.world", "World Cup", "WC", .soccer),
            espn("football/nfl", "NFL", "NFL", .football),
            espn("football/college-football", "College Football", "NCAAF", .football),
            espn("hockey/nhl", "NHL", "NHL", .hockey),
            espn("baseball/mlb", "MLB", "MLB", .baseball),
        ]
    }()

    struct Team: Hashable {
        var abbr: String
        var score: String
        var logo: URL?
    }
    struct Game: Identifiable, Hashable {
        var id: String
        var league: String // short name
        var home: Team
        var away: Team
        var state: String  // pre, in, post
        var detail: String
        var date: Date?
        var link: URL?
        var closing = false // last minutes and within a score or two (only feeds with a game clock: ESPN)
    }

    var followed: [League] {
        didSet { UserDefaults.standard.set(followed.map(\.id), forKey: "sportsFollowed"); Task { await refresh() } }
    }
    /// League whose live game shows in the closed island: "" nothing, "*" any followed league, else a league id.
    var notchLeague: String {
        didSet { UserDefaults.standard.set(notchLeague, forKey: "sportsNotch"); Task { await refresh() } }
    }
    /// Cards for game starts, close finishes and finals: "" off, "*" every followed league, else a league id.
    var alertLeague: String {
        didSet { UserDefaults.standard.set(alertLeague, forKey: "sportsAlerts"); Task { await refresh() } }
    }
    @ObservationIgnored var onAlert: (_ icon: String, _ title: String, _ subtitle: String) -> Void = { _, _, _ in }
    @ObservationIgnored private var seen: [String: (state: String, closing: Bool)]? // nil until the first load, so launching doesn't alert
    var games: [Game] = []
    var failed = false
    var liveForNotch: Game? {
        guard !notchLeague.isEmpty else { return nil }
        let shorts = notchLeague == "*" ? Set(followed.map(\.short)) : Set(followed.filter { $0.id == notchLeague }.map(\.short))
        return games.first { $0.state == "in" && shorts.contains($0.league) }
    }

    @ObservationIgnored private var lbaSeason: (id: Int, date: Date)?
    @ObservationIgnored private var euroCache: [String: (date: Date, games: [Game])] = [:]
    @ObservationIgnored private var poller: Timer?

    init() {
        let d = UserDefaults.standard
        let saved = d.stringArray(forKey: "sportsFollowed") ?? ["espn:basketball/nba", "euroleague:E", "euroleague:U", "espn:soccer/ita.1"]
        followed = saved.compactMap { id in Self.catalog.first { $0.id == id } }
        notchLeague = d.string(forKey: "sportsNotch") ?? ""
        alertLeague = d.string(forKey: "sportsAlerts") ?? "*"
        // While a live score or alerts are wanted, keep scores fresh even with the page closed.
        poller = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, !notchLeague.isEmpty || !alertLeague.isEmpty else { return }
            Task { await self.refresh() }
        }
        if !notchLeague.isEmpty || !alertLeague.isEmpty { Task { await refresh() } }
    }

    func follow(_ l: League) { if !followed.contains(l) { followed.append(l) } }
    func unfollow(_ l: League) {
        followed.removeAll { $0 == l }
        if notchLeague == l.id { notchLeague = "" }
        if alertLeague == l.id { alertLeague = "" }
    }

    func refresh() async {
        let leagues = followed
        var all: [Game] = []
        var anyFailed = false
        await withTaskGroup(of: [Game]?.self) { group in
            for l in leagues { group.addTask { await self.fetch(l) } }
            for await r in group { if let r { all += r } else { anyFailed = true } }
        }
        let rank = ["in": 0, "pre": 1, "post": 2]
        await MainActor.run {
            failed = anyFailed && all.isEmpty
            games = all.sorted { ((rank[$0.state] ?? 3), $0.date ?? .distantFuture) < ((rank[$1.state] ?? 3), $1.date ?? .distantFuture) }
            alert(all)
        }
    }

    /// Compares with the previous load and raises one card per change, for the leagues chosen in Settings → Scores.
    private func alert(_ all: [Game]) {
        let wanted = alertLeague == "*" ? followed : followed.filter { $0.id == alertLeague }
        let shorts = Dictionary(wanted.map { ($0.short, $0.sport) }, uniquingKeysWith: { a, _ in a })
        defer { seen = Dictionary(all.map { ($0.id, ($0.state, $0.closing)) }, uniquingKeysWith: { a, _ in a }) }
        guard let seen, !alertLeague.isEmpty else { return }
        let p = Prefs.shared
        for g in all {
            guard let sport = shorts[g.league], let before = seen[g.id] else { continue } // new ids (next matchday) don't alert
            let match = "\(g.away.abbr) – \(g.home.abbr)"
            let score = "\(g.away.abbr) \(g.away.score) – \(g.home.score) \(g.home.abbr)"
            if before.state == "pre", g.state == "in", p.scoreStart { onAlert(sport.icon, "\(match) started", g.league) }
            else if before.state == "in", g.state == "post", p.scoreFinal { onAlert(sport.icon, score, "Final · \(g.league)") }
            else if g.state == "in", g.closing, !before.closing, p.scoreClose { onAlert(sport.icon, score, "Close finish · \(g.detail)") }
        }
    }

    private func fetch(_ l: League) async -> [Game]? {
        let parts = l.id.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "euroleague": return await euroleague(parts[1], short: l.short)
        case "lba": return await lba(short: l.short)
        case "link": return []
        default: return await espn(parts[1], short: l.short)
        }
    }

    /// Leagues with no score feed: shown as a button that opens their site.
    var linkLeagues: [(name: String, url: URL)] {
        followed.compactMap { l in
            guard l.id.hasPrefix("link:"), let url = URL(string: String(l.id.dropFirst(5))) else { return nil }
            return (l.name, url)
        }
    }

    // MARK: LBA

    /// legabasket.it's own website data (not a published API: it can change without notice). The calendar call returns
    /// the current matchday; game_status "0" scheduled, "1" live, "2" final. The season id is looked up every 6 hours.
    private func lba(short: String) async -> [Game]? {
        let base = "https://www.legabasket.it/api/championships"
        var season = await MainActor.run { lbaSeason }
        if season == nil || -(season!.date.timeIntervalSinceNow) > 6 * 3600 {
            guard let root = await json(URL(string: "\(base)/get-championships?cs_id=1&items=1000")!),
                  let list = root["competitions"] as? [[String: Any]],
                  let id = list.filter({ $0["status"] as? Int == 1 }).compactMap({ $0["id"] as? Int }).max() else { return nil }
            season = (id, .now)
            await MainActor.run { lbaSeason = season }
        }
        guard let id = season?.id, let root = await json(URL(string: "\(base)/get-championships-calendar-by-id?id=\(id)")!),
              let matches = root["matches"] as? [[String: Any]] else { return nil }
        let cdn = root["cdn_url"] as? String ?? "https://lba-media.s3.eu-south-1.amazonaws.com"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return matches.compactMap { m in
            guard let mid = m["id"] as? Int else { return nil }
            func team(_ code: String, _ score: String, _ logo: String) -> Team {
                Team(abbr: m[code] as? String ?? "?", score: "\(m[score] as? Int ?? 0)", logo: (m[logo] as? String).flatMap { URL(string: "\(cdn)/\($0)") })
            }
            let status = m["game_status"] as? String ?? "0"
            let state = status == "2" ? "post" : status == "1" ? "in" : "pre"
            return Game(id: "lba\(mid)", league: short, home: team("h_club_code", "home_final_score", "home_logo_key"),
                        away: team("v_club_code", "visitor_final_score", "v_logo_key"), state: state,
                        detail: state == "post" ? "Final" : state == "in" ? "Live" : "", date: (m["match_datetime"] as? String).flatMap(iso.date),
                        link: URL(string: "https://www.legabasket.it/lba/6/calendario"))
        }
    }

    private func json(_ url: URL) async -> [String: Any]? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: ESPN

    private func espn(_ path: String, short: String) async -> [Game]? {
        guard let root = await json(URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard")!) else { return nil }
        let sport = Sport(rawValue: String(path.prefix { $0 != "/" })) ?? .basketball
        let halves = path.contains("college-basketball") // NCAA plays two halves, the NBA four quarters
        return (root["events"] as? [[String: Any]] ?? []).compactMap { Self.espnGame($0, short: short, sport: sport, halves: halves) }
    }

    private static func espnGame(_ e: [String: Any], short: String, sport: Sport, halves: Bool) -> Game? {
        guard let id = e["id"] as? String,
              let comp = (e["competitions"] as? [[String: Any]])?.first,
              let teams = comp["competitors"] as? [[String: Any]],
              let status = (e["status"] as? [String: Any])?["type"] as? [String: Any] else { return nil }
        func team(_ side: String) -> Team? {
            guard let c = teams.first(where: { $0["homeAway"] as? String == side }), let t = c["team"] as? [String: Any] else { return nil }
            return Team(abbr: t["abbreviation"] as? String ?? "?", score: c["score"] as? String ?? "", logo: (t["logo"] as? String).flatMap(URL.init))
        }
        guard let home = team("home"), let away = team("away") else { return nil }
        let link = ((e["links"] as? [[String: Any]])?.first?["href"] as? String).flatMap(URL.init)
        // Close finish: final period, under 5 minutes left (soccer: 80th minute on), and a small margin for the sport.
        let st = e["status"] as? [String: Any] ?? [:]
        let period = st["period"] as? Int ?? 0, clock = st["clock"] as? Double ?? .infinity
        let margin = abs((Int(home.score) ?? 0) - (Int(away.score) ?? 0))
        let closing: Bool = switch sport {
        case .basketball: period >= (halves ? 2 : 4) && clock <= 300 && margin <= 5
        case .football: period >= 4 && clock <= 300 && margin <= 8
        case .hockey: period >= 3 && clock <= 300 && margin <= 1
        case .soccer: (Int((st["displayClock"] as? String ?? "").prefix { $0.isNumber }) ?? 0) >= 80 && margin <= 1
        case .baseball: period >= 9 && margin <= 2
        }
        return Game(id: "espn\(id)", league: short, home: home, away: away, state: status["state"] as? String ?? "pre",
                    detail: status["shortDetail"] as? String ?? "", date: (e["date"] as? String).flatMap(parseDate), link: link,
                    closing: closing && status["state"] as? String == "in")
    }

    // MARK: EuroLeague / EuroCup

    /// The feed returns the whole season (~0.7 MB), so it's cached for 2 minutes and trimmed to yesterday…next week.
    private func euroleague(_ code: String, short: String) async -> [Game]? {
        let cached = await MainActor.run { euroCache[code] } // the cache is only touched on the main thread
        if let c = cached, -c.date.timeIntervalSinceNow < 120 { return c.games }
        let now = Date.now, cal = Calendar.current
        let year = cal.component(.year, from: now) - (cal.component(.month, from: now) < 7 ? 1 : 0) // seasons start in July
        guard let root = await json(URL(string: "https://api-live.euroleague.net/v2/competitions/\(code)/seasons/\(code)\(year)/games")!),
              let data = root["data"] as? [[String: Any]] else { return cached?.games }
        let games: [Game] = data.compactMap { g in
            guard let local = g["local"] as? [String: Any], let road = g["road"] as? [String: Any],
                  let date = (g["utcDate"] as? String).flatMap(Self.parseDate),
                  date > now - 86_400, date < now + 7 * 86_400 else { return nil }
            func team(_ t: [String: Any]) -> Team {
                let club = t["club"] as? [String: Any] ?? [:]
                let score = t["score"] as? Int ?? 0
                return Team(abbr: club["tvCode"] as? String ?? "?", score: "\(score)",
                            logo: ((club["images"] as? [String: Any])?["crest"] as? String).flatMap(URL.init))
            }
            let played = g["played"] as? Bool ?? false
            let status = (g["gameStatus"] as? String ?? "").lowercased()
            let live = !played && (status.contains("live") || (date < now && now.timeIntervalSince(date) < 3 * 3600))
            return Game(id: "el\(g["identifier"] as? String ?? UUID().uuidString)", league: short, home: team(local), away: team(road),
                        state: played ? "post" : live ? "in" : "pre", detail: played ? "Final" : live ? "Live" : "", date: date, link: nil)
        }
        await MainActor.run { euroCache[code] = (.now, games) }
        return games
    }

    /// Dates arrive as 2026-11-12T19:45Z or 2026-11-12T19:45:00Z; ISO8601DateFormatter rejects the first.
    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mmX", "yyyy-MM-dd'T'HH:mm:ssX"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

struct SportsSection: View {
    let sports: SportsService
    @State private var filter: String? // league short name, nil = all followed

    var body: some View {
        let shown = sports.games.filter { filter == nil || $0.league == filter }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("All followed") { filter = nil }
                    Divider()
                    ForEach(sports.followed.filter { !$0.id.hasPrefix("link:") }) { l in Button(l.name) { filter = l.short } }
                } label: {
                    Text(filter.flatMap { f in sports.followed.first { $0.short == f }?.name } ?? "All followed").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                ForEach(sports.linkLeagues, id: \.name) { l in // leagues with no live feed open their results page
                    Button { NSWorkspace.shared.open(l.url) } label: {
                        Label(l.name, systemImage: "arrow.up.right").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 18).background(.white.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("No live feed for this league: opens its site")
                }
            }
            if shown.isEmpty {
                Placeholder(icon: sports.failed ? "wifi.slash" : "sportscourt",
                            text: sports.followed.isEmpty ? "Follow leagues in Settings → Scores" : sports.failed ? "Couldn't load scores" : "No games right now")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(shown) { GameCard(game: $0) } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: sports.followed) {
            while !Task.isCancelled {
                await sports.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

struct GameCard: View {
    let game: SportsService.Game

    var body: some View {
        Button { if let link = game.link { NSWorkspace.shared.open(link) } } label: {
            VStack(alignment: .leading, spacing: 5) {
                row(game.away)
                row(game.home)
                HStack(spacing: 4) {
                    if game.state == "in" { Circle().fill(.red).frame(width: 5, height: 5) }
                    Text(status).font(.system(size: 9, weight: .medium)).lineLimit(1)
                        .foregroundStyle(game.state == "in" ? .red : .secondary)
                    Spacer(minLength: 0)
                    Text(game.league).font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
            }
            .padding(9)
            .frame(width: 124, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        guard game.state == "pre", let d = game.date else { return game.detail }
        return Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func row(_ t: SportsService.Team) -> some View {
        HStack(spacing: 6) {
            AsyncImage(url: t.logo) { $0.resizable().scaledToFit() } placeholder: { Circle().fill(.white.opacity(0.1)) }
                .frame(width: 18, height: 18)
            Text(t.abbr).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if game.state != "pre" { Text(t.score).font(.system(size: 13, weight: .bold).monospacedDigit()) }
        }
    }
}
