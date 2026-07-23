import Foundation

struct WeatherReading {
    let temperature: Double
    let unit: String
    let emoji: String
    let city: String

    var tempText: String { "\(Int(temperature.rounded()))\(unit)" }
}

/// Local weather via keyless public APIs: ipinfo.io for approximate location
/// (overridable with `defaults write dev.barkeep.mac weatherLat/-Lon/-City`),
/// Open-Meteo for conditions.
enum WeatherMonitor {
    static func fetch() async -> WeatherReading? {
        guard let location = await locate() else { return nil }
        let defaults = UserDefaults.standard
        let celsius = defaults.bool(forKey: "weatherCelsius")
        let unitParam = celsius ? "celsius" : "fahrenheit"
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.lat)),
            URLQueryItem(name: "longitude", value: String(location.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: unitParam),
        ]
        guard let url = components.url,
              let json = await getJSON(url),
              let current = json["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double else { return nil }
        let code = current["weather_code"] as? Int ?? 0
        return WeatherReading(
            temperature: temp,
            unit: celsius ? "C" : "F",
            emoji: emoji(for: code),
            city: location.city
        )
    }

    /// Resolves a city name to coordinates via Open-Meteo's geocoding API.
    static func geocode(_ query: String) async -> (lat: Double, lon: Double, city: String)? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "1"),
        ]
        guard let url = components.url,
              let json = await getJSON(url),
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double else { return nil }
        return (lat, lon, first["name"] as? String ?? query)
    }

    private static func locate() async -> (lat: Double, lon: Double, city: String)? {
        let defaults = UserDefaults.standard
        if let lat = defaults.object(forKey: "weatherLat") as? Double,
           let lon = defaults.object(forKey: "weatherLon") as? Double {
            return (lat, lon, defaults.string(forKey: "weatherCity") ?? "custom")
        }
        guard let json = await getJSON(URL(string: "https://ipinfo.io/json")!),
              let loc = json["loc"] as? String else { return nil }
        let parts = loc.split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        return (lat, lon, json["city"] as? String ?? "?")
    }

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// WMO weather code → emoji icon.
    private static func emoji(for code: Int) -> String {
        switch code {
        case 0: return "☀️"
        case 1: return "🌤"
        case 2: return "⛅️"
        case 3: return "☁️"
        case 45, 48: return "🌫"
        case 51...57: return "🌦"
        case 61...67, 80...82: return "🌧"
        case 71...77, 85, 86: return "🌨"
        case 95...99: return "⛈"
        default: return "🌡"
        }
    }
}
