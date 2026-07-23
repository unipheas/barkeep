import SwiftUI

@MainActor
struct MenuView: View {
    @Environment(AppState.self) private var state
    @State private var tab = 0
    @State private var contentSize = CGSize.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $tab) {
                Text("Device").tag(0)
                Text("Message").tag(1)
                Text("Timers").tag(2)
                Text("Arcade").tag(3)
                Text("Settings").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case 0: DeviceTab()
            case 1: MessageTab()
            case 2: TimersTab()
            case 3: ArcadeTab()
            default: SettingsTab()
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Text("BarKeep v\(AppVersion.current)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MenuContentSizeKey.self,
                    value: geometry.size
                )
            }
        }
        .onPreferenceChange(MenuContentSizeKey.self) { contentSize = $0 }
        .background(MenuBarWindowSizer(contentSize: contentSize))
        .task { await state.refreshDeviceStatus() }
        .task { await state.previewLoop() }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(state.deviceReachable ? .green : .orange)
                .frame(width: 9, height: 9)
            Text(state.deviceReachable ? "Busy Bar" : "Unreachable")
                .font(.headline)
            Text(state.transportType.uppercased())
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Spacer()
            if let battery = state.batteryCharge {
                Label("\(battery)%", systemImage: "battery.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                if let url = URL(string: "http://\(state.host)/") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            .help("Open the bar's web interface (http://\(state.host))")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit BarKeep")
        }
    }
}

// MARK: - Arcade tab

