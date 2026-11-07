import Foundation
import XCTest
@testable import BarKeep

/// A loopback-only RFC 6455 fixture exercises the real URLSession adapter.
final class DeviceStatusSocketTests: XCTestCase {
    func testRealAdapterEnablesReceivesBinaryRejectsTextAndCloses() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-c", Self.server]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let line = output.fileHandleForReading.availableData
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/api/status")))
        let socket = DeviceStatusSocket(task: task)
        defer { socket.close() }
        XCTAssertEqual(task.maximumMessageSize, 1_048_576)
        socket.start()
        try await socket.enable()
        let packet = try await socket.receive()
        XCTAssertEqual(packet, Data([1, 2, 3]))
        do { _ = try await socket.receive(); XCTFail("Accepted text instead of a binary packet") }
        catch { XCTAssertEqual(error.localizedDescription, "Expected a binary status packet from the bar.") }
        socket.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("PASS"))
    }

    private static let server = #"""
import base64, hashlib, json, socket, struct
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(10)
    print(listener.getsockname()[1], flush=True)
    connection, _ = listener.accept()
    with connection:
        connection.settimeout(10)
        header = b''
        while b'\r\n\r\n' not in header:
            chunk = connection.recv(1)
            if not chunk: raise RuntimeError('Disconnected during handshake')
            header += chunk
            if len(header) > 16384: raise RuntimeError('Oversized handshake')
        headers = dict(line.split(':', 1) for line in header.decode().split('\r\n')[1:] if ':' in line)
        key = next(v.strip() for k, v in headers.items() if k.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        def exact(length):
            data = b''
            while len(data) < length:
                part = connection.recv(length - len(data))
                if not part: raise RuntimeError('Truncated frame')
                data += part
            return data
        def frame():
            first, second = exact(2)
            length = second & 127
            if length == 126: length = struct.unpack('!H', exact(2))[0]
            elif length == 127: length = struct.unpack('!Q', exact(8))[0]
            if length > 16384: raise RuntimeError('Oversized fixture frame')
            mask = exact(4) if second & 128 else None
            data = exact(length)
            if mask: data = bytes(value ^ mask[i % 4] for i, value in enumerate(data))
            return first & 15, data
        opcode, data = frame()
        assert opcode == 1 and json.loads(data) == {'enable': True}
        connection.sendall(b'\x82\x03\x01\x02\x03\x81\x03bad')
        opcode, _ = frame()
        assert opcode == 8
        print('PASS: enable, binary, text, close', flush=True)
"""#
}
