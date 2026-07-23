import AppKit
import Observation
import os

private let arcadeLog = Logger(subsystem: "dev.barkeep.mac", category: "arcade")

struct ArcadeUploadLifecycle {
    private(set) var session = 0
    private(set) var uploadSession: Int?

    mutating func beginSession() {
        session += 1
    }

    mutating func beginUpload() -> Int {
        uploadSession = session
        return session
    }

    mutating func invalidateSession() {
        session += 1
    }

    func shouldDraw(uploadSession: Int, isActive: Bool) -> Bool {
        isActive && uploadSession == session
    }

    mutating func finishUpload(_ finishedSession: Int) -> Bool {
        guard uploadSession == finishedSession else { return false }
        uploadSession = nil
        return true
    }
}

private final class ArcadeInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ArcadeKeyboardCapture: NSObject, NSWindowDelegate {
    private var panel: ArcadeInputPanel?
    private var eventMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var onFocusLost: (() -> Void)?
    private var isStopping = false
    private var captureTask: Task<Void, Never>?
    private var captureEstablished = false

    func start(
        onEvent: @escaping (NSEvent) -> Void,
        onCaptured: @escaping () -> Void,
        onFocusLost: @escaping () -> Void
    ) {
        stop(restoreFocus: false)
        self.onFocusLost = onFocusLost
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil
            : frontmost

        let panel = ArcadeInputPanel(
            contentRect: NSRect(x: -10, y: -10, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.delegate = self
        self.panel = panel

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { event in
            onEvent(event)
            return nil
        }

        // The menu-bar popover is still completing its button click when this
        // method starts. Capturing immediately lets that popover steal key
        // status back and looks like an external focus change.
        captureTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let panel, self.panel === panel else {
                return
            }
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            self.captureEstablished = panel.isKeyWindow
            if self.captureEstablished {
                onCaptured()
            }
        }
    }

    func stop(restoreFocus: Bool = true) {
        isStopping = true
        captureTask?.cancel()
        captureTask = nil
        captureEstablished = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel?.close()
        panel = nil
        onFocusLost = nil
        if restoreFocus {
            if let previousApplication {
                previousApplication.activate(options: [.activateAllWindows])
            } else {
                NSApp.hide(nil)
            }
        }
        previousApplication = nil
        isStopping = false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isStopping, captureEstablished else { return }
        onFocusLost?()
    }
}

@Observable
@MainActor
final class ArcadeController {
    private(set) var isActive = false
    private(set) var selectedGame: ArcadeGame = .snake
    private(set) var previewImage: CGImage?
    private(set) var framesSent = 0
    private(set) var framesDropped = 0
    private(set) var controlsCaptured = false
    var showPreview: Bool {
        didSet {
            UserDefaults.standard.set(showPreview, forKey: "arcadeShowPreview")
            updatePreview()
        }
    }
    var errorMessage: String?

    private let client: BusyBarClient
    private let keyboard = ArcadeKeyboardCapture()
    private var engine = ArcadeEngine(game: .snake)
    private var heldKeys = Set<ArcadeKey>()
    private var pressedKeys = Set<ArcadeKey>()
    private var gameTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var uploadSlot = 0
    private var lastUpload = ContinuousClock.now
    private var nextUploadAllowed = ContinuousClock.now
    private var uploadLifecycle = ArcadeUploadLifecycle()
    private var consecutiveFailures = 0

    init(client: BusyBarClient) {
        self.client = client
        self.showPreview = UserDefaults.standard.bool(forKey: "arcadeShowPreview")
        updatePreview()
    }

    func start(_ game: ArcadeGame) {
        if isActive {
            select(game)
            return
        }
        selectedGame = game
        engine.select(game)
        uploadLifecycle.beginSession()
        isActive = true
        framesSent = 0
        framesDropped = 0
        errorMessage = nil
        consecutiveFailures = 0
        nextUploadAllowed = .now
        heldKeys.removeAll()
        pressedKeys.removeAll()
        updatePreview()
        captureKeyboard()
        startLoop()
    }

    func captureKeyboard() {
        guard isActive else { return }
        controlsCaptured = false
        keyboard.start(
            onEvent: { [weak self] event in self?.handle(event) },
            onCaptured: { [weak self] in
                self?.controlsCaptured = true
                self?.errorMessage = nil
            },
            onFocusLost: { [weak self] in
                guard let self else { return }
                self.controlsCaptured = false
                self.heldKeys.removeAll()
                self.pressedKeys.removeAll()
                self.errorMessage = "Keyboard focus released. Click Capture Keyboard to resume controls."
            }
        )
    }

    func select(_ game: ArcadeGame) {
        selectedGame = game
        engine.select(game)
        heldKeys.removeAll()
        pressedKeys.removeAll()
        updatePreview()
    }

    func restart() {
        engine.reset()
        updatePreview()
    }

