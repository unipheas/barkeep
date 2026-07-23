import SwiftUI
import Observation
import ServiceManagement
import CoreGraphics
import os

private let log = Logger(subsystem: "dev.barkeep.mac", category: "app")

struct MessagePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var font: String
    var colorHex: String
}

@Observable
@MainActor
final class AppState {
    // MARK: - Settings (persisted)

    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "host"); client.host = host }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token"); client.token = token }
    }
    var autoOnCall: Bool {
        didSet {
            UserDefaults.standard.set(autoOnCall, forKey: "autoOnCall")
            syncAutoBusy()
        }
    }
    var theme: String {
        didSet { UserDefaults.standard.set(theme, forKey: "theme") }
    }
    var triggerSmartHome: Bool {
        didSet { UserDefaults.standard.set(triggerSmartHome, forKey: "triggerSmartHome") }
    }
    /// Seconds the mic must stay idle before "on call" is cleared.
    var offDebounceSeconds: Double {
        didSet { UserDefaults.standard.set(offDebounceSeconds, forKey: "offDebounceSeconds") }
    }
    var forwardNotifications: Bool {
        didSet {
            UserDefaults.standard.set(forwardNotifications, forKey: "forwardNotifications")
            forwardNotifications ? notificationWatcher.start() : notificationWatcher.stop()
        }
    }
    /// Comma-separated bundle-ID substrings to forward; empty forwards everything.
    var notificationAppFilter: String {
        didSet { UserDefaults.standard.set(notificationAppFilter, forKey: "notificationAppFilter") }
    }
    var calendarAutoBusy: Bool {
        didSet {
            UserDefaults.standard.set(calendarAutoBusy, forKey: "calendarAutoBusy")
            if calendarAutoBusy {
                Task {
                    _ = await calendarMonitor.requestAccess()
                    calendarChanged()
                }
            } else {
                syncAutoBusy()
            }
        }
    }
    /// Play a chime on the bar's speaker when a notification is forwarded.
    var notificationChime: Bool {
        didSet { UserDefaults.standard.set(notificationChime, forKey: "notificationChime") }
    }
    /// Hold notifications that arrive during a call and replay them after.
    var queueDuringCalls: Bool {
        didSet { UserDefaults.standard.set(queueDuringCalls, forKey: "queueDuringCalls") }
    }
    var presets: [MessagePreset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.set(data, forKey: "presets")
            }
        }
    }
    var slackSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(slackSyncEnabled, forKey: "slackSyncEnabled") }
    }
    var slackToken: String {
        didSet {
            UserDefaults.standard.set(slackToken, forKey: "slackToken")
            slackSync.token = slackToken
        }
    }
    /// Show live network latency in the bar's bottom-right corner.
    var showPing: Bool {
        didSet {
            UserDefaults.standard.set(showPing, forKey: "showPing")
            syncPingLoop()
        }
    }
    /// Show local weather (icon + temperature) on the bar's left side.
    var showWeather: Bool {
        didSet {
            UserDefaults.standard.set(showWeather, forKey: "showWeather")
            syncWeatherLoop()
        }
    }
    var pingHost: String {
        didSet { UserDefaults.standard.set(pingHost, forKey: "pingHost") }
    }
    var weatherCelsius: Bool {
        didSet {
            UserDefaults.standard.set(weatherCelsius, forKey: "weatherCelsius")
            syncWeatherLoop()
        }
    }

    // MARK: - Live state

    private(set) var micInUse = false
    private(set) var onCall = false
    private(set) var deviceReachable = false
    private(set) var batteryCharge: Int?
    private(set) var firmwareVersion: String?
    private(set) var availableThemes = [
        "busy", "back_soon", "booked", "chill_time", "coding", "dnd", "flow",
        "keep_out", "low_social_battery", "lunch", "meeting", "on_air", "on_call",
    ]
    var lastError: String?

    private(set) var notificationStatus: NotificationWatcher.Status = .stopped
    private(set) var brightnessValue = "auto"
    private(set) var volumeValue = 100
    private(set) var transportType = "usb"
    private(set) var wifiStateText = "unknown"
    var deviceNameText = ""
    private(set) var updateCheckText: String?
    private(set) var screenPreview: CGImage?
    private(set) var queuedCount = 0
    private(set) var inMeeting = false
    private(set) var nextMeetingTitle: String?
    private(set) var nextMeetingDate: Date?
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
    var calendarAccessGranted: Bool { calendarMonitor.accessGranted }

    let client: BusyBarClient
    private let micMonitor = MicMonitor()
    private let notificationWatcher = NotificationWatcher()
    private let calendarMonitor = CalendarMonitor()
    private let slackSync = SlackSync()
    private var offDebounceTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private(set) var latestPingMs: Double?
    private var weatherTask: Task<Void, Never>?
    private(set) var latestWeather: WeatherReading?
    private var lastWeatherIconEmoji: String?
    private var queuedNotifications: [String] = []
    /// True when this app started the busy session (so we only clear our own).
    private var weSetBusy = false

    private static let ledColors: [(match: String, hex: String)] = [
        ("teams", "#7B83EBFF"),
        ("slack", "#36C5F0FF"),
        ("outlook", "#0078D4FF"),
        ("mail", "#0078D4FF"),
    ]

    init() {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "host") ?? "10.0.4.20"
        let token = defaults.string(forKey: "token") ?? ""
        self.host = host
        self.token = token
        self.autoOnCall = defaults.object(forKey: "autoOnCall") as? Bool ?? true
        self.theme = defaults.string(forKey: "theme") ?? "on_air"
        self.triggerSmartHome = defaults.object(forKey: "triggerSmartHome") as? Bool ?? true
        self.offDebounceSeconds = defaults.object(forKey: "offDebounceSeconds") as? Double ?? 3
        self.forwardNotifications = defaults.object(forKey: "forwardNotifications") as? Bool ?? false
        self.notificationAppFilter = defaults.string(forKey: "notificationAppFilter")
            ?? "com.microsoft.teams2, com.microsoft.teams"
        self.calendarAutoBusy = defaults.object(forKey: "calendarAutoBusy") as? Bool ?? false
        self.notificationChime = defaults.object(forKey: "notificationChime") as? Bool ?? false
        self.queueDuringCalls = defaults.object(forKey: "queueDuringCalls") as? Bool ?? true
        if let data = defaults.data(forKey: "presets"),
           let saved = try? JSONDecoder().decode([MessagePreset].self, from: data) {
            self.presets = saved
        } else {
            self.presets = [
                MessagePreset(text: "Come in!", font: "normal", colorHex: "#00FF66FF"),
                MessagePreset(text: "5 more minutes", font: "normal", colorHex: "#FFCC00FF"),
                MessagePreset(text: "Lunch time", font: "normal", colorHex: "#FF8800FF"),
            ]
        }
        self.slackSyncEnabled = defaults.object(forKey: "slackSyncEnabled") as? Bool ?? false
        self.slackToken = defaults.string(forKey: "slackToken") ?? ""
        self.showPing = defaults.object(forKey: "showPing") as? Bool ?? false
        self.showWeather = defaults.object(forKey: "showWeather") as? Bool ?? false
        self.pingHost = defaults.string(forKey: "pingHost") ?? "1.1.1.1"
        self.weatherCelsius = defaults.bool(forKey: "weatherCelsius")
        self.client = BusyBarClient(host: host, token: token)
        slackSync.token = self.slackToken
        syncPingLoop()
        syncWeatherLoop()

        micMonitor.onChange = { [weak self] inUse in
            Task { @MainActor in self?.micStateChanged(inUse) }
        }
        micMonitor.start()

        notificationWatcher.onNotification = { [weak self] note in
            Task { @MainActor [weak self] in self?.handleNotification(note) }
        }
        notificationWatcher.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in self?.notificationStatus = status }
        }
        if forwardNotifications { notificationWatcher.start() }

        calendarMonitor.onChange = { [weak self] in self?.calendarChanged() }
        if calendarAutoBusy { calendarMonitor.start() }

        Task { await refreshDeviceStatus() }
    }

    // MARK: - Device status

    func refreshDeviceStatus() async {
        do {
            let status = try await client.status()
            deviceReachable = true
            batteryCharge = status.power.battery_charge
            firmwareVersion = status.firmware.version
            let busyType = try await client.currentBusyType()
            onCall = busyType != "NOT_STARTED"
            if let themes = try? await client.listThemes(), !themes.isEmpty {
                availableThemes = themes
            }
            if let value = try? await client.brightness() { brightnessValue = value }
            if let value = try? await client.volume() { volumeValue = value }
            if let value = try? await client.transport() { transportType = value }
            if let value = try? await client.wifiState() { wifiStateText = value }
            if let value = try? await client.deviceName() { deviceNameText = value }
        } catch {
            deviceReachable = false
            batteryCharge = nil
        }
    }

    /// Runs while the popover is visible; keeps the live preview fresh.
    func previewLoop() async {
        while !Task.isCancelled {
            if let frame = try? await client.screenFrame() {
                screenPreview = Self.cgImage(from: frame)
                deviceReachable = true
            } else {
                screenPreview = nil
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func cgImage(from frame: ScreenFrame) -> CGImage? {
        var rgba = Data(capacity: frame.width * frame.height * 4)
        let pixels = frame.grbPixels
        for i in stride(from: 0, to: frame.width * frame.height * 3, by: 3) {
            rgba.append(pixels[pixels.startIndex + i + 1]) // R (stream is GRB)
            rgba.append(pixels[pixels.startIndex + i])     // G
            rgba.append(pixels[pixels.startIndex + i + 2]) // B
            rgba.append(0xFF)
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: frame.width, height: frame.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Device controls

    func applyBrightness(_ value: String) {
        brightnessValue = value
        Task {
            do { try await client.setBrightness(value); lastError = nil }
            catch { lastError = error.localizedDescription }
        }
    }

    func applyVolume(_ value: Int) {
        volumeValue = value
        Task {
            do { try await client.setVolume(value); lastError = nil }
            catch { lastError = error.localizedDescription }
        }
    }

    func applyDeviceName() {
        Task {
            do { try await client.setDeviceName(deviceNameText); lastError = nil }
            catch { lastError = error.localizedDescription }
        }
    }

    func checkForUpdate() {
        updateCheckText = "Checking…"
        Task {
            do {
                try await client.startUpdateCheck()
                for _ in 0..<15 {
                    try await Task.sleep(for: .seconds(2))
                    let status = try await client.updateStatus()
                    switch status.check.status {
                    case "ok", "success":
                        updateCheckText = status.check.available_version.isEmpty
                            ? "Up to date (\(firmwareVersion ?? "?"))"
                            : "Update available: \(status.check.available_version)"
                        return
                    case "failure":
                        updateCheckText = "Check failed — bar needs internet (Wi-Fi)"
                        return
                    default:
                        continue
                    }
                }
                updateCheckText = "Check timed out"
            } catch {
                updateCheckText = "Check failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Timers

    func startPomodoro(workMinutes: Int, restMinutes: Int, cycles: Int) {
        Task {
            do {
                try await client.startIntervalSession(
                    workMinutes: workMinutes, restMinutes: restMinutes, cycles: cycles,
                    theme: theme, triggerSmartHome: triggerSmartHome
                )
                onCall = true
                weSetBusy = true
                lastError = nil
                if slackSyncEnabled { _ = await slackSync.setBusy(true) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func startSimpleTimer(minutes: Int) {
        Task {
            do {
                try await client.startSimpleSession(minutes: minutes, theme: theme, triggerSmartHome: triggerSmartHome)
                onCall = true
                weSetBusy = true
                lastError = nil
                if slackSyncEnabled { _ = await slackSync.setBusy(true) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Ping badge

    private func syncPingLoop() {
        pingTask?.cancel()
        pingTask = nil
        latestPingMs = nil
        guard showPing else {
            Task { try? await client.expireElements([.text(id: "ping")]) }
            return
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ms = await PingMonitor.measure(host: self.pingHost)
                self.latestPingMs = ms
                // The badge self-expires (10 s timeout), so a stopped loop
                // or an active busy session just lets it fade out.
                if !self.onCall {
                    let text: String
                    let color: String
                    if let ms {
                        text = "\(Int(ms.rounded()))ms"
                        color = ms < 40 ? "#34C759FF" : ms < 100 ? "#FFD60AFF" : "#FF3B30FF"
                    } else {
                        text = "x"
                        color = "#FF3B30FF"
                    }
                    try? await self.client.drawPingBadge(text: text, colorHex: color)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Weather badge

    /// Human-readable current weather location for the settings UI.
    var weatherLocationLabel: String {
        UserDefaults.standard.string(forKey: "weatherCity") ?? "Automatic (IP-based)"
    }

    /// Empty query reverts to automatic IP-based location; otherwise the
    /// city name is geocoded and pinned.
    func applyWeatherLocation(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let defaults = UserDefaults.standard
        if trimmed.isEmpty {
            defaults.removeObject(forKey: "weatherLat")
            defaults.removeObject(forKey: "weatherLon")
            defaults.removeObject(forKey: "weatherCity")
            syncWeatherLoop()
            return
        }
        Task {
            guard let place = await WeatherMonitor.geocode(trimmed) else {
                lastError = "Could not find “\(trimmed)”"
                return
            }
            defaults.set(place.lat, forKey: "weatherLat")
            defaults.set(place.lon, forKey: "weatherLon")
            defaults.set(place.city, forKey: "weatherCity")
            lastError = nil
            syncWeatherLoop()
        }
    }

    private func syncWeatherLoop() {
        weatherTask?.cancel()
        weatherTask = nil
        guard showWeather else {
            latestWeather = nil
            let hadIcon = lastWeatherIconEmoji != nil
            lastWeatherIconEmoji = nil
            Task { [client] in
                var items: [BusyBarClient.ExpirableElement] = [.text(id: "wx_temp")]
                if hadIcon { items.append(.image(id: "wx_icon", path: "wx.png")) }
                try? await client.expireElements(items)
            }
            return
        }
        weatherTask = Task { [weak self] in
            var lastFetch = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                // Re-fetch every 10 min; redraw every 60 s to keep the
                // elements alive (150 s timeout lets them fade if we stop).
                if Date().timeIntervalSince(lastFetch) > 600 {
                    if let reading = await WeatherMonitor.fetch() {
                        self.latestWeather = reading
                        lastFetch = Date()
                    }
                }
                if let reading = self.latestWeather, !self.onCall {
                    var iconOK = self.lastWeatherIconEmoji == reading.emoji
                    if !iconOK, let png = MessageRenderer.renderEmojiIcon(reading.emoji) {
                        iconOK = (try? await self.client.uploadAsset(filename: "wx.png", data: png)) != nil
                        if iconOK { self.lastWeatherIconEmoji = reading.emoji }
                    }
                    try? await self.client.drawWeatherBadge(iconUploaded: iconOK, tempText: reading.tempText)
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: - Calendar

    private func calendarChanged() {
        inMeeting = calendarMonitor.currentEvent != nil
        nextMeetingTitle = calendarMonitor.nextEvent?.title
        nextMeetingDate = calendarMonitor.nextEvent?.startDate
        if calendarAutoBusy { syncAutoBusy() }
    }

    func sendMeetingCountdown() {
        guard let date = nextMeetingDate else { return }
        Task {
            do {
                try await client.drawCountdown(to: date, colorHex: "#FFAA00FF", timeout: 0, priority: 95)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - On-call logic

    private func micStateChanged(_ inUse: Bool) {
        micInUse = inUse
        guard autoOnCall else { return }
        syncAutoBusy()
    }

    private var wantAutoBusy: Bool {
        (autoOnCall && micInUse) || (calendarAutoBusy && inMeeting)
    }

    private func syncAutoBusy() {
        offDebounceTask?.cancel()
        if wantAutoBusy {
            setOnCall(true, automatic: true)
        } else if weSetBusy {
            let delay = offDebounceSeconds
            offDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, !self.wantAutoBusy else { return }
                self.setOnCall(false, automatic: true)
            }
        }
    }

    func setOnCall(_ on: Bool, automatic: Bool = false) {
        Task {
            do {
                if on && automatic {
                    // Don't stomp a busy session the user started elsewhere.
                    let current = try await client.currentBusyType()
                    if current != "NOT_STARTED" && !weSetBusy {
                        onCall = true
                        return
                    }
                }
                try await client.setBusy(on, theme: theme, triggerSmartHome: triggerSmartHome)
                onCall = on
                weSetBusy = on
                deviceReachable = true
                lastError = nil
                if !on { flushQueuedNotifications() }
                if slackSyncEnabled {
                    if let slackError = await slackSync.setBusy(on) {
                        lastError = slackError
                    }
                }
            } catch {
                lastError = error.localizedDescription
                await refreshDeviceStatus()
            }
        }
    }

    // MARK: - Notification forwarding

    private func handleNotification(_ note: ForwardedNotification) {
        let filters = notificationAppFilter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if !filters.isEmpty {
            let bundle = note.bundleID.lowercased()
            guard filters.contains(where: { bundle.contains($0) }) else {
                log.info("skipping notification from \(note.bundleID, privacy: .public) (not in filter)")
                return
            }
        }
        let text = [note.title, note.body]
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
        // Scrolling text beats a 72px static image for notifications, so
        // transliterate unicode (smart quotes, accents, …) down to ASCII.
        let ascii = Self.asciiFold(text)
        guard !ascii.isEmpty else { return }

        guard !onCall else {
            if queueDuringCalls {
                queuedNotifications.append(ascii)
                if queuedNotifications.count > 5 { queuedNotifications.removeFirst() }
                queuedCount = queuedNotifications.count
                log.info("queued notification from \(note.bundleID, privacy: .public) (\(self.queuedCount) queued)")
            } else {
                log.info("suppressing notification from \(note.bundleID, privacy: .public) — busy session active")
            }
            return
        }
        log.info("forwarding notification from \(note.bundleID, privacy: .public)")
        deliverToBar(ascii, bundleID: note.bundleID)
    }

    private func deliverToBar(_ ascii: String, bundleID: String) {
        let bundle = bundleID.lowercased()
        let ledColor = Self.ledColors.first { bundle.contains($0.match) }?.hex ?? "#FFFFFFFF"
        let chime = notificationChime
        Task {
            do {
                try await client.drawText(ascii, font: .normal, colorHex: "#FFFFFFFF", timeout: 20, priority: 95, ledColor: ledColor)
                if chime {
                    try? await client.playSound(stockPath: "shared/calendar_event_starts.snd")
                }
                log.info("notification drawn on bar (\(ascii.count) chars)")
                lastError = nil
            } catch {
                log.error("notification draw failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
            }
        }
    }

    private func flushQueuedNotifications() {
        guard !queuedNotifications.isEmpty else { return }
        let queued = queuedNotifications
        queuedNotifications.removeAll()
        queuedCount = 0
        log.info("flushing \(queued.count) queued notifications")
        Task {
            for (index, text) in queued.enumerated() {
                let label = queued.count > 1 ? "[\(index + 1)/\(queued.count)] \(text)" : text
                try? await client.drawText(label, font: .normal, colorHex: "#FFFFFFFF", timeout: 12, priority: 95, ledColor: "#FFFFFFFF")
                if index < queued.count - 1 {
                    try? await Task.sleep(for: .seconds(13))
                }
            }
        }
    }

    private static func asciiFold(_ text: String) -> String {
        let transformed = text.applyingTransform(
            StringTransform("Any-Latin; Latin-ASCII"), reverse: false
        ) ?? text
        let filtered = transformed.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7E }
        return String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Messages

    func sendMessage(_ text: String, font: TextFont, color: NSColor, timeoutSeconds: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hex = MessageRenderer.rgbaHex(from: color)
        Task {
            do {
                if MessageRenderer.isPlainASCII(trimmed) {
                    try await client.drawText(trimmed, font: font, colorHex: hex, timeout: timeoutSeconds, priority: 95)
                } else {
                    guard let png = MessageRenderer.renderToPNG(trimmed, colorHex: hex) else {
                        throw BusyBarError(message: "Could not render message image")
                    }
                    try await client.uploadAsset(filename: "message.png", data: png)
                    try await client.drawImage(named: "message.png", timeout: timeoutSeconds, priority: 95)
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func sendPreset(_ preset: MessagePreset) {
        let font = TextFont(rawValue: preset.font) ?? .normal
        let color = MessageRenderer.nsColor(fromRGBAHex: preset.colorHex) ?? .white
        sendMessage(preset.text, font: font, color: color, timeoutSeconds: 30)
    }

    func sendDrawing(_ grid: [[String?]], timeoutSeconds: Int) {
        Task {
            do {
                guard let png = MessageRenderer.renderGridToPNG(grid) else {
                    throw BusyBarError(message: "Could not encode drawing")
                }
                try await client.uploadAsset(filename: "canvas.png", data: png)
                try await client.drawImage(named: "canvas.png", timeout: timeoutSeconds, priority: 95)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearDisplay() {
        Task {
            do {
                try await client.clearDisplay()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
