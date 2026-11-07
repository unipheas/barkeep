import Foundation
import Observation

/// A confirmation approves an immutable request and destination, not a mutable form.
@Observable @MainActor
final class DeviceToolsModel {
    var values: [String: String] = [:]
    var json = ""
    var upload: URL?
    var error: String?
    var confirm = false
    private(set) var response = ""
    private(set) var responseData: Data?
    private(set) var working = false
    private var revision = 0
    private var pending: Request?
    var confirmationHost: String? { pending?.client.host }

    private struct Request {
        let endpoint: DeviceEndpoint
        let path: String
        let query: [String: String]
        let body: Data?
        let client: BusyBarClient
    }

    func reset(for endpoint: DeviceEndpoint?) {
        revision += 1
        values = Dictionary(uniqueKeysWithValues: (endpoint?.parameters ?? []).map { ($0.name, $0.defaultValue) })
        json = endpoint?.bodyTemplate ?? ""
        upload = nil; response = ""; responseData = nil; error = nil
        pending = nil; confirm = false
    }

    private func prepare(_ endpoint: DeviceEndpoint, client: BusyBarClient) throws -> Request {
        var file: Data?
        if endpoint.isBinary, let upload {
            let size = try upload.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256 * 1024 * 1024 else { throw BusyBarError(message: "Choose a file smaller than 256 MB.") }
            file = try Data(contentsOf: upload)
        }
        let prepared = try endpoint.prepare(values: values, json: json, file: file)
        return Request(endpoint: endpoint, path: prepared.path, query: prepared.query,
                       body: prepared.body, client: client.snapshot())
    }

    func prepareConfirmation(_ endpoint: DeviceEndpoint, client: BusyBarClient) {
        guard !working else { return }
        pending = nil; confirm = false; error = nil
        do {
            pending = try prepare(endpoint, client: client)
            confirm = true
        } catch { self.error = error.localizedDescription }
    }

    func applyConfirmed(client: BusyBarClient) async {
        guard !working, let request = pending else { return }
        pending = nil; confirm = false
        guard request.client.host == client.host, request.client.token == client.token else {
            error = "Device changed. Review the request again before applying it."
            return
        }
        await send(request, liveClient: client)
    }

    func execute(_ endpoint: DeviceEndpoint, client: BusyBarClient) async {
        guard !working else { return }
        do { await send(try prepare(endpoint, client: client), liveClient: client) }
        catch { self.error = error.localizedDescription }
    }

    private func send(_ request: Request, liveClient: BusyBarClient) async {
        let generation = revision
        working = true; error = nil; response = ""; responseData = nil
        defer { working = false }
        do {
            let data = try await request.client.api(request.endpoint.method, request.path,
                query: request.query, body: request.body, contentType: request.endpoint.contentType, timeout: 120)
            guard generation == revision, request.client.host == liveClient.host,
                  request.client.token == liveClient.token else { return }
            responseData = data
            if data.count > 64 * 1024 {
                response = "Received \(data.count) bytes. Save the response to view the complete file."
            } else {
                response = (try? BusyBarClient.prettyJSON(data)) ?? String(data: data, encoding: .utf8)
                    ?? "Received \(data.count) binary bytes. Save the response to a file."
            }
            if response.isEmpty { response = "Completed successfully." }
        } catch {
            guard generation == revision, request.client.host == liveClient.host,
                  request.client.token == liveClient.token else { return }
            self.error = error.localizedDescription
        }
    }
}
