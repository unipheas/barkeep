import AppKit
import EventKit
import SQLite3
import XCTest
@testable import BarKeep

final class DefensiveLifecycleTests: XCTestCase {
    func testSparseNotificationRecordsAndZeroLengthUUID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("fixture.db").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { XCTAssertEqual(sqlite3_exec(db, text, nil, nil, nil), SQLITE_OK) }
        sql("CREATE TABLE app(app_id INTEGER,identifier TEXT); CREATE TABLE record(rec_id INTEGER,app_id INTEGER,uuid,data BLOB)")
        let watcher = NotificationWatcher(paths: [directory.appendingPathComponent("fixture.db").path])
        var notes: [ForwardedNotification] = []
        watcher.onNotification = { notes.append($0) }
        watcher.poll()
        let records: [[String: Any]] = [[:], ["req": ["titl": "No application"]], ["app": "fixture.app", "req": ["body": "Body only"]]]
        for (index, record) in records.enumerated() {
            let hex = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0).map { String(format: "%02x", $0) }.joined()
            sql("INSERT INTO record VALUES(\(index),1,X'',X'\(hex)')")
        }
        watcher.poll()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.map(\.bundleID), ["", "fixture.app"])
        XCTAssertEqual(notes.map(\.title), ["No application", ""])
        let stopped = expectation(description: "Closed fixture")
        watcher.onStatusChange = { if $0 == .stopped { stopped.fulfill() } }
        watcher.stop()
        wait(for: [stopped], timeout: 2)
    }

    @MainActor func testCalendarReleaseRemovesActiveObserver() {
        let source = EmptyLifecycleCalendar()
        let event = EKEvent(eventStore: EKEventStore())
        event.startDate = Date().addingTimeInterval(-60)
        event.endDate = Date().addingTimeInterval(60)
        source.fixtures = [event]
        let center = NotificationCenter()
        var monitor: CalendarMonitor? = CalendarMonitor(source: source, center: center)
        weak var weakMonitor = monitor
        monitor?.start()
        XCTAssertTrue(monitor?.accessGranted == true)
        monitor = nil
        XCTAssertNil(weakMonitor)
        center.post(name: .EKEventStoreChanged, object: source.notificationObject)
    }

    @MainActor func testWindowCoordinatorReleasedBeforeQueuedCorrection() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var coordinator: MenuBarWindowSizer.Coordinator? = .init()
        weak var weakCoordinator = coordinator
        coordinator?.update(window: window, contentSize: CGSize(width: 340, height: 500))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

@MainActor private final class EmptyLifecycleCalendar: CalendarSource {
    var authorizationStatus: EKAuthorizationStatus { .fullAccess }
    let notificationObject: AnyObject = NSObject()
    func requestAccess() async throws -> Bool { false }
    var fixtures: [EKEvent] = []
    func events(from: Date, to: Date) -> [EKEvent] { fixtures }
}
