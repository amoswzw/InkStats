import InkKit
import Foundation

struct WeatherPlace: Codable, Hashable {
    let name: String
    /// Region and country, to tell places with the same name apart.
    let detail: String
    let latitude: Double
    let longitude: Double
}

enum WeatherCondition {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, thunder

    /// WMO weather interpretation codes, as used by Open-Meteo.
    init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1, 2: self = .partlyCloudy
        case 45, 48: self = .fog
        case 51...57: self = .drizzle
        case 61...67, 80...82: self = .rain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .thunder
        default: self = .cloudy
        }
    }

    var names: (chinese: String, english: String) {
        switch self {
        case .clear: return ("晴", "Clear")
        case .partlyCloudy: return ("多云", "Partly cloudy")
        case .cloudy: return ("阴", "Overcast")
        case .fog: return ("雾", "Fog")
        case .drizzle: return ("毛毛雨", "Drizzle")
        case .rain: return ("雨", "Rain")
        case .snow: return ("雪", "Snow")
        case .thunder: return ("雷雨", "Thunderstorm")
        }
    }
}

struct WeatherDay {
    let date: Date
    let condition: WeatherCondition
    let low: Double
    let high: Double
    let precipitationChance: Int?
}

struct WeatherReport {
    let place: WeatherPlace
    let fetched: Date
    /// The place's own UTC offset, so days and times read as they do there.
    let timeZone: TimeZone
    let celsius: Double
    let feelsLike: Double
    let humidity: Double
    let windKmh: Double
    let condition: WeatherCondition
    let isDay: Bool
    let sunrise: Date?
    let sunset: Date?
    /// Hourly temperatures from the current hour onward, 25 points.
    let hourly: [Double?]
    let days: [WeatherDay]
}

/// Fetches forecasts from Open-Meteo. This is the only part of InkStats that uses the network,
/// and it does nothing until the user turns on the weather item and picks a place.
final class WeatherService {
    static let shared = WeatherService()

    private static let refreshInterval: TimeInterval = 30 * 60
    private static let retryInterval: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var report: WeatherReport?
    private var lastError: String?
    private var lastAttempt: (place: WeatherPlace, date: Date)?
    private var loading = false

    func cached(for place: WeatherPlace?) -> WeatherReport? {
        lock.lock(); defer { lock.unlock() }
        return report?.place == place ? report : nil
    }

    var error: String? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    func refreshIfNeeded(enabled: Bool, place: WeatherPlace?) {
        guard enabled, let place else { return }
        lock.lock()
        let current = report?.place == place ? report : nil
        let stale = current.map { Date().timeIntervalSince($0.fetched) > Self.refreshInterval } ?? true
        let canRetry = lastAttempt.map { $0.place != place || Date().timeIntervalSince($0.date) > Self.retryInterval } ?? true
        guard stale, canRetry, !loading else { lock.unlock(); return }
        loading = true
        lastAttempt = (place, Date())
        lock.unlock()

        Task {
            let result: Result<WeatherReport, Error>
            do { result = .success(try await Self.fetch(place)) } catch { result = .failure(error) }
            finish(result)
        }
    }

    private func finish(_ result: Result<WeatherReport, Error>) {
        lock.lock(); defer { lock.unlock() }
        loading = false
        switch result {
        case .success(let fresh): report = fresh; lastError = nil
        case .failure(let error): lastError = error.localizedDescription
        }
    }

    // MARK: Open-Meteo

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature2m: Double
            let apparentTemperature: Double
            let relativeHumidity2m: Double
            let weatherCode: Int
            let windSpeed10m: Double
            let isDay: Int

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m", apparentTemperature = "apparent_temperature"
                case relativeHumidity2m = "relative_humidity_2m", weatherCode = "weather_code"
                case windSpeed10m = "wind_speed_10m", isDay = "is_day"
            }
        }
        struct Hourly: Decodable {
            let time: [TimeInterval]
            let temperature2m: [Double?]

            enum CodingKeys: String, CodingKey {
                case time, temperature2m = "temperature_2m"
            }
        }
        struct Daily: Decodable {
            let time: [TimeInterval]
            let weatherCode: [Int?]
            let temperature2mMax: [Double?]
            let temperature2mMin: [Double?]
            let sunrise: [TimeInterval?]
            let sunset: [TimeInterval?]
            let precipitationProbabilityMax: [Int?]

            enum CodingKeys: String, CodingKey {
                case time, sunrise, sunset, weatherCode = "weather_code"
                case temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
                case precipitationProbabilityMax = "precipitation_probability_max"
            }
        }
        let utcOffsetSeconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily

        enum CodingKeys: String, CodingKey {
            case current, hourly, daily, utcOffsetSeconds = "utc_offset_seconds"
        }
    }

    private static func fetch(_ place: WeatherPlace) async throws -> WeatherReport {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try check(response)
        return try parse(data, place: place, now: Date())
    }

    static func parse(_ data: Data, place: WeatherPlace, now date: Date) throws -> WeatherReport {
        let forecast = try JSONDecoder().decode(Forecast.self, from: data)
        let now = date.timeIntervalSince1970
        let hourStart = forecast.hourly.time.lastIndex { $0 <= now } ?? 0
        let hourly = Array(forecast.hourly.temperature2m.dropFirst(hourStart).prefix(25))

        let d = forecast.daily
        let days: [WeatherDay] = d.time.indices.compactMap { i in
            guard let low = d.temperature2mMin[i], let high = d.temperature2mMax[i] else { return nil }
            return WeatherDay(date: Date(timeIntervalSince1970: d.time[i]), condition: WeatherCondition(code: d.weatherCode[i] ?? 3),
                              low: low, high: high, precipitationChance: d.precipitationProbabilityMax[i])
        }
        let c = forecast.current
        return WeatherReport(
            place: place, fetched: date, timeZone: TimeZone(secondsFromGMT: forecast.utcOffsetSeconds) ?? .current,
            celsius: c.temperature2m, feelsLike: c.apparentTemperature, humidity: c.relativeHumidity2m, windKmh: c.windSpeed10m,
            condition: WeatherCondition(code: c.weatherCode), isDay: c.isDay == 1,
            sunrise: d.sunrise.first.flatMap { $0 }.map(Date.init(timeIntervalSince1970:)),
            sunset: d.sunset.first.flatMap { $0 }.map(Date.init(timeIntervalSince1970:)),
            hourly: hourly, days: days)
    }

    private struct Geocoding: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    static func search(_ query: String) async throws -> [WeatherPlace] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        try check(response)
        return (try JSONDecoder().decode(Geocoding.self, from: data).results ?? []).map { r in
            WeatherPlace(name: r.name, detail: [r.admin1, r.country].compactMap { $0 }.filter { $0 != r.name }.joined(separator: ", "),
                         latitude: r.latitude, longitude: r.longitude)
        }
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Open-Meteo returned status \(http.statusCode)."])
        }
    }
}
