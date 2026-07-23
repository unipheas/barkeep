import Foundation

struct BusyBarError: Error, LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

struct DeviceStatus: Decodable {
    struct Power: Decodable {
        let state: String
        let battery_charge: Int
    }
    struct Firmware: Decodable {
        let version: String
    }
    let power: Power
    let firmware: Firmware
}

struct UpdateStatus: Decodable {
    struct Check: Decodable {
        let available_version: String
        let event: String
        let status: String
    }
    let check: Check
}

struct ScreenFrame {
    let width: Int
    let height: Int
    /// Raw pixel bytes in GRB order, row-major.
    let grbPixels: Data
}

struct BusyBarSettings: Codable {
    var theme: String
    var show_work_phase_only: Bool
    var trigger_smart_home: Bool
}

enum TextFont: String, CaseIterable, Identifiable {
    case tiny, small, normal, condensed, bold, large, extra_large
    var id: String { rawValue }
}

final class BusyBarClient: @unchecked Sendable {
    var host: String
    var token: String

    private let session: URLSession

    init(host: String, token: String = "") {
        self.host = Self.normalizedHost(host)
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, contentType: String = "application/json") throws -> URLRequest {
        let normalizedHost = Self.normalizedHost(host)
        var components = URLComponents(string: "http://\(normalizedHost)/api\(path)")
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw BusyBarError(message: "Bad URL for host \(host)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if body != nil {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        try Self.applyAuthentication(to: &req, token: token)
        return req
    }

    static func applyAuthentication(to request: inout URLRequest, token: String) throws {
        if token.rangeOfCharacter(from: .newlines.union(.controlCharacters)) != nil {
            throw BusyBarError(
                message: "Wi-Fi password contains pasted line breaks. Clear it and enter only the Busy Bar's local HTTP API password."
            )
        }
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-API-Token")
        }
    }