    func stop() {
        stop(withError: nil)
    }

    private func stop(withError error: String?) {
        guard isActive else { return }
        uploadLifecycle.invalidateSession()
        isActive = false
        gameTask?.cancel()
        gameTask = nil
        // URLSession cancellation can leave a partially overwritten PNG in
        // the device asset slot. Let the current upload finish; generation
        // checks below prevent its stale frame from being drawn.
        heldKeys.removeAll()
        pressedKeys.removeAll()
        controlsCaptured = false
        keyboard.stop()
        if let error {
            errorMessage = error
        }
    }

    private func startLoop() {
        gameTask?.cancel()
        lastUpload = .now - .seconds(1)
        gameTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self, self.isActive else { break }
                self.engine.update(
                    now: ProcessInfo.processInfo.systemUptime,
                    held: self.heldKeys,
                    pressed: self.pressedKeys
                )
                self.pressedKeys.removeAll()
                self.updatePreview()
                self.sendLatestFrameIfReady()
                try? await clock.sleep(for: .milliseconds(16))
            }
        }
    }

    private func sendLatestFrameIfReady() {
        let now = ContinuousClock.now
        guard now - lastUpload >= .milliseconds(50) else { return }
        guard now >= nextUploadAllowed else { return }
        guard uploadTask == nil else {
            framesDropped += 1
            return
        }
        guard let png = ArcadeRenderer.pngData(from: engine.frame) else {
            errorMessage = "Could not encode the arcade frame."
            return
        }
        lastUpload = now
        let frameGeneration = uploadLifecycle.beginUpload()
        let filename = "arcade\(uploadSlot).png"
        uploadSlot = (uploadSlot + 1) % 2
        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.uploadAsset(filename: filename, data: png)
                guard self.uploadLifecycle.shouldDraw(
                    uploadSession: frameGeneration,
                    isActive: self.isActive
                ) else {
                    if self.uploadLifecycle.finishUpload(frameGeneration) {
                        self.uploadTask = nil
                    }
                    return
                }
                try await self.client.drawImage(
                    named: filename, timeout: 1, priority: 99
                )
                self.framesSent += 1
                self.consecutiveFailures = 0
                self.nextUploadAllowed = .now
                self.errorMessage = nil
            } catch is CancellationError {
                // Process shutdown can still cancel URLSession work.
            } catch {
                guard self.uploadLifecycle.shouldDraw(
                    uploadSession: frameGeneration,
                    isActive: self.isActive
                ) else {
                    if self.uploadLifecycle.finishUpload(frameGeneration) {
                        self.uploadTask = nil
                    }
                    return
                }
                arcadeLog.error("Arcade frame failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = error.localizedDescription
                self.consecutiveFailures += 1
                let delay = min(
                    5.0,
                    pow(2.0, Double(self.consecutiveFailures - 1)) * 0.25
                )
                self.nextUploadAllowed = .now + .seconds(delay)
                if self.consecutiveFailures >= 5 {
                    self.stop(withError: "Arcade stopped after repeated connection failures.")
                }
            }
            if self.uploadLifecycle.finishUpload(frameGeneration) {
                self.uploadTask = nil
            }
        }
    }

    private func updatePreview() {
        previewImage = showPreview ? ArcadeRenderer.cgImage(from: engine.frame) : nil
    }

    private func handle(_ event: NSEvent) {
        let isDown = event.type == .keyDown
        if isDown, event.isARepeat { return }

        switch event.keyCode {
        case 53: // Escape: release keyboard capture and stop.
            if isDown { stop() }
            return
        case 18 where isDown: select(.snake)
        case 19 where isDown: select(.tetris)
        case 20 where isDown: select(.pong)
        case 21 where isDown: select(.breakout)
        case 15 where isDown: restart()
        default:
            guard let key = Self.arcadeKey(for: event.keyCode) else { return }
            if isDown {
                heldKeys.insert(key)
                pressedKeys.insert(key)
            } else {
                heldKeys.remove(key)
            }
        }
    }

    private static func arcadeKey(for keyCode: UInt16) -> ArcadeKey? {
        switch keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 49: .space
        case 13: .w
        case 1: .s
        default: nil
        }
    }
}

enum ArcadeRenderer {
    static func cgImage(from frame: ArcadeFrame) -> CGImage? {
        var rgba = Data(capacity: ArcadeFrame.width * ArcadeFrame.height * 4)
        for color in frame.pixels {
            rgba.append(color.red)
            rgba.append(color.green)
            rgba.append(color.blue)
            rgba.append(0xFF)
        }
        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(
            width: ArcadeFrame.width,
            height: ArcadeFrame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: ArcadeFrame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func pngData(from frame: ArcadeFrame) -> Data? {
        guard let image = cgImage(from: frame) else { return nil }
        return NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [.compressionFactor: 0.2])
    }
}
