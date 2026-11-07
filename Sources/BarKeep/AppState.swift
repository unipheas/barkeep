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

    private var connection: DeviceConnection
    private let defaults: UserDefaults
    private let weatherSession: URLSession
    private let loginItems: LoginItemService
    private let renderMessage: (String, String) -> Data?
    private(set) var connectionRevision = 0
    private var connectionTask: Task<Void, Never>?
    private(set) var isConnecting = false

    var connectionMode: DeviceConnectionMode {
        get { connection.mode }
        set {
            guard connection.mode != newValue else { return }
            connection.mode = newValue
            connectionChanged()
        }
    }
    var wifiHost: String {
        get { connection.wifiHost }
        set {
            connection.wifiHost = newValue
            connection.save(to: defaults)
            if connectionMode == .wifi { connectionChanged(resetBusyOwnership: true) }
        }
    }
    var host: String { connection.host }
    var connectionHelp: String? { connection.configurationHelp }
    var token: String {
        get { connection.password }
        set {
            connection.password = newValue
            connection.save(to: defaults)
            if connectionMode == .wifi { connectionChanged() }
        }
    }
    var autoOnCall: Bool {
        didSet {
            defaults.set(autoOnCall, forKey: "autoOnCall")
            syncAutoBusy()
        }
    }
    var theme: String {
        didSet { defaults.set(theme, forKey: "theme") }
    }
    var triggerSmartHome: Bool {
        didSet { defaults.set(triggerSmartHome, forKey: "triggerSmartHome") }
    }
    /// Seconds the mic must stay idle before "on call" is cleared.
    var offDebounceSeconds: Double {
        didSet { defaults.set(offDebounceSeconds, forKey: "offDebounceSeconds") }
    }
    var forwardNotifications: Bool {
        didSet {
            defaults.set(forwardNotifications, forKey: "forwardNotifications")
            forwardNotifications ? notificationWatcher.start() : notificationWatcher.stop()
        }
    }
    /// Comma-separated bundle-ID substrings to forward; empty forwards everything.
    var notificationAppFilter: String {
        didSet { defaults.set(notificationAppFilter, forKey: "notificationAppFilter") }
    }
    var calendarAutoBusy: Bool {
        didSet {
            defaults.set(calendarAutoBusy, forKey: "calendarAutoBusy")
            if calendarAutoBusy {
                Task {
                    _ = await calendarMonitor.requestAccess()
                    guard calendarAutoBusy else { calendarMonitor.stop(); return }
                    calendarChanged()
                }
            } else {
                calendarMonitor.stop()
                syncAutoBusy()
            }
        }
    }
    /// Play a chime on the bar's speaker when a notification is forwarded.
    var notificationChime: Bool {
        didSet { defaults.set(notificationChime, forKey: "notificationChime") }
    }
    /// Hold notifications that arrive during a call and replay them after.
    var queueDuringCalls: Bool {
        didSet { defaults.set(queueDuringCalls, forKey: "queueDuringCalls") }
    }
    var presets: [MessagePreset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) {
                defaults.set(data, forKey: "presets")
            }
        }
    }
    var slackSyncEnabled: Bool {
        didSet { defaults.set(slackSyncEnabled, forKey: "slackSyncEnabled") }
    }
    var slackToken: String {
        didSet {
            defaults.set(slackToken, forKey: "slackToken")
            slackSync.token = slackToken
        }
    }
    /// Show live network latency in the bar's bottom-right corner.
    var showPing: Bool {
        didSet {
            defaults.set(showPing, forKey: "showPing")
            syncPingLoop()
        }
    }
    /// Show local weather (icon + temperature) on the bar's left side.
    var showWeather: Bool {
        didSet {
            defaults.set(showWeather, forKey: "showWeather")
            syncWeatherLoop()
        }
    }
    var pingHost: String {
        didSet { defaults.set(pingHost, forKey: "pingHost") }
    }
    var weatherCelsius: Bool {
        didSet {
            defaults.set(weatherCelsius, forKey: "weatherCelsius")
            syncWeatherLoop()
        }
    }

    // MARK: - Live state

    private(set) var micInUse = false
    private(set) var activeMicrophoneNames: [String] = []
    private(set) var onCall = false
    private(set) var deviceReachable = false
    private(set) var authenticationRejected = false
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
    private var confirmedBrightnessValue = "auto"
    private var confirmedVolumeValue = 100
    private var brightnessWriteSequence = 0
    private var volumeWriteSequence = 0
    private var brightnessMutationRevision = 0
    private var volumeMutationRevision = 0
    private var brightnessWriteTask: Task<Void, Never>?
    private var volumeWriteTask: Task<Void, Never>?
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
        get { loginItems.isEnabled() }
        set {
            do {
                try loginItems.setEnabled(newValue)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
    var calendarAccessGranted: Bool { calendarMonitor.accessGranted }

    let client: BusyBarClient
    let arcade: ArcadeController
    private let localNetworkPermissionTrigger: LocalNetworkPermissionTrigger
    private let micMonitor: MicMonitor
    private let notificationWatcher: NotificationWatcher
    private let calendarMonitor: CalendarMonitor
    private let slackSync: SlackSync
    private var offDebounceTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private(set) var latestPingMs: Double?
    private var weatherTask: Task<Void, Never>?
    private(set) var latestWeather: WeatherReading?
    private(set) var widgetsPausedForApp = false
    private var launchedDeviceAppID: String?
    private var lastWeatherIconEmoji: String?
    private var queuedNotifications: [String] = []
    private var notificationReplayTask: Task<Void, Never>?
    /// True when this app started the busy session (so we only clear our own).
    private var weSetBusy = false
    private var busyWriteTask: Task<Void, Never>?
    private var busyWriteSequence = 0
    private var busyMutationRevision = 0

    private static let ledColors: [(match: String, hex: String)] = [
        ("teams", "#7B83EBFF"),
        ("slack", "#36C5F0FF"),
        ("outlook", "#0078D4FF"),
        ("mail", "#0078D4FF"),
    ]

    init(
        defaults: UserDefaults = .standard,
        startServices: Bool = true,
        session: URLSession? = nil,
        slackSession: URLSession = .shared,
        weatherSession: URLSession = .shared,
        calendarSource: CalendarSource? = nil,
        localNetworkPermissionTrigger: LocalNetworkPermissionTrigger? = nil,
        micMonitor: MicMonitor? = nil,
        notificationWatcher: NotificationWatcher? = nil,
        arcadeKeyboard: (any ArcadeKeyboardCapturing)? = nil,
        renderMessage: @escaping (String, String) -> Data? = MessageRenderer.renderToPNG,
        loginItems: LoginItemService? = nil
    ) {
        let connection = DeviceConnection(defaults: defaults)
        self.connection = connection
        self.defaults = defaults
        self.weatherSession = weatherSession
        self.renderMessage = renderMessage
        self.loginItems = loginItems ?? .live
        self.calendarMonitor = CalendarMonitor(source: calendarSource)
        self.localNetworkPermissionTrigger = localNetworkPermissionTrigger ?? LocalNetworkPermissionTrigger()
        self.micMonitor = micMonitor ?? MicMonitor()
        self.notificationWatcher = notificationWatcher ?? NotificationWatcher()
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
        self.client = BusyBarClient(host: connection.host, token: connection.token, session: session)
        self.slackSync = SlackSync(session: slackSession)
        self.transportType = connection.mode.rawValue
        self.arcade = ArcadeController(client: self.client, keyboard: arcadeKeyboard, defaults: defaults)
        self.slackSync.token = self.slackToken
        calendarMonitor.onChange = { [weak self] in self?.calendarChanged() }
        guard startServices else { return }
        self.localNetworkPermissionTrigger.onAccessAvailable = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshDeviceStatus()
            }
        }
        self.localNetworkPermissionTrigger.requestAccess()
        syncPingLoop()
        syncWeatherLoop()

        self.micMonitor.onChange = { [weak self] activity in
            Task { @MainActor in self?.micStateChanged(activity) }
        }
        self.micMonitor.start()

        self.notificationWatcher.onNotification = { [weak self] note in
            Task { @MainActor [weak self] in self?.handleNotification(note) }
        }
        self.notificationWatcher.onStatusChange = { [weak self] status in
            Task { @MainActor [weak self] in self?.notificationStatus = status }
        }
        if forwardNotifications { self.notificationWatcher.start() }

        if calendarAutoBusy { calendarMonitor.start() }

        Task { await refreshDeviceStatus() }
    }

    // MARK: - Device status

    private func connectionChanged(resetBusyOwnership: Bool = false) {
        busyWriteTask?.cancel(); busyWriteTask = nil
        if arcade.isActive { arcade.stop() }
        connection.save(to: defaults)
        connectionRevision += 1
        brightnessWriteTask?.cancel(); brightnessWriteTask = nil
        volumeWriteTask?.cancel(); volumeWriteTask = nil
        notificationReplayTask?.cancel()
        notificationReplayTask = nil
        queuedNotifications.removeAll()
        queuedCount = 0
        connectionTask?.cancel()
        // USB and Wi-Fi are two routes to the same bar. Retain ownership of
        // our busy session so a later mic-off can still clear it. Editing the
        // Wi-Fi address may select a different device, so discard ownership.
        if resetBusyOwnership {
            offDebounceTask?.cancel()
            weSetBusy = false
        }
        client.configure(host: connection.host, token: connection.token)
        if widgetsPausedForApp { resumeWidgets() }
        deviceReachable = false
        authenticationRejected = false
        isConnecting = false
        batteryCharge = nil
        firmwareVersion = nil
        screenPreview = nil
        onCall = false
        transportType = connectionMode.rawValue
        wifiStateText = "unknown"
        deviceNameText = ""
        updateCheckText = nil
        lastError = nil
        guard !connection.needsWiFiHost else { return }
        connectionTask = Task { await refreshDeviceStatus() }
    }

    func refreshDeviceStatus() async {
        guard !connection.needsWiFiHost else { return }
        let revision = connectionRevision
        // Snapshot the endpoint so an in-flight refresh cannot mix USB and Wi-Fi
        // responses or overwrite the newly selected connection's state.
        let endpoint = client.snapshot()
        let brightnessRevision = brightnessMutationRevision
        let volumeRevision = volumeMutationRevision
        let busyRevision = busyMutationRevision
        isConnecting = true
        defer { if revision == connectionRevision { isConnecting = false } }
        do {
            let status = try await endpoint.status()
            guard revision == connectionRevision, !Task.isCancelled else { return }
            deviceReachable = true
            authenticationRejected = false
            batteryCharge = status.power.battery_charge
            firmwareVersion = status.firmware.version
            let busyType = try await endpoint.currentBusyType()
            guard revision == connectionRevision, !Task.isCancelled else { return }
            if busyRevision == busyMutationRevision {
                onCall = busyType != "NOT_STARTED"
            }
            if onCall, arcade.isActive { arcade.stop() }
            let themes = try? await endpoint.listThemes()
            let brightness = try? await endpoint.brightness()
            let volume = try? await endpoint.volume()
            let wifiState = try? await endpoint.wifiState()
            let name = try? await endpoint.deviceName()
            guard revision == connectionRevision, !Task.isCancelled else { return }
            if let themes, !themes.isEmpty { availableThemes = themes }
            if let brightness, brightnessRevision == brightnessMutationRevision, brightnessWriteTask == nil {
                brightnessValue = brightness; confirmedBrightnessValue = brightness
            }
            if let volume, volumeRevision == volumeMutationRevision, volumeWriteTask == nil {
                volumeValue = volume; confirmedVolumeValue = volume
            }
            if let wifiState { wifiStateText = wifiState }
            if let name { deviceNameText = name }
        } catch {
            guard revision == connectionRevision, !Task.isCancelled else { return }
            deviceReachable = false
            authenticationRejected = Self.isAuthenticationError(error)
            batteryCharge = nil
            screenPreview = nil
            firmwareVersion = nil
            if arcade.isActive { arcade.stop() }
        }
    }

    nonisolated static func configuredTransport(for host: String) -> String {
        BusyBarClient.normalizedHost(host) == "10.0.4.20"
            ? "usb"
            : "wifi"
    }

    nonisolated static func isAuthenticationError(_ error: Error) -> Bool {
        (error as? BusyBarError)?.statusCode == 403
    }

    /// Runs while the popover is visible; keeps the live preview fresh.
    func previewLoop(interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            let revision = connectionRevision
            let endpoint = client.snapshot()
            if !connection.needsWiFiHost {
                do {
                    let frame = try await endpoint.screenFrame()
                    guard revision == connectionRevision, !Task.isCancelled else { continue }
                    screenPreview = Self.cgImage(from: frame)
                    deviceReachable = true
                    authenticationRejected = false
                } catch {
                    guard revision == connectionRevision, !Task.isCancelled else { continue }
                    screenPreview = nil
                    deviceReachable = false
                    authenticationRejected = Self.isAuthenticationError(error)
                    batteryCharge = nil
                }
            }
            try? await Task.sleep(for: interval)
        }
    }

    private static func cgImage(from frame: ScreenFrame) -> CGImage? {
        var rgba = Data(capacity: frame.width * frame.height * 4)
        let pixels = frame.bgrPixels
        for i in stride(from: 0, to: frame.width * frame.height * 3, by: 3) {
            rgba.append(pixels[pixels.startIndex + i + 2]) // R (stream is BGR)
            rgba.append(pixels[pixels.startIndex + i + 1]) // G
            rgba.append(pixels[pixels.startIndex + i])     // B
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

    @discardableResult
    func applyBrightness(_ value: String) -> Task<Void, Never> {
        let revision = connectionRevision
        let endpoint = client.snapshot()
        brightnessWriteSequence += 1
        brightnessMutationRevision += 1
        let sequence = brightnessWriteSequence
        let previousTask = brightnessWriteTask
        brightnessValue = value
        let task = Task {
            // Serialize writes and skip superseded selections that have not started.
            await previousTask?.value
            defer {
                brightnessMutationRevision += 1
                if sequence == brightnessWriteSequence { brightnessWriteTask = nil }
            }
            guard revision == connectionRevision, sequence == brightnessWriteSequence, !Task.isCancelled else { return }
            do {
                try await endpoint.setBrightness(value)
                guard revision == connectionRevision, !Task.isCancelled else { return }
                confirmedBrightnessValue = value
                guard sequence == brightnessWriteSequence else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision, sequence == brightnessWriteSequence, !Task.isCancelled else { return }
                brightnessValue = confirmedBrightnessValue
                lastError = error.localizedDescription
            }
        }
        brightnessWriteTask = task
        return task
    }

    @discardableResult
    func applyVolume(_ value: Int) -> Task<Void, Never> {
        let revision = connectionRevision
        let endpoint = client.snapshot()
        volumeWriteSequence += 1
        volumeMutationRevision += 1
        let sequence = volumeWriteSequence
        let previousTask = volumeWriteTask
        volumeValue = value
        let task = Task {
            // Serialize writes and skip superseded selections that have not started.
            await previousTask?.value
            defer {
                volumeMutationRevision += 1
                if sequence == volumeWriteSequence { volumeWriteTask = nil }
            }
            guard revision == connectionRevision, sequence == volumeWriteSequence, !Task.isCancelled else { return }
            do {
                try await endpoint.setVolume(value)
                guard revision == connectionRevision, !Task.isCancelled else { return }
                confirmedVolumeValue = value
                guard sequence == volumeWriteSequence else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision, sequence == volumeWriteSequence, !Task.isCancelled else { return }
                volumeValue = confirmedVolumeValue
                lastError = error.localizedDescription
            }
        }
        volumeWriteTask = task
        return task
    }

    func applyDeviceName() {
        let revision = connectionRevision
        let endpoint = client.snapshot()
        let name = deviceNameText
        Task {
            do {
                try await endpoint.setDeviceName(name)
                guard revision == connectionRevision else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision else { return }
                lastError = error.localizedDescription
            }
        }
    }

    func checkForUpdate(pollInterval: Duration = .seconds(2)) {
        let revision = connectionRevision
        let endpoint = client.snapshot()
        updateCheckText = "Checking…"
        Task {
            do {
                try await endpoint.startUpdateCheck()
                for _ in 0..<15 {
                    try await Task.sleep(for: pollInterval)
                    let status = try await endpoint.updateStatus()
                    guard revision == connectionRevision else { return }
                    switch status.check.status {
                    case "available", "not_available", "ok", "success":
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
                guard revision == connectionRevision else { return }
                updateCheckText = "Check timed out"
            } catch {
                guard revision == connectionRevision else { return }
                updateCheckText = "Check failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Timers

    @discardableResult
    func startPomodoro(workMinutes: Int, restMinutes: Int, cycles: Int) -> Task<Void, Never> {
        enqueueBusyWrite { [self] endpoint, revision in
            do {
                await arcade.stopAndWait()
                try await endpoint.startIntervalSession(
                    workMinutes: workMinutes, restMinutes: restMinutes, cycles: cycles,
                    theme: theme, triggerSmartHome: triggerSmartHome
                )
                guard revision == connectionRevision else { return }
                onCall = true
                weSetBusy = true
                lastError = nil
                if slackSyncEnabled { lastError = await slackSync.setBusy(true) }
            } catch {
                guard revision == connectionRevision else { return }
                lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func startSimpleTimer(minutes: Int) -> Task<Void, Never> {
        enqueueBusyWrite { [self] endpoint, revision in
            do {
                await arcade.stopAndWait()
                try await endpoint.startSimpleSession(minutes: minutes, theme: theme, triggerSmartHome: triggerSmartHome)
                guard revision == connectionRevision else { return }
                onCall = true
                weSetBusy = true
                lastError = nil
                if slackSyncEnabled { lastError = await slackSync.setBusy(true) }
            } catch {
                guard revision == connectionRevision else { return }
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Ping badge

    /// Device apps own their display. Pause our recurring overlays until Stop or
    /// Resume Widgets, without changing the user's saved widget preferences.
    func launchDeviceApp(_ app: DeviceApp, on endpoint: BusyBarClient) async throws {
        _ = try endpoint.appQuery(app.id)
        let revision = connectionRevision
        let wasPaused = widgetsPausedForApp
        widgetsPausedForApp = true
        pingTask?.cancel()
        weatherTask?.cancel()
        await pingTask?.value
        await weatherTask?.value
        await arcade.stopAndWait()
        do {
            guard revision == connectionRevision else { throw BusyBarError(message: "Device changed. Launch the app again.") }
            try await endpoint.clearDisplay()
            try await endpoint.launchApp(id: app.id)
            if revision == connectionRevision { launchedDeviceAppID = app.id }
        } catch {
            if revision == connectionRevision, !wasPaused { resumeWidgets() }
            throw error
        }
    }

    func resumeWidgets() {
        widgetsPausedForApp = false
        launchedDeviceAppID = nil
        if showPing { syncPingLoop() }
        if showWeather { syncWeatherLoop() }
    }

    func deviceAppRemoved(_ app: DeviceApp) {
        if launchedDeviceAppID == app.id { resumeWidgets() }
    }

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
                if !Task.isCancelled && !self.onCall && !self.arcade.isActive && !self.widgetsPausedForApp {
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
        defaults.string(forKey: "weatherCity") ?? "Automatic (IP-based)"
    }

    /// Empty query reverts to automatic IP-based location; otherwise the
    /// city name is geocoded and pinned.
    func applyWeatherLocation(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let defaults = defaults
        if trimmed.isEmpty {
            defaults.removeObject(forKey: "weatherLat")
            defaults.removeObject(forKey: "weatherLon")
            defaults.removeObject(forKey: "weatherCity")
            syncWeatherLoop()
            return
        }
        Task {
            guard let place = await WeatherMonitor.geocode(trimmed, session: weatherSession) else {
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
                    if let reading = await WeatherMonitor.fetch(defaults: self.defaults, session: self.weatherSession) {
                        self.latestWeather = reading
                        lastFetch = Date()
                    }
                }
                if let reading = self.latestWeather, !self.onCall, !self.arcade.isActive, !self.widgetsPausedForApp {
                    var iconOK = self.lastWeatherIconEmoji == reading.emoji
                    if !iconOK, let png = MessageRenderer.renderEmojiIcon(reading.emoji) {
                        iconOK = (try? await self.client.uploadAsset(filename: "wx.png", data: png)) != nil
                        if iconOK { self.lastWeatherIconEmoji = reading.emoji }
                    }
                    if !Task.isCancelled, !self.widgetsPausedForApp {
                        try? await self.client.drawWeatherBadge(iconUploaded: iconOK, tempText: reading.tempText)
                    }
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
        guard !arcade.isActive else {
            lastError = "Stop the arcade before drawing another item."
            return
        }
        let endpoint = client.snapshot()
        let revision = connectionRevision
        Task {
            do {
                try await endpoint.drawCountdown(to: date, colorHex: "#FFAA00FF", timeout: 0, priority: 95)
                guard revision == connectionRevision else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision else { return }
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - On-call logic

    @discardableResult
    func micStateChanged(_ activity: MicMonitor.Activity) -> Task<Void, Never>? {
        micInUse = activity.isInUse
        activeMicrophoneNames = activity.deviceNames
        guard autoOnCall else { return nil }
        return syncAutoBusy()
    }

    private var wantAutoBusy: Bool {
        (autoOnCall && micInUse) || (calendarAutoBusy && inMeeting)
    }

    @discardableResult
    private func syncAutoBusy() -> Task<Void, Never>? {
        offDebounceTask?.cancel()
        if wantAutoBusy {
            return setOnCall(true, automatic: true)
        } else if weSetBusy {
            let delay = offDebounceSeconds
            offDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, !self.wantAutoBusy else { return }
                await self.setOnCall(false, automatic: true).value
            }
            return offDebounceTask
        }
        return nil
    }

    private func enqueueBusyWrite(_ operation: @escaping @MainActor (BusyBarClient, Int) async -> Void) -> Task<Void, Never> {
        let revision = connectionRevision
        let endpoint = client.snapshot()
        let previous = busyWriteTask
        busyWriteSequence += 1
        busyMutationRevision += 1
        let sequence = busyWriteSequence
        let task = Task {
            // Finish each device + Slack transition before the next one starts.
            // Otherwise a slow call-start response can overtake a call end.
            await previous?.value
            defer {
                busyMutationRevision += 1
                if sequence == busyWriteSequence { busyWriteTask = nil }
            }
            guard !Task.isCancelled, revision == connectionRevision else { return }
            await operation(endpoint, revision)
        }
        busyWriteTask = task
        return task
    }

    @discardableResult
    func setOnCall(_ on: Bool, automatic: Bool = false) -> Task<Void, Never> {
        enqueueBusyWrite { [self] endpoint, revision in
            do {
                if on, arcade.isActive {
                    arcade.stop()
                }
                if on && automatic {
                    // Don't stomp a busy session the user started elsewhere.
                    let current = try await endpoint.currentBusyType()
                    guard revision == connectionRevision else { return }
                    guard wantAutoBusy else { return }
                    if current != "NOT_STARTED" && !weSetBusy {
                        onCall = true
                        return
                    }
                }
                try await endpoint.setBusy(on, theme: theme, triggerSmartHome: triggerSmartHome)
                guard revision == connectionRevision else { return }
                onCall = on
                weSetBusy = on
                deviceReachable = true
                lastError = nil
                // The microphone may have gone idle while the write was in
                // flight, before we owned the new session. Schedule its clear now.
                if on && automatic && !wantAutoBusy { syncAutoBusy() }
                if !on { flushQueuedNotifications() }
                if slackSyncEnabled {
                    if let slackError = await slackSync.setBusy(on) {
                        lastError = slackError
                    }
                }
            } catch {
                guard revision == connectionRevision else { return }
                let failure = error.localizedDescription
                await refreshDeviceStatus()
                guard revision == connectionRevision else { return }
                lastError = failure
            }
        }
    }

    // MARK: - Notification forwarding

    func handleNotification(_ note: ForwardedNotification) {
        guard !arcade.isActive else { return }
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
        let endpoint = client.snapshot()
        let revision = connectionRevision
        Task {
            do {
                try await endpoint.drawText(ascii, font: .normal, colorHex: "#FFFFFFFF", timeout: 20, priority: 95, ledColor: ledColor)
                guard revision == connectionRevision else { return }
                if chime {
                    try? await endpoint.playSound(stockPath: "shared/calendar_event_starts.snd")
                }
                guard revision == connectionRevision else { return }
                log.info("notification drawn on bar (\(ascii.count) chars)")
                lastError = nil
            } catch {
                guard revision == connectionRevision else { return }
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
        notificationReplayTask?.cancel()
        let endpoint = client.snapshot()
        let revision = connectionRevision
        notificationReplayTask = Task { [weak self] in
            for (index, text) in queued.enumerated() {
                guard let self, !Task.isCancelled, revision == self.connectionRevision else { return }
                if self.onCall {
                    self.queuedNotifications = Array((Array(queued[index...]) + self.queuedNotifications).suffix(5))
                    self.queuedCount = self.queuedNotifications.count
                    return
                }
                let label = queued.count > 1 ? "[\(index + 1)/\(queued.count)] \(text)" : text
                try? await endpoint.drawText(label, font: .normal, colorHex: "#FFFFFFFF", timeout: 12, priority: 95, ledColor: "#FFFFFFFF")
                if index < queued.count - 1 {
                    try? await Task.sleep(for: .seconds(13))
                }
            }
        }
    }

    static func asciiFold(_ text: String, transform: (String) -> String? = {
        $0.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false)
    }) -> String {
        let transformed = transform(text) ?? text
        let filtered = transformed.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value <= 0x7E }
        return String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Messages

    func sendMessage(_ text: String, font: TextFont, color: NSColor, timeoutSeconds: Int) {
        guard !arcade.isActive else {
            lastError = "Stop the arcade before sending a message."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let hex = MessageRenderer.rgbaHex(from: color)
        let revision = connectionRevision
        let endpoint = client.snapshot()
        Task {
            do {
                if MessageRenderer.isPlainASCII(trimmed) {
                    try await endpoint.drawText(trimmed, font: font, colorHex: hex, timeout: timeoutSeconds, priority: 95)
                } else {
                    guard let png = renderMessage(trimmed, hex) else {
                        throw BusyBarError(message: "Could not render message image")
                    }
                    try await endpoint.uploadAsset(filename: "message.png", data: png)
                    try await endpoint.drawImage(named: "message.png", timeout: timeoutSeconds, priority: 95)
                }
                guard revision == connectionRevision else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision else { return }
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
        guard !arcade.isActive else {
            lastError = "Stop the arcade before sending a drawing."
            return
        }
        let revision = connectionRevision
        let endpoint = client.snapshot()
        Task {
            do {
                guard let png = MessageRenderer.renderGridToPNG(grid) else {
                    throw BusyBarError(message: "Could not encode drawing")
                }
                try await endpoint.uploadAsset(filename: "canvas.png", data: png)
                try await endpoint.drawImage(named: "canvas.png", timeout: timeoutSeconds, priority: 95)
                guard revision == connectionRevision else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision else { return }
                lastError = error.localizedDescription
            }
        }
    }

    func clearDisplay() {
        let revision = connectionRevision
        let endpoint = client.snapshot()
        Task {
            do {
                try await endpoint.clearDisplay()
                guard revision == connectionRevision else { return }
                lastError = nil
            } catch {
                guard revision == connectionRevision else { return }
                lastError = error.localizedDescription
            }
        }
    }
}