    static func normalizedHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed),
           components.scheme != nil,
           let hostname = components.host {
            if let port = components.port {
                return "\(hostname):\(port)"
            }
            return hostname
        }
        return trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .first ?? trimmed
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BusyBarError(message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw BusyBarError(
                message: "HTTP \(http.statusCode) \(req.url?.path ?? ""): \(bodyText.prefix(200))",
                statusCode: http.statusCode
            )
        }
        return data
    }

    // MARK: - Status

    func status() async throws -> DeviceStatus {
        let data = try await send(request("GET", "/status"))
        return try JSONDecoder().decode(DeviceStatus.self, from: data)
    }

    // MARK: - Busy state

    func currentBusyType() async throws -> String {
        let data = try await send(request("GET", "/busy/snapshot"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let snapshot = json?["snapshot"] as? [String: Any]
        return snapshot?["type"] as? String ?? "UNKNOWN"
    }

    /// Starts a Pomodoro-style interval session on the bar's native timer.
    func startIntervalSession(workMinutes: Int, restMinutes: Int, cycles: Int, theme: String, triggerSmartHome: Bool) async throws {
        let workMs = workMinutes * 60_000
        let snapshot: [String: Any] = [
            "type": "INTERVAL",
            "card_id": "00000000-0000-0000-0000-000000000000",
            "current_interval": 1,
            "current_interval_time_total_ms": workMs,
            "current_interval_time_left_ms": workMs,
            "is_paused": false,
            "interval_settings": [
                "type": "INTERVAL",
                "interval_work_ms": workMs,
                "interval_rest_ms": restMinutes * 60_000,
                "interval_work_cycles_count": cycles,
                "is_autostart_enabled": false,
            ],
            "busy_bar_settings": [
                "theme": theme,
                "show_work_phase_only": false,
                "trigger_smart_home": triggerSmartHome,
            ],
        ]
        try await putSnapshot(snapshot)
    }

    /// Starts a simple countdown session on the bar's native timer.
    func startSimpleSession(minutes: Int, theme: String, triggerSmartHome: Bool) async throws {
        let snapshot: [String: Any] = [
            "type": "SIMPLE",
            "card_id": "00000000-0000-0000-0000-000000000000",
            "time_left_ms": minutes * 60_000,
            "is_paused": false,
            "busy_bar_settings": [
                "theme": theme,
                "show_work_phase_only": false,
                "trigger_smart_home": triggerSmartHome,
            ],
        ]
        try await putSnapshot(snapshot)
    }

    private func putSnapshot(_ snapshot: [String: Any]) async throws {
        let payload: [String: Any] = [
            "snapshot": snapshot,
            "snapshot_timestamp_ms": Int(Date().timeIntervalSince1970 * 1000),
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(try request("PUT", "/busy/snapshot", body: body))
    }

    func setBusy(_ on: Bool, theme: String, triggerSmartHome: Bool) async throws {
        var snapshot: [String: Any] = [
            "busy_bar_settings": [
                "theme": on ? theme : "busy",
                "show_work_phase_only": false,
                "trigger_smart_home": triggerSmartHome,
            ]
        ]
        if on {
            snapshot["type"] = "INFINITE"
            snapshot["card_id"] = "00000000-0000-0000-0000-000000000000"
            snapshot["is_paused"] = false
        } else {
            snapshot["type"] = "NOT_STARTED"
        }
        let payload: [String: Any] = [
            "snapshot": snapshot,
            "snapshot_timestamp_ms": Int(Date().timeIntervalSince1970 * 1000),
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(try request("PUT", "/busy/snapshot", body: body))
    }

    /// Themes are directories under the busy app's assets; "busy" is the built-in default.
    func listThemes() async throws -> [String] {
        let data = try await send(request("GET", "/storage/list", query: ["path": "/ext/apps_assets/busy/themes"]))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["list"] as? [[String: Any]] ?? []
        let themes = entries.compactMap { entry -> String? in
            guard entry["type"] as? String == "dir" else { return nil }
            return entry["name"] as? String
        }
        return ["busy"] + themes.sorted()
    }

    // MARK: - Display

    static let appName = "busybar_mac"
    static let displayWidth = 72
    static let displayHeight = 16

    static func displayPayload(
        elements: [[String: Any]],
        priority: Int,
        ledColor: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "application_name": appName,
            "priority": priority,
            "elements": elements,
        ]
        if let ledColor {
            payload["led_notification_color"] = ledColor
        }
        return payload
    }

    static func assetQuery(filename: String) -> [String: String] {
        ["application_name": appName, "file": filename]
    }

    func drawText(_ text: String, font: TextFont, colorHex: String, timeout: Int, priority: Int, ledColor: String? = nil) async throws {
        let element: [String: Any] = [
            "id": "msg",
            "type": "text",
            "text": text,
            "font": font.rawValue,
            "color": colorHex,
            "align": "mid_left",
            "x": 0,
            "y": Self.displayHeight / 2,
            "width": Self.displayWidth,
            "scroll_rate": 2500,
            "scroll_start_delay": 800,
            "scroll_repeat_delay": 1500,
            "timeout": timeout,
            "display": "front",
        ]
        try await draw(elements: [element], priority: priority, ledColor: ledColor)
    }

    func drawImage(named filename: String, timeout: Int, priority: Int, ledColor: String? = nil) async throws {
        let element: [String: Any] = [
            "id": "img",
            "type": "image",
            "path": filename,
            "align": "top_left",
            "x": 0,
            "y": 0,
            "timeout": timeout,
            "display": "front",
        ]
        try await draw(elements: [element], priority: priority, ledColor: ledColor)
    }

    private func draw(elements: [[String: Any]], priority: Int, ledColor: String? = nil) async throws {
        let payload = Self.displayPayload(
            elements: elements,
            priority: priority,
            ledColor: ledColor
        )
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(try request("POST", "/display/draw", body: body))
    }

    func clearDisplay() async throws {
        try await send(try request("DELETE", "/display/draw", query: ["application_name": Self.appName]))
    }

    func drawCountdown(to date: Date, colorHex: String, timeout: Int, priority: Int) async throws {
        let element: [String: Any] = [
            "id": "countdown",
            "type": "countdown",
            "timestamp": String(Int(date.timeIntervalSince1970)),
            "direction": "time_left",
            "show_hours": "when_non_zero",
            "color": colorHex,
            "align": "center",
            "x": Self.displayWidth / 2,
            "y": Self.displayHeight / 2,
            "timeout": timeout,
            "display": "front",
        ]
        try await draw(elements: [element], priority: priority)
    }

    /// Small latency badge in the bottom-right corner. Same application_name
    /// as messages so both elements coexist on the canvas.
    func drawPingBadge(text: String, colorHex: String) async throws {
        let element: [String: Any] = [
            "id": "ping",
            "type": "text",
            "text": text,
            "font": "tiny",
            "color": colorHex,
            "align": "bottom_right",
            "x": Self.displayWidth,
            "y": Self.displayHeight,
            "timeout": 10,
            "display": "front",
        ]
        try await draw(elements: [element], priority: 95)
    }

    /// Weather widget: 16x16 icon top-left + temperature text beside it.
    /// Same application_name as messages so all elements coexist.
    func drawWeatherBadge(iconUploaded: Bool, tempText: String) async throws {
        var elements: [[String: Any]] = [[
            "id": "wx_temp",
            "type": "text",
            "text": tempText,
            "font": "small",
            "color": "#FFD60AFF",
            "align": "mid_left",
            "x": 18,
            "y": Self.displayHeight / 2,
            "timeout": 150,
            "display": "front",
        ]]
        if iconUploaded {
            elements.append([
                "id": "wx_icon",
                "type": "image",
                "path": "wx.png",
                "align": "top_left",
                "x": 0,
                "y": 0,
                "timeout": 150,
                "display": "front",
            ])
        }
        try await draw(elements: elements, priority: 95)
    }

    enum ExpirableElement {
        case text(id: String)
        case image(id: String, path: String)
    }

    /// The draw API has no per-element delete, so removal = overwrite the
    /// element (same id) with a blank that expires after one second. The
    /// overwrite must keep the element's type — the firmware rejects
    /// replacing an image element with a text one.
    func expireElements(_ items: [ExpirableElement]) async throws {
        let elements: [[String: Any]] = items.map { item in
            switch item {
            case .text(let id):
                return [
                    "id": id, "type": "text", "text": " ", "font": "tiny",
                    "color": "#00000000", "align": "top_left", "x": 0, "y": 0,
                    "timeout": 1, "display": "front",
                ]
            case .image(let id, let path):
                return [
                    "id": id, "type": "image", "path": path, "opacity": 0,
                    "align": "top_left", "x": 0, "y": 0,
                    "timeout": 1, "display": "front",
                ]
            }
        }
        try await draw(elements: elements, priority: 95)
    }

    // MARK: - Screen preview

    /// Returns one frame of the given display (0 = front, 1 = back) as raw
    /// GRB pixel data (base64 on the wire).
    func screenFrame(display: Int = 0) async throws -> ScreenFrame {
        let data = try await send(request("GET", "/screen", query: ["display": String(display)]))
        guard let pixels = Data(base64Encoded: data) else {
            throw BusyBarError(message: "Screen frame was not base64")
        }
        let width = display == 0 ? Self.displayWidth : 160
        let height = display == 0 ? Self.displayHeight : 80
        guard pixels.count >= width * height * 3 else {
            throw BusyBarError(message: "Screen frame too small (\(pixels.count) bytes)")
        }
        return ScreenFrame(width: width, height: height, grbPixels: pixels)
    }

    // MARK: - Device settings

    func brightness() async throws -> String {
        let data = try await send(request("GET", "/display/brightness"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["value"] as? String ?? "auto"
    }

    func setBrightness(_ value: String) async throws {
        try await send(try request("POST", "/display/brightness", query: ["value": value]))
    }

    func volume() async throws -> Int {
        let data = try await send(request("GET", "/audio/volume"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["volume"] as? Int ?? 0
    }

    func setVolume(_ value: Int) async throws {
        try await send(try request("POST", "/audio/volume", query: ["volume": String(value), "silent": "true"]))
    }

    func deviceName() async throws -> String {
        let data = try await send(request("GET", "/name"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["name"] as? String ?? ""
    }

    func setDeviceName(_ name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        try await send(try request("POST", "/name", body: body))
    }

    func transport() async throws -> String {
        let data = try await send(request("GET", "/transport"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["type"] as? String ?? "unknown"
    }

    func wifiState() async throws -> String {
        let data = try await send(request("GET", "/wifi/status"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["state"] as? String ?? "unknown"
    }

    // MARK: - Audio

    func playSound(stockPath: String) async throws {
        let payload: [String: Any] = [
            "application_name": Self.appName,
            "stock_path": stockPath,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await send(try request("POST", "/audio/play", body: body))
    }

    // MARK: - Firmware updates

    func startUpdateCheck() async throws {
        try await send(try request("POST", "/update/check"))
    }

    func updateStatus() async throws -> UpdateStatus {
        let data = try await send(request("GET", "/update/status"))
        return try JSONDecoder().decode(UpdateStatus.self, from: data)
    }

    // MARK: - Assets

    func uploadAsset(filename: String, data: Data) async throws {
        let req = try request(
            "POST", "/assets/upload",
            query: Self.assetQuery(filename: filename),
            body: data,
            contentType: "application/octet-stream"
        )
        try await send(req)
    }
}