@MainActor
struct ArcadeTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var arcade = state.arcade
        VStack(alignment: .leading, spacing: 10) {
            if state.onCall {
                Text("End the current busy session before starting a game.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if !state.deviceReachable {
                Text("Connect the Busy Bar before starting a game.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if arcade.showPreview, let image = arcade.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(72.0 / 16.0, contentMode: .fit)
                    .padding(4)
                    .background(.black, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }

            ForEach(ArcadeGame.allCases) { game in
                HStack {
                    Text("\(game.number)")
                        .font(.caption.monospaced().bold())
                        .frame(width: 18, height: 18)
                        .foregroundStyle(Color(nsColor: nsColor(game.color)))
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(game.title)
                            .font(.subheadline.bold())
                        Text(game.controls)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(
                        arcade.isActive && arcade.selectedGame == game
                            ? "Restart" : "Play"
                    ) {
                        if arcade.isActive && arcade.selectedGame == game {
                            arcade.restart()
                        } else {
                            arcade.start(game)
                        }
                    }
                    .controlSize(.small)
                    .disabled(state.onCall || !state.deviceReachable)
                }
            }

            Divider()

            if arcade.isActive {
                HStack {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Playing \(arcade.selectedGame.title)")
                        .font(.caption.bold())
                    Spacer()
                    Button("Stop") { arcade.stop() }
                        .controlSize(.small)
                }
                if arcade.controlsCaptured {
                    Text("Keyboard captured · 1–4 switch games · R restarts · Esc stops")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Keyboard controls are paused.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Capture Keyboard") {
                            arcade.captureKeyboard()
                        }
                        .controlSize(.small)
                    }
                }
                Text("\(arcade.framesSent) frames sent · \(arcade.framesDropped) skipped")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("After Play, use the Mac keyboard while watching the Busy Bar. Press Esc to stop and return keyboard focus to your previous app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Show preview in BarKeep", isOn: $arcade.showPreview)
                .toggleStyle(.checkbox)
                .font(.caption)

            if let error = arcade.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func nsColor(_ color: ArcadeColor) -> NSColor {
        NSColor(
            deviceRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}

// MARK: - Device tab

@MainActor
struct DeviceTab: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            preview

            Toggle(isOn: Binding(
                get: { state.onCall },
                set: { state.setOnCall($0) }
            )) {
                Label("On Call / Busy", systemImage: state.onCall ? "microphone.badge.ellipsis.fill" : "microphone.slash")
            }
            .toggleStyle(.switch)

            Toggle("Follow microphone", isOn: $state.autoOnCall)
                .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                Circle()
                    .fill(state.micInUse ? .red : .secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(microphoneStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(microphoneStatus)
                if state.queuedCount > 0 {
                    Spacer()
                    Text("\(state.queuedCount) notification\(state.queuedCount == 1 ? "" : "s") queued")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Toggle("Show ping on bar", isOn: $state.showPing)
                    .toggleStyle(.checkbox)
                Spacer()
                if state.showPing {
                    if let ms = state.latestPingMs {
                        Text("\(Int(ms.rounded())) ms")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(ms < 40 ? .green : ms < 100 ? .yellow : .red)
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Toggle("Show weather on bar", isOn: $state.showWeather)
                    .toggleStyle(.checkbox)
                Spacer()
                if state.showWeather {
                    if let weather = state.latestWeather {
                        Text("\(weather.emoji) \(weather.tempText) · \(weather.city)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            LabeledContent("Brightness") {
                Picker("", selection: Binding(
                    get: { state.brightnessValue },
                    set: { state.applyBrightness($0) }
                )) {
                    Text("Auto").tag("auto")
                    ForEach([10, 25, 50, 75, 100], id: \.self) { value in
                        Text("\(value)%").tag(String(value))
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }

            LabeledContent("Volume") {
                HStack {
                    Slider(value: Binding(
                        get: { Double(state.volumeValue) },
                        set: { state.applyVolume(Int($0)) }
                    ), in: 0...100, step: 10)
                    Text("\(state.volumeValue)%")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var microphoneStatus: String {
        guard state.micInUse else { return "Microphone idle" }
        guard !state.activeMicrophoneNames.isEmpty else { return "Microphone in use" }
        return "In use: \(state.activeMicrophoneNames.joined(separator: ", "))"
    }

    private var preview: some View {
        Group {
            if let frame = state.screenPreview {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(72.0 / 16.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black)
                    .aspectRatio(72.0 / 16.0, contentMode: .fit)
                    .overlay {
                        Text("no signal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .padding(4)
        .background(.black, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

// MARK: - Message tab

@MainActor
struct MessageTab: View {
    @Environment(AppState.self) private var state

    @State private var message = ""
    @State private var font: TextFont = .normal
    @State private var color = Color.white
    @State private var timeoutSeconds = 30
    @State private var showEmojiPicker = false
    @State private var showColorPicker = false
    @State private var emojiSearch = ""

    private static let colors: [(name: String, color: Color)] = [
        ("White", .white), ("Red", .red), ("Orange", .orange),
        ("Yellow", .yellow), ("Green", .green), ("Cyan", .cyan),
        ("Blue", .blue), ("Purple", .purple), ("Pink", .pink),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.onCall {
                Text("Unavailable during a busy session — the bar rejects drawing while one is active.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            composer
                .disabled(state.onCall)
                .opacity(state.onCall ? 0.5 : 1)

            Divider()
            presetsSection
                .disabled(state.onCall)
                .opacity(state.onCall ? 0.5 : 1)

            Divider()
            HStack {
                Button("Drawing Canvas…") {
                    openCanvas()
                }
                Spacer()
                Button("Clear Display") { state.clearDisplay() }
            }
        }
    }

    @Environment(\.openWindow) private var openWindow
    private func openCanvas() {
        openWindow(id: "canvas")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Type a message (emoji OK)…", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button {
                    showEmojiPicker.toggle()
                    showColorPicker = false
                } label: {
                    Text("😀")
                }
                .buttonStyle(.borderless)
                .help("Insert emoji")
                Button {
                    showColorPicker.toggle()
                    showEmojiPicker = false
                } label: {
                    Circle()
                        .fill(color)
                        .stroke(.secondary, lineWidth: 1)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Message color")
            }
            if showColorPicker {
                HStack(spacing: 6) {
                    ForEach(Self.colors, id: \.name) { preset in
                        Button {
                            color = preset.color
                            showColorPicker = false
                        } label: {
                            Circle()
                                .fill(preset.color)
                                .stroke(.secondary, lineWidth: 1)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .help(preset.name)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if showEmojiPicker {
                emojiPicker
            }
            HStack {
                Picker("Font", selection: $font) {
                    ForEach(TextFont.allCases) { font in
                        Text(font.rawValue.replacingOccurrences(of: "_", with: " ")).tag(font)
                    }
                }
                .frame(maxWidth: 120)
                Picker("For", selection: $timeoutSeconds) {
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                    Text("2 min").tag(120)
                    Text("Until cleared").tag(0)
                }
                .frame(maxWidth: 120)
                Spacer()
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .labelsHidden()
            if !MessageRenderer.isPlainASCII(message) && !message.isEmpty {
                Text("Contains emoji/unicode — sent as a rendered image (no scrolling, keep it short).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presetsSection: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.subheadline.bold())
            ForEach(state.presets) { preset in
                HStack {
                    Circle()
                        .fill(Color(MessageRenderer.nsColor(fromRGBAHex: preset.colorHex) ?? .white))
                        .frame(width: 8, height: 8)
                    Text(preset.text).lineLimit(1)
                    Spacer()
                    Button("Send") { state.sendPreset(preset) }
                        .controlSize(.small)
                    Button {
                        state.presets.removeAll { $0.id == preset.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                let trimmed = message.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                state.presets.append(MessagePreset(
                    text: trimmed,
                    font: font.rawValue,
                    colorHex: MessageRenderer.rgbaHex(from: NSColor(color))
                ))
                message = ""
            } label: {
                Label("Save current message as preset", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var emojiPicker: some View {
        VStack(spacing: 6) {
            TextField("Search emoji (e.g. fire, rocket, cat)…", text: $emojiSearch)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            let matches = EmojiCatalog.search(emojiSearch)
            if matches.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 40)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 9), spacing: 2) {
                        ForEach(matches) { emoji in
                            Button {
                                message += emoji.char
                            } label: {
                                Text(emoji.char).font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .help(emoji.name.capitalized)
                        }
                    }
                }
                .frame(height: 150)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func send() {
        state.sendMessage(message, font: font, color: NSColor(color), timeoutSeconds: timeoutSeconds)
        message = ""
    }
}

// MARK: - Timers tab

@MainActor
struct TimersTab: View {
    @Environment(AppState.self) private var state

    @State private var workMinutes = 25
    @State private var restMinutes = 5
    @State private var cycles = 4
    @State private var simpleMinutes = 30

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            Text("Pomodoro").font(.subheadline.bold())
            HStack {
                Stepper("Work \(workMinutes)m", value: $workMinutes, in: 5...90, step: 5)
                Stepper("Rest \(restMinutes)m", value: $restMinutes, in: 1...30)
            }
            .font(.caption)
            HStack {
                Stepper("\(cycles) cycles", value: $cycles, in: 1...10)
                    .font(.caption)
                Spacer()
                Button("Start Pomodoro") {
                    state.startPomodoro(workMinutes: workMinutes, restMinutes: restMinutes, cycles: cycles)
                }
                .disabled(state.onCall)
            }

            Divider()

            Text("Simple timer").font(.subheadline.bold())
            HStack {
                Stepper("\(simpleMinutes) minutes", value: $simpleMinutes, in: 5...240, step: 5)
                    .font(.caption)
                Spacer()
                Button("Start Timer") {
                    state.startSimpleTimer(minutes: simpleMinutes)
                }
                .disabled(state.onCall)
            }

            if state.onCall {
                Button("End Current Session") { state.setOnCall(false) }
            }

            Divider()

            Text("Calendar").font(.subheadline.bold())
            Toggle("Auto-busy during calendar events", isOn: $state.calendarAutoBusy)
                .toggleStyle(.checkbox)
            if state.calendarAutoBusy && !state.calendarAccessGranted {
                Text("Waiting for calendar access — approve the system prompt.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let title = state.nextMeetingTitle, let date = state.nextMeetingDate {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next: \(title)").font(.caption).lineLimit(1)
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Countdown on Bar") { state.sendMeetingCountdown() }
                        .controlSize(.small)
                        .disabled(state.onCall)
                }
            } else if state.calendarAccessGranted {
                Text("No upcoming events in the next 24 h.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings tab

@MainActor
struct SettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = false
    @State private var weatherQuery = ""

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Device host") {
                TextField("10.0.4.20", text: $state.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            LabeledContent("Device name") {
                TextField("BUSY Bar", text: $state.deviceNameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { state.applyDeviceName() }
            }
            LabeledContent("API token") {
                SecureField("needed for Wi-Fi", text: $state.token)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            Picker("On-call theme", selection: $state.theme) {
                ForEach(state.availableThemes, id: \.self) { theme in
                    Text(themeTitle(theme)).tag(theme)
                }
            }
            Toggle("Trigger smart home", isOn: $state.triggerSmartHome)
            LabeledContent("Clear delay") {
                Picker("", selection: $state.offDebounceSeconds) {
                    Text("3 s").tag(3.0)
                    Text("10 s").tag(10.0)
                    Text("30 s").tag(30.0)
                }
                .labelsHidden()
                .frame(width: 80)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    state.launchAtLogin = newValue
                }

            Divider()
            Text("Notifications").font(.subheadline.bold())
            Toggle("Forward notifications to bar", isOn: $state.forwardNotifications)
            if state.forwardNotifications {
                LabeledContent("Only from") {
                    TextField("bundle IDs, comma-separated", text: $state.notificationAppFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Toggle("Chime on the bar", isOn: $state.notificationChime)
                Toggle("Queue during calls, replay after", isOn: $state.queueDuringCalls)
                notificationStatusView
            }

            Divider()
            Text("Widgets").font(.subheadline.bold())
            LabeledContent("Ping host") {
                TextField("1.1.1.1", text: $state.pingHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            Picker("Weather unit", selection: $state.weatherCelsius) {
                Text("°F").tag(false)
                Text("°C").tag(true)
            }
            .frame(maxWidth: 200)
            LabeledContent("Weather location") {
                TextField(state.weatherLocationLabel, text: $weatherQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit {
                        state.applyWeatherLocation(weatherQuery)
                        weatherQuery = ""
                    }
            }
            Text("Type a city and press return; leave empty and press return for automatic (IP-based).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Slack").font(.subheadline.bold())
            Toggle("Sync Slack status when busy", isOn: $state.slackSyncEnabled)
            if state.slackSyncEnabled {
                LabeledContent("User token") {
                    SecureField("xoxp-…", text: $state.slackToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                Text("Sets “🎧 On a call” + DND while busy; clears after. Token needs users.profile:write and dnd:write — see README.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text("Firmware \(state.firmwareVersion ?? "?") · Wi-Fi \(state.wifiStateText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Update") { state.checkForUpdate() }
                    .controlSize(.small)
            }
            if let text = state.updateCheckText {
                Text(text).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { launchAtLogin = state.launchAtLogin }
    }

    @ViewBuilder
    private var notificationStatusView: some View {
        switch state.notificationStatus {
        case .watching:
            Label("Watching for notifications", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.green)
        case .noAccess:
            VStack(alignment: .leading, spacing: 4) {
                Label("Needs Full Disk Access to read notifications", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button("Open Full Disk Access Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
            }
        case .error(let message):
            Text(message).font(.caption2).foregroundStyle(.red)
        case .stopped:
            EmptyView()
        }
    }

    private func themeTitle(_ theme: String) -> String {
        switch theme {
        case "dnd": return "Do Not Disturb"
        default: return theme.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }
}
