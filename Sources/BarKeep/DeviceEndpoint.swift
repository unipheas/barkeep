import Foundation

struct DeviceEndpoint: Decodable, Identifiable, Hashable {
    struct Parameter: Decodable, Hashable {
        let name: String
        let location: String
        let required: Bool
        let detail: String
        let choices: [String]
        let defaultValue: String
    }
    let id: String
    let path: String
    let method: String
    let title: String
    let detail: String
    let group: String
    let parameters: [Parameter]
    let contentType: String
    let bodyTemplate: String
    let bodySchema: String

    var isReadOnly: Bool { method == "GET" }
    var isBinary: Bool { contentType == "application/octet-stream" }

    func prepare(values: [String: String], json: String, file: Data?) throws -> (path: String, query: [String: String], body: Data?) {
        var resolvedPath = path
        var query: [String: String] = [:]
        for parameter in parameters {
            let value = values[parameter.name] ?? parameter.defaultValue
            guard !value.isEmpty || !parameter.required else {
                throw BusyBarError(message: "Enter \(parameter.name).")
            }
            if value.isEmpty { continue }
            if !parameter.choices.isEmpty && !parameter.choices.contains(value) {
                throw BusyBarError(message: "Choose a valid value for \(parameter.name).")
            }
            if parameter.location == "path" {
                guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                    throw BusyBarError(message: "Invalid \(parameter.name).")
                }
                resolvedPath = resolvedPath.replacingOccurrences(of: "{\(parameter.name)}", with: value)
            } else if parameter.location == "query" { query[parameter.name] = value }
        }
        var body: Data?
        if isBinary {
            guard let file, !file.isEmpty else { throw BusyBarError(message: "Choose a file to upload.") }
            body = file
        } else if contentType == "application/json" {
            body = Data(json.utf8)
            _ = try JSONSerialization.jsonObject(with: body!)
        }
        return (resolvedPath, query, body)
    }
}
