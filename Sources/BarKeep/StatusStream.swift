import Foundation
import Observation

protocol StatusSocket: AnyObject {
    func start()
    func enable() async throws
    func receive() async throws -> Data
    func close()
}

final class DeviceStatusSocket: StatusSocket {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task; task.maximumMessageSize = 1_048_576 }
    func start() { task.resume() }
    func enable() async throws { try await task.send(.string(#"{"enable":true}"#)) }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string: throw BusyBarError(message:"Expected a binary status packet from the bar.")
        @unknown default: throw BusyBarError(message:"Unsupported status message.")
        }
    }
    func close() { task.cancel(with:.normalClosure,reason:nil) }
}

@Observable @MainActor
final class StatusStreamModel {
    private(set) var running = false
    private(set) var packetCount = 0
    private(set) var latestJSON = ""
    private(set) var latestData: Data?
    private(set) var error: String?
    private var task: Task<Void,Never>?
    private var socket: StatusSocket?
    private var generation = 0
    private let makeSocket: (BusyBarClient) throws -> StatusSocket

    init(makeSocket: @escaping (BusyBarClient) throws -> StatusSocket = { try $0.statusSocket() }) {
        self.makeSocket = makeSocket
    }
    func start(client: BusyBarClient) {
        stop()
        packetCount = 0; latestJSON = ""; latestData = nil; error = nil
        do {
            let socket = try makeSocket(client.snapshot())
            self.socket = socket
            let current = generation
            running = true
            socket.start()
            task = Task { [weak self] in
                do {
                    try await socket.enable()
                    while !Task.isCancelled {
                        let bytes = try await socket.receive()
                        guard let self, self.generation == current else { return }
                        let object = try StatusProto.decode(bytes)
                        let data = try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
                        self.latestData = data
                        self.latestJSON = data.count <= 64 * 1024
                            ? String(decoding:data,as:UTF8.self)
                            : "Received a large status packet (\(data.count) bytes). Save the packet to inspect it."
                        self.packetCount += 1
                    }
                } catch {
                    guard let self, self.generation == current else { return }
                    self.error = error.localizedDescription
                    self.stop()
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        generation += 1
        task?.cancel(); task = nil
        socket?.close(); socket = nil
        running = false
    }
}
