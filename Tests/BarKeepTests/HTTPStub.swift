import XCTest
@testable import BarKeep

final class HTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response: URLResponse = status == -1
                ? URLResponse(url:request.url!,mimeType:nil,expectedContentLength:data.count,textEncodingName:nil)
                : HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:nil)!
            client?.urlProtocol(self, didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: config)
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
}

let appFixture = #"{"id":"app.test.clock","name":"Clock","version":"1.2.3","api_version":"27.12.0","author":"Tester","description":"Clock","is_debug":false,"icon_path":"/ext/clock.png"}"#
