import XCTest
@testable import BarKeep

final class StatusStreamTests: XCTestCase {
    func testEverySchemaFieldAndEnumCanDecode() throws {
        for (name,info) in StatusSchema.types where info.fields != nil {
            var bytes = Data()
            for (_,field) in info.fields!.sorted(by: { $0.value.id < $1.value.id }) {
                let wire: UInt64
                let payload: Data
                switch field.type {
                case "uint32", "sint32", "bool": wire = 0; payload = varint(7)
                case "fixed64": wire = 1; payload = Data([1,2,3,4,5,6,7,8])
                case "string": wire = 2; payload = length(Data("Test".utf8))
                case "bytes": wire = 2; payload = length(Data([1,2,3]))
                default:
                    let resolved = try StatusProto.resolve(field.type,within:name)
                    if let enums = StatusSchema.types[resolved]?.values {
                        wire = 0; payload = varint(UInt64(enums.values.min() ?? 0))
                    } else { wire = 2; payload = length(Data()) }
                }
                bytes.append(varint(UInt64(field.id) << 3 | wire)); bytes.append(payload)
            }
            let decoded = try StatusProto.decode(bytes,type:name)
            XCTAssertEqual(decoded.count,info.fields!.count,name)
            if let field = info.fields?.first(where: { $0.value.type == "sint32" }) {
                XCTAssertEqual(decoded[field.key] as? Int64,-4)
            }
        }
        let state = try StatusProto.decode(Data([0x12,0,0x12,0]))
        XCTAssertEqual((state["updates"] as? [Any])?.count,2)
        let unknownEnum = try StatusProto.decode(Data([8,127]),type:"BSB_Error.Error")
        XCTAssertEqual(unknownEnum["cause"] as? String,"127")
        XCTAssertEqual(try StatusProto.decode(Data([0xF8,0x07,1,0xFD,0x07,1,2,3,4])).count,0)
    }

    func testRejectsMalformedOversizedAndWrongWirePackets() {
        let cases = [Data([0]),Data([0x80]),Data([0x0B]),Data([0x09,1]),
                     Data([0x12,4,1]),Data([0x12,0x80,0x80,0x80,1]),
                     Data([0xF8,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,2]),
                     Data([8,1]),Data([0x12,1,0])]
        for data in cases { XCTAssertThrowsError(try StatusProto.decode(data),data.description) }
        XCTAssertThrowsError(try StatusProto.decode(Data(repeating:0,count:1_048_577)))
        XCTAssertThrowsError(try StatusProto.decode(Data(),depth:16))
        XCTAssertThrowsError(try StatusProto.decode(Data(),type:"unknown"))
        XCTAssertThrowsError(try StatusProto.resolve("unknown",within:"BSB_State.State"))
        XCTAssertThrowsError(try StatusProto.decode(Data([10,1,0xFF]),type:"BSB_State.DeviceName"))
        XCTAssertThrowsError(try StatusProto.decode(Data([8,1]),type:"BSB_State.DeviceName"))
        XCTAssertThrowsError(try StatusProto.decode(Data([0x0A,0]),type:"BSB_State.AudioVolume"))
        XCTAssertThrowsError(try StatusProto.decode(Data([8,0xFF,0xFF,0xFF,0xFF,0x7F]),type:"BSB_State.AudioVolume"))
        XCTAssertThrowsError(try StatusProto.decode(Data([10,0]),type:"BSB_Error.Error"))
    }

    @MainActor func testStreamLifecycleDecodeFailureAndRestart() async throws {
        let socket = FixtureStatusSocket(packets:[Data([0x12,0])])
        let model = StatusStreamModel(makeSocket:{ client in
            XCTAssertEqual(client.host,"bar.test")
            return socket
        })
        let client = BusyBarClient(host:"bar.test")
        model.start(client:client)
        await settle { model.packetCount == 1 }
        XCTAssertTrue(model.running); XCTAssertTrue(socket.started); XCTAssertTrue(socket.enabled)
        XCTAssertTrue(model.latestJSON.contains("updates")); XCTAssertNotNil(model.latestData)
        model.stop()
        XCTAssertFalse(model.running); XCTAssertTrue(socket.closed)
        let invalid = FixtureStatusSocket(packets:[Data([0])])
        let bad = StatusStreamModel(makeSocket:{ _ in invalid })
        bad.start(client:client)
        await settle { bad.error != nil }
        XCTAssertFalse(bad.running); XCTAssertTrue(invalid.closed)
        let failed = StatusStreamModel(makeSocket:{ _ in throw URLError(.badURL) })
        failed.start(client:client)
        XCTAssertNotNil(failed.error); XCTAssertFalse(failed.running)
        let large = Data([0x12]) + length(Data([0x52]) + length(Data([0x32]) + length(Data(repeating:65,count:60000))))
        let largeSocket = FixtureStatusSocket(packets:[large])
        let big = StatusStreamModel(makeSocket:{ _ in largeSocket })
        big.start(client:client)
        await settle { big.packetCount == 1 }
        XCTAssertTrue(big.latestJSON.contains("large status packet")); big.stop()
    }

    @MainActor func testStoppingDiscardsLatePacket() async {
        let socket = FixtureStatusSocket(packets:[Data([0x12,0])],delay:true)
        let model = StatusStreamModel(makeSocket:{ _ in socket })
        model.start(client:BusyBarClient(host:"bar.test"))
        await settle { socket.enabled }
        model.stop()
        try? await Task.sleep(for:.milliseconds(40))
        XCTAssertEqual(model.packetCount,0); XCTAssertNil(model.error)
    }

    func testLiveStatusStreamOnConnectedDevice() async throws {
        guard ProcessInfo.processInfo.environment["BARKEEP_LIVE_STATUS"] == "1" else {
            throw XCTSkip("Set BARKEEP_LIVE_STATUS=1 to read the connected USB device's live stream")
        }
        let socket = try BusyBarClient(host:"10.0.4.20").statusSocket()
        socket.start(); defer { socket.close() }
        try await socket.enable()
        let packet = try await socket.receive()
        let decoded = try StatusProto.decode(packet)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertNotNil(decoded["timestamp"])
    }

    private func varint(_ number: UInt64) -> Data {
        var number = number; var bytes = Data()
        while number > 127 { bytes.append(UInt8(number & 127) | 128); number >>= 7 }
        bytes.append(UInt8(number)); return bytes
    }
    private func length(_ data: Data) -> Data { varint(UInt64(data.count)) + data }
    @MainActor private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for:.milliseconds(5))
        }
        XCTFail("Stream did not settle")
    }
}

private final class FixtureStatusSocket: StatusSocket {
    private var packets: [Data]
    private let delay: Bool
    var started = false
    var enabled = false
    var closed = false
    init(packets:[Data],delay:Bool=false) { self.packets=packets; self.delay=delay }
    func start() { started=true }
    func enable() async throws { enabled=true }
    func receive() async throws -> Data {
        if delay { try? await Task.sleep(for:.milliseconds(20)) }
        if !packets.isEmpty { return packets.removeFirst() }
        try await Task.sleep(for:.seconds(30))
        throw URLError(.networkConnectionLost)
    }
    func close() { closed=true }
}
