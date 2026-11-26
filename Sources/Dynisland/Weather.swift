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
    }
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
        guard Prefs.shared.weatherWing || !city.isEmpty || location.authorizationStatus == .authorized else {
            return // don't ask for location until weather is wanted
        }
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
                        .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max"),
                        .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "2"),
                        .init(name: "temperature_unit", value: unit)]
        guard let root = await json(q.url!), let cur = root["current"] as? [String: Any], let daily = root["daily"] as? [String: Any] else {
            await MainActor.run { status = "Couldn't load the weather." }
            return
        }
        func ints(_ k: String) -> [Int] { (daily[k] as? [Any] ?? []).map { Int((($0 as? NSNumber)?.doubleValue ?? 0).rounded()) } }
        let hi = ints("temperature_2m_max"), lo = ints("temperature_2m_min"), codes = ints("weather_code"), rain = ints("precipitation_probability_max")
        guard hi.count >= 2, lo.count >= 2, codes.count >= 2 else { return }
        let n = Now(temp: Int((cur["temperature_2m"] as? Double ?? 0).rounded()), code: cur["weather_code"] as? Int ?? 0, day: (cur["is_day"] as? Int ?? 1) == 1,
                    high: hi[0], low: lo[0], rain: rain.first ?? 0, tomorrowHigh: hi[1], tomorrowLow: lo[1], tomorrowCode: codes[1], place: place)
        await MainActor.run { now = n; status = "" }
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
