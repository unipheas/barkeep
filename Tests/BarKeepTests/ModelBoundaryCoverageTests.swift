import AppKit
import XCTest
@testable import BarKeep

final class ModelBoundaryCoverageTests: XCTestCase {
    func testFixed64FieldsRejectLengthDelimitedWire() throws {
        var checked = 0
        for (name, info) in StatusSchema.types {
            for field in (info.fields ?? [:]).values where field.type == "fixed64" {
                var tag = UInt64(field.id << 3 | 2)
                var bytes = Data()
                repeat {
                    let byte = UInt8(tag & 127)
                    tag >>= 7
                    bytes.append(byte | (tag == 0 ? 0 : 128))
                } while tag != 0
                bytes.append(0)
                XCTAssertThrowsError(try StatusProto.decode(bytes, type: name), name)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testColorHexRoundTripsAlphaAndGrayscale() throws {
        let color = try XCTUnwrap(MessageRenderer.nsColor(fromRGBAHex: "#1280FE40"))
        XCTAssertEqual(MessageRenderer.rgbaHex(from: color), "#1280FE40")
        XCTAssertEqual(MessageRenderer.rgbaHex(from: NSColor(deviceWhite: 0.5, alpha: 1)), "#808080FF")
    }

    func testNonHTTPResponseIsRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonHTTPBoundaryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = BusyBarClient(host: "bar.test", session: session)
        do {
            _ = try await client.send(URLRequest(url: URL(string: "http://bar.test/api/status")!))
            XCTFail("A non-HTTP transport response must not be treated as success")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No HTTP response")
        }
    }

    @MainActor func testOversizedUploadIsRejectedBeforeReadingContents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        try handle.close()
        let endpoint = try XCTUnwrap(DeviceEndpoint.all.first(where: { $0.isBinary }))
        let model = DeviceToolsModel()
        model.reset(for: endpoint)
        model.upload = url
        model.prepareConfirmation(endpoint, client: BusyBarClient(host: "bar.test"))
        XCTAssertFalse(model.confirm)
        XCTAssertEqual(model.error, "Choose a file smaller than 256 MB.")
    }
}

private final class NonHTTPBoundaryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
