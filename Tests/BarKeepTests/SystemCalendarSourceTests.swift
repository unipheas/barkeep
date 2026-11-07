import EventKit
import XCTest
@testable import BarKeep

final class SystemCalendarSourceTests: XCTestCase {
    @MainActor func testConcreteAdapterUsesProvidedStoreWithoutCalendarAccess() async throws {
        let store = AdapterEventStore()
        let source = SystemCalendarSource(store: store)
        XCTAssertTrue(source.notificationObject === store)
        XCTAssertEqual(source.authorizationStatus, EKEventStore.authorizationStatus(for: .event))
        let granted = try await source.requestAccess()
        XCTAssertFalse(granted)
        XCTAssertEqual(store.requests, 1)
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(source.events(from: start, to: end).isEmpty)
        XCTAssertEqual(store.start, start)
        XCTAssertEqual(store.end, end)
        XCTAssertEqual(store.queries, 1)
    }
}

private final class AdapterEventStore: EKEventStore, @unchecked Sendable {
    var requests = 0
    var queries = 0
    var start: Date?
    var end: Date?
    override func requestFullAccessToEvents(completion: @escaping (Bool, Error?) -> Void) {
        requests += 1
        completion(false, nil)
    }
    override func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        start = startDate; end = endDate
        return NSPredicate(value: true)
    }
    override func events(matching predicate: NSPredicate) -> [EKEvent] {
        queries += 1
        return []
    }
}
