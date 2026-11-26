import CoreLocation
import SwiftUI

/// Weather from Open-Meteo (free, no key), for this Mac's location or a city typed in Settings. Refreshed every 30 min.
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    struct Now: Equatable {
        var temp: Int, code: Int, day: Bool
        var high: Int, low: Int, rain: Int     // today; rain = max precipitation chance %
        var tomorrowHigh: Int, tomorrowLow: Int, tomorrowCode: Int
        var place: String
        var hours: [Hour] = []  // from this hour on, next 24 h
        var days: [Day] = []    // today + 6
    }
    struct Hour: Equatable, Identifiable { var label: String, temp: Int, code: Int, day: Bool; var id: String { label } }
    struct Day: Equatable, Identifiable { var label: String, high: Int, low: Int, code: Int, rain: Int; var id: String { label } }
    var now: Now?
    var status = ""  // why there's no weather, for Settings

    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCity = ""
    @ObservationIgnored private var lastWing = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, Prefs.shared.weatherCity != lastCity || Prefs.shared.weatherWing != lastWing else { return }
            refresh()
        }
        refresh()
    }

    var unit: String { Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius" }

    func refresh() {
        let city = Prefs.shared.weatherCity.trimmingCharacters(in: .whitespaces)
        lastCity = Prefs.shared.weatherCity
        lastWing = Prefs.shared.weatherWing
        if city.isEmpty {
            switch location.authorizationStatus {
            case .notDetermined: location.requestWhenInUseAuthorization()
            case .denied, .restricted: status = "Location is off for Dynisland. Type a city instead."
            default: location.requestLocation()
            }
        } else {
            Task { await geocode(city) }
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if Prefs.shared.weatherCity.isEmpty, m.authorizationStatus == .authorized || m.authorizationStatus == .authorizedAlways { m.requestLocation() }
        else if m.authorizationStatus == .denied { status = "Location is off for Dynisland. Type a city instead." }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) {
        guard let c = l.last?.coordinate else { return }
        Task { await load(lat: c.latitude, lon: c.longitude, place: "") }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { status = "Couldn't find your location." }

    private func geocode(_ city: String) async {
        var q = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        q.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        guard let root = await json(q.url!), let r = (root["results"] as? [[String: Any]])?.first,
              let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else {
            await MainActor.run { status = "No place called \"\(city)\"." }
            return
        }
        await load(lat: lat, lon: lon, place: r["name"] as? String ?? city)
    }

    private func load(lat: Double, lon: Double, place: String) async {
        var q = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        q.queryItems = [.init(name: "latitude", value: String(format: "%.2f", lat)), .init(name: "longitude", value: String(format: "%.2f", lon)),
                        .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                        .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
                        .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
                        .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "7"),
                        .init(name: "temperature_unit", value: unit)]
        guard let root = await json(q.url!), let cur = root["current"] as? [String: Any], let daily = root["daily"] as? [String: Any] else {
            await MainActor.run { status = "Couldn't load the weather." }
            return
        }
        func ints(_ k: String) -> [Int] { (daily[k] as? [Any] ?? []).map { Int((($0 as? NSNumber)?.doubleValue ?? 0).rounded()) } }
        let hi = ints("temperature_2m_max"), lo = ints("temperature_2m_min"), codes = ints("weather_code"), rain = ints("precipitation_probability_max")
        guard hi.count >= 2, lo.count >= 2, codes.count >= 2 else { return }
        var n = Now(temp: Int((cur["temperature_2m"] as? Double ?? 0).rounded()), code: cur["weather_code"] as? Int ?? 0, day: (cur["is_day"] as? Int ?? 1) == 1,
                    high: hi[0], low: lo[0], rain: rain.first ?? 0, tomorrowHigh: hi[1], tomorrowLow: lo[1], tomorrowCode: codes[1], place: place)
        // Times arrive in the place's own time zone ("2026-11-26T14:00"); labels are shown in that zone too, like Weather.
        let zone = TimeZone(secondsFromGMT: root["utc_offset_seconds"] as? Int ?? 0) ?? .current
        let parse = DateFormatter(), hourLabel = DateFormatter(), dayLabel = DateFormatter()
        for f in [parse, hourLabel, dayLabel] { f.timeZone = zone }
        parse.locale = Locale(identifier: "en_US_POSIX")
        hourLabel.setLocalizedDateFormatFromTemplate("j")
        dayLabel.setLocalizedDateFormatFromTemplate("EEE")
        if let hourly = root["hourly"] as? [String: Any], let times = hourly["time"] as? [String] {
            func col(_ k: String) -> [Int] { (hourly[k] as? [Any] ?? []).map { Int((($0 as? NSNumber)?.doubleValue ?? 0).rounded()) } }
            let temps = col("temperature_2m"), hcodes = col("weather_code"), isDay = col("is_day")
            let nowHour = String((cur["time"] as? String ?? "").prefix(13)) // "2026-11-26T14"
            parse.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let start = times.firstIndex(where: { $0.hasPrefix(nowHour) }) {
                n.hours = (start..<min(start + 24, times.count, temps.count, hcodes.count)).map { i in
                    Hour(label: i == start ? "Now" : parse.date(from: times[i]).map(hourLabel.string) ?? "", temp: temps[i], code: hcodes[i],
                         day: (isDay.indices.contains(i) ? isDay[i] : 1) == 1)
                }
            }
        }
        if let dates = daily["time"] as? [String] {
            parse.dateFormat = "yyyy-MM-dd"
            n.days = (0..<min(dates.count, hi.count, lo.count, codes.count)).map { i in
                Day(label: i == 0 ? "Today" : parse.date(from: dates[i]).map(dayLabel.string) ?? "", high: hi[i], low: lo[i], code: codes[i],
                    rain: rain.indices.contains(i) ? rain[i] : 0)
            }
        }
        let result = n
        await MainActor.run { now = result; status = "" }
    }

    private func json(_ url: URL) async -> [String: Any]? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// SF Symbol for a WMO weather code.
    static func symbol(_ code: Int, day: Bool = true) -> String {
        switch code {
        case 0: day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func condition(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorm"
        default: "—"
        }
    }
}

/// Island page: current conditions on the left, the next hours and the week on the right, like the Weather app.
struct WeatherSection: View {
    let weather: WeatherService

    var body: some View {
        if let w = weather.now {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(w.place.isEmpty ? "My Location" : w.place, systemImage: w.place.isEmpty ? "location.fill" : "mappin")
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1).labelStyle(.titleAndIcon)
                    Text("\(w.temp)°").font(.system(size: 38, weight: .light).monospacedDigit())
                    Text(WeatherService.condition(w.code)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text("H:\(w.high)°  L:\(w.low)°").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(width: 128, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(w.hours) { h in
                                cell(h.label, WeatherService.symbol(h.code, day: h.day), "\(h.temp)°", bold: h.label == "Now")
                            }
                        }
                    }
                    Divider().overlay(.white.opacity(0.1)).padding(.horizontal, 8)
                    HStack(spacing: 0) {
                        ForEach(w.days) { d in
                            cell(d.label, WeatherService.symbol(d.code), "\(d.high)° \(d.low)°", bold: d.label == "Today", rain: d.rain)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            Placeholder(icon: "cloud.sun", text: weather.status.isEmpty ? "Loading the weather…" : weather.status)
                .task { weather.refresh() }
        }
    }

    private func cell(_ top: String, _ symbol: String, _ bottom: String, bold: Bool, rain: Int = 0) -> some View {
        VStack(spacing: 2) {
            Text(top).font(.system(size: 9, weight: bold ? .bold : .medium)).foregroundStyle(bold ? .primary : .secondary).lineLimit(1)
            Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.system(size: 13)).frame(height: 16)
                .overlay(alignment: .bottom) {
                    if rain >= 30 { Text("\(rain)%").font(.system(size: 7, weight: .bold)).foregroundStyle(.cyan).offset(y: 9) }
                }
            Text(bottom).font(.system(size: 10, weight: .semibold).monospacedDigit()).lineLimit(1).padding(.top, rain >= 30 ? 4 : 0)
        }
        .frame(minWidth: 38)
        .padding(.vertical, 2)
    }
}

/// Today's (or tomorrow's) weather beside a Calendar day title.
struct WeatherBadge: View {
    let code: Int
    var day = true
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: WeatherService.symbol(code, day: day)).symbolRenderingMode(.multicolor)
            Text(text).monospacedDigit()
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
