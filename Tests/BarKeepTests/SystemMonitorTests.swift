import EventKit
import XCTest
@testable import BarKeep

final class SystemMonitorTests: XCTestCase {
    @MainActor func testScheduledCalendarTimerRefreshesFixtureSource() async throws {
        let source = FixtureCalendarSource()
        let monitor = CalendarMonitor(source: source, center: NotificationCenter())
        monitor.start()
        defer { monitor.stop() }
        let value = try XCTUnwrap(Mirror(reflecting: monitor).children.first { $0.label == "timer" }?.value)
        let timer = try XCTUnwrap((value as? Timer) ?? (Mirror(reflecting: value).children.first?.value as? Timer))
        XCTAssertEqual(timer.timeInterval, 60)
        let before = source.reads
        timer.fire()
        for _ in 0..<100 where source.reads == before { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(source.reads, before + 1)
    }

    func testPingLoopbackAndFailureCases() async {
        let success = await PingMonitor.measure(host:"127.0.0.1")
        XCTAssertNotNil(success)
        XCTAssertGreaterThanOrEqual(success ?? -1,0)
        let missing = await PingMonitor.measure(host:"127.0.0.1",executableURL:URL(fileURLWithPath:"/not-a-barkeep-executable"))
        XCTAssertNil(missing)
        let malformed = await PingMonitor.measure(host:"127.0.0.1",executableURL:URL(fileURLWithPath:"/usr/bin/false"))
        XCTAssertNil(malformed)
        for host in ["-f", "", "host\n-f", "host with spaces"] {
            let invalid = await PingMonitor.measure(host:host)
            XCTAssertNil(invalid)
        }
    }

    @MainActor func testCalendarSelectionChangesAndPermissionRevocation() async {
        let source = FixtureCalendarSource()
        let center = NotificationCenter()
        let now = Date(timeIntervalSince1970:100000)
        let monitor = CalendarMonitor(source:source,center:center,now:{ now })
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.refresh()
        XCTAssertEqual(source.reads,0)
        source.items = [event("Long",now.addingTimeInterval(-60),now.addingTimeInterval(600)),
                        event("Short",now.addingTimeInterval(-30),now.addingTimeInterval(30)),
                        event("Next",now.addingTimeInterval(120),now.addingTimeInterval(240)),
                        event("Later",now.addingTimeInterval(300),now.addingTimeInterval(600))]
        let allDay = event("All day",now.addingTimeInterval(-600),now.addingTimeInterval(600)); allDay.isAllDay = true
        source.items.append(allDay)
        source.items.append(event("Ended",now.addingTimeInterval(-60),now))
        let allowed = await monitor.requestAccess()
        XCTAssertTrue(allowed); XCTAssertTrue(monitor.accessGranted)
        XCTAssertEqual(monitor.currentEvent?.title,"Short")
        XCTAssertEqual(monitor.nextEvent?.title,"Next")
        XCTAssertEqual(changes,1)
        monitor.refresh(); XCTAssertEqual(changes,1)
        source.items[2].title = "Renamed"
        source.items[2].startDate = now.addingTimeInterval(90)
        center.post(name:.EKEventStoreChanged,object:source.notificationObject)
        for _ in 0..<50 where changes == 1 { try? await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(changes,2); XCTAssertEqual(monitor.nextEvent?.title,"Renamed")
        monitor.start(); monitor.start()
        let reads = source.reads
        center.post(name:.EKEventStoreChanged,object:source.notificationObject)
        try? await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(source.reads,reads+1,"Repeated starts must not leak duplicate observers")
        source.authorizationStatus = .denied
        monitor.refresh()
        XCTAssertFalse(monitor.accessGranted); XCTAssertNil(monitor.currentEvent); XCTAssertNil(monitor.nextEvent)
        let stoppedReads = source.reads
        center.post(name:.EKEventStoreChanged,object:source.notificationObject)
        try? await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(source.reads,stoppedReads)
        monitor.stop()
    }

    @MainActor func testCalendarAccessFailureDoesNotReadEvents() async {
        let source = FixtureCalendarSource()
        let monitor = CalendarMonitor(source:source)
        source.authorizationStatus = .denied
        monitor.start()
        XCTAssertFalse(monitor.accessGranted)
        source.allow = false
        let denied = await monitor.requestAccess()
        XCTAssertFalse(denied); XCTAssertEqual(source.reads,0)
        source.fail = true
        let failed = await monitor.requestAccess()
        XCTAssertFalse(failed); XCTAssertEqual(source.reads,0)
    }

    @MainActor func testMenuIconsHaveExpectedTemplateAndDimensions() throws {
        for (onCall,reachable,template) in [(false,true,true),(true,true,false),(false,false,true),(true,false,true)] {
            let icon = MenuBarIcon.current(onCall:onCall,reachable:reachable)
            XCTAssertEqual(icon.size.width,18); XCTAssertEqual(icon.size.height,16)
            XCTAssertEqual(icon.isTemplate,template)
            XCTAssertNotNil(icon.tiffRepresentation)
        }
    }

    @MainActor private func event(_ title: String, _ start: Date, _ end: Date) -> EKEvent {
        let event = EKEvent(eventStore:EKEventStore())
        event.title = title; event.startDate = start; event.endDate = end
        return event
    }
}

@MainActor private final class FixtureCalendarSource: CalendarSource {
    var authorizationStatus: EKAuthorizationStatus = .fullAccess
    let notificationObject: AnyObject = NSObject()
    var items: [EKEvent] = []
    var reads = 0
    var allow = true
    var fail = false
    func requestAccess() async throws -> Bool {
        if fail { throw URLError(.notConnectedToInternet) }
        return allow
    }
    func events(from:Date,to:Date) -> [EKEvent] { reads += 1; return items }
}
