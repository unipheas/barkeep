import Foundation
import EventKit

@MainActor
protocol CalendarSource {
    var authorizationStatus: EKAuthorizationStatus { get }
    var notificationObject: AnyObject { get }
    func requestAccess() async throws -> Bool
    func events(from: Date, to: Date) -> [EKEvent]
}

@MainActor
final class SystemCalendarSource: CalendarSource {
    private let store: EKEventStore
    init(store: EKEventStore = EKEventStore()) { self.store = store }
    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for:.event) }
    var notificationObject: AnyObject { store }
    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func events(from: Date, to: Date) -> [EKEvent] {
        store.events(matching:store.predicateForEvents(withStart:from,end:to,calendars:nil))
    }
}

/// Watches calendars for the current and next meeting. The source boundary lets
/// tests exercise permission failures and event changes without reading calendars.
@MainActor
final class CalendarMonitor {
    var onChange: (() -> Void)?
    private(set) var accessGranted = false
    private(set) var currentEvent: EKEvent?
    private(set) var nextEvent: EKEvent?
    private let source: CalendarSource
    private let center: NotificationCenter
    private let now: () -> Date
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var signature = ""

    init(source: CalendarSource? = nil, center: NotificationCenter = .default, now: @escaping () -> Date = Date.init) {
        self.source = source ?? SystemCalendarSource()
        self.center = center; self.now = now
    }
    var authorizationStatus: EKAuthorizationStatus { source.authorizationStatus }

    func requestAccess() async -> Bool {
        do { accessGranted = try await source.requestAccess() }
        catch { accessGranted = false }
        if accessGranted { start() }
        else { stop() }
        return accessGranted
    }

    func start() {
        stopObservers()
        guard authorizationStatus == .fullAccess else {
            accessGranted = false
            clearEvents()
            return
        }
        accessGranted = true
        refresh()
        let timer = Timer(timeInterval:60,repeats:true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer,forMode:.common)
        self.timer = timer
        observer = center.addObserver(forName:.EKEventStoreChanged,object:source.notificationObject,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stop() {
        stopObservers()
        clearEvents()
    }
    private func stopObservers() {
        timer?.invalidate(); timer = nil
        if let observer { center.removeObserver(observer); self.observer = nil }
    }
    private func clearEvents() {
        let changed = currentEvent != nil || nextEvent != nil
        currentEvent = nil; nextEvent = nil; signature = ""
        if changed { onChange?() }
    }

    func refresh() {
        guard accessGranted else { return }
        guard authorizationStatus == .fullAccess else {
            accessGranted = false; stop(); return
        }
        let now = now()
        let events = source.events(from:now.addingTimeInterval(-12 * 3600),to:now.addingTimeInterval(24 * 3600))
            .filter { !$0.isAllDay && $0.status != .canceled && $0.startDate != nil && $0.endDate != nil }
        let current = events.filter { $0.startDate <= now && $0.endDate > now }.min { $0.endDate < $1.endDate }
        let next = events.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
        // EventKit can mutate an existing event object in place. Compare a stored
        // value snapshot so title/time changes with the same identifier are visible.
        let updatedSignature = [current,next].map { event in
            event.map { "\($0.eventIdentifier ?? "")|\($0.title ?? "")|\($0.startDate.timeIntervalSince1970)|\($0.endDate.timeIntervalSince1970)" } ?? ""
        }.joined(separator:"\n")
        let changed = updatedSignature != signature
        signature = updatedSignature; currentEvent = current; nextEvent = next
        if changed { onChange?() }
    }

    deinit {
        timer?.invalidate()
        if let observer { center.removeObserver(observer) }
    }
}
