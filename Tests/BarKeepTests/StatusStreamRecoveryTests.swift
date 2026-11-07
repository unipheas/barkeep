import XCTest
@testable import BarKeep

final class StatusStreamRecoveryTests: XCTestCase {
    @MainActor func testLateFailureFromReplacedConnectionCannotStopNewStream() async throws {
        let old = RecoverySocket()
        let replacement = RecoverySocket()
        var attempts = 0
        let model = StatusStreamModel(makeSocket: { _ in
            attempts += 1
            return attempts == 1 ? old : replacement
        })
        defer { model.stop(); old.finish(); replacement.finish() }
        let client = BusyBarClient(host: "fixture.test")
        model.start(client: client)
        await settle { old.waiting }
        model.start(client: client)
        await settle { replacement.waiting }
        XCTAssertTrue(old.closed)
        old.finish(error: URLError(.networkConnectionLost))
        await Task.yield()
        replacement.finish(data: Data([0x12, 0]))
        await settle { model.packetCount == 1 }
        XCTAssertTrue(model.running)
        XCTAssertNil(model.error)
        XCTAssertFalse(replacement.closed)
        XCTAssertTrue(model.latestJSON.contains("updates"))
    }

    @MainActor func testEnableFailureCanBeRestartedWithoutStaleError() async throws {
        let failed = RecoverySocket(enableError: URLError(.cannotConnectToHost))
        let replacement = RecoverySocket()
        var attempts = 0
        let model = StatusStreamModel(makeSocket: { _ in
            attempts += 1
            return attempts == 1 ? failed : replacement
        })
        defer { model.stop(); replacement.finish() }
        let client = BusyBarClient(host: "fixture.test")
        model.start(client: client)
        await settle { model.error != nil }
        XCTAssertFalse(model.running)
        XCTAssertTrue(failed.closed)
        XCTAssertEqual(model.packetCount, 0)
        model.start(client: client)
        XCTAssertNil(model.error)
        XCTAssertNil(model.latestData)
        await settle { replacement.waiting }
        replacement.finish(data: Data([0x12, 0]))
        await settle { model.packetCount == 1 }
        XCTAssertTrue(model.running)
    }

    func testMaximumUnknownVarintIsSkippedAndFollowingFieldStillDecodes() throws {
        let bytes = Data([0xF8, 0x07] + Array(repeating: UInt8(0xFF), count: 9) + [1, 0x12, 0])
        let decoded = try StatusProto.decode(bytes)
        XCTAssertEqual((decoded["updates"] as? [Any])?.count, 1)
    }

    func testAllByteFieldsRejectScalarWire() throws {
        var checked = 0
        for (name, info) in StatusSchema.types {
            for field in (info.fields ?? [:]).values where field.type == "bytes" {
                var tag = UInt64(field.id) << 3
                var bytes = Data()
                repeat {
                    let low = UInt8(tag & 127)
                    tag >>= 7
                    bytes.append(low | (tag == 0 ? 0 : 128))
                } while tag != 0
                bytes.append(1)
                XCTAssertThrowsError(try StatusProto.decode(bytes, type: name))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    @MainActor private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Recovery did not settle")
    }
}

private final class RecoverySocket: StatusSocket {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let enableError: Error?
    private var didClose = false
    var closed: Bool { lock.withLock { didClose } }
    var waiting: Bool { lock.withLock { continuation != nil } }
    init(enableError: Error? = nil) { self.enableError = enableError }
    func start() {}
    func enable() async throws { if let enableError { throw enableError } }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { pending in
            lock.withLock { continuation = pending }
        }
    }
    func close() { lock.withLock { didClose = true } }
    func finish(data: Data? = nil, error: Error = CancellationError()) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        if let data { pending?.resume(returning: data) }
        else { pending?.resume(throwing: error) }
    }
}
