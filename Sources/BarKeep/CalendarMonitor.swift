import Foundation
import EventKit

/// Watches the user's calendars for the current and next event, so the app
/// can auto-set busy during meetings and show a countdown to the next one.
@MainActor
final class CalendarMonitor {
    var onChange: (() -> Void)?

    private(set) var accessGranted = false
    private(set) var currentEvent: EKEvent?
    private(set) var nextEvent: EKEvent?

    private let store = EKEventStore()
    private var timer: Timer?

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async -> Bool {
        do {
            accessGranted = try await store.requestFullAccessToEvents()
        } catch {
            accessGranted = false
        }
        if accessGranted { start() }
        return accessGranted
    }

    func start() {
        guard authorizationStatus == .fullAccess else { return }
        accessGranted = true
        refresh()
        timer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        guard accessGranted else { return }
        let now = Date()
        let horizon = now.addingTimeInterval(24 * 3600)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600), end: horizon, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }

        let current = events
            .filter { $0.startDate <= now && $0.endDate > now }
            .min { $0.endDate < $1.endDate }
        let next = events
            .filter { $0.startDate > now }
            .min { $0.startDate < $1.startDate }

        let changed = current?.eventIdentifier != currentEvent?.eventIdentifier
            || next?.eventIdentifier != nextEvent?.eventIdentifier
        currentEvent = current
        nextEvent = next
        if changed { onChange?() }
    }
}
