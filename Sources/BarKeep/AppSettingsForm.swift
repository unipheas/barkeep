import SwiftUI

struct AppSettingsSchema: Decodable {
    struct Field: Decodable {
        struct Option: Decodable { let value: String; let label: String }
        let type: String
        let label: String
        let description: String?
        let options: [Option]?
        let sensitive: Bool?
        let fields: [String: Field]?
    }
    let version: Int
    let fields: [String: Field]
}

/// Preserve the complete document while editing a single nested value.
enum AppSettingsDocument {
    static func value(in json: String, at path: [String]) -> Any? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        var value: Any? = root["values"]
        for key in path { value = (value as? [String: Any])?[key] }
        return value
    }

    static func replacing(in json: String, at path: [String], value: Any) throws -> String {
        guard !path.isEmpty,
              var root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let values = root["values"] as? [String: Any] else {
            throw BusyBarError(message: "Load the complete settings document before editing.")
        }
        func update(_ object: [String: Any], _ keys: ArraySlice<String>) -> [String: Any] {
            var copy = object
            let key = keys.first!
            copy[key] = keys.count == 1 ? value : update(object[key] as? [String: Any] ?? [:], keys.dropFirst())
            return copy
        }
        root["values"] = update(values, path[...])
        return try BusyBarClient.prettyJSON(JSONSerialization.data(withJSONObject: root))
    }
}

@MainActor
struct AppSettingsForm: View {
    let fields: [String: AppSettingsSchema.Field]
    var path: [String] = []
    @Binding var json: String
    @State private var editError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields.keys.sorted(), id: \.self) { key in
                if let field = fields[key] {
                    fieldView(key, field)
                    if let description = field.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let editError { Text(editError).foregroundStyle(.red).font(.caption) }
        }
    }

    @ViewBuilder private func fieldView(_ key: String, _ field: AppSettingsSchema.Field) -> some View {
        switch field.type {
        case "group":
            GroupBox(field.label) {
                AppSettingsForm(fields: field.fields ?? [:], path: path + [key], json: $json).padding(6)
            }
        case "boolean":
            Toggle(field.label, isOn: Binding(get: { value(key) as? Bool ?? false }, set: { set(key, $0) }))
        case "enum":
            Picker(field.label, selection: stringBinding(key)) {
                ForEach(field.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
        case "integer":
            LabeledContent(field.label) {
                TextField(field.label, value: Binding(get: { value(key) as? Int ?? 0 }, set: { set(key, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
            }
        case "string", "time", "color":
            LabeledContent(field.label) {
                if field.sensitive == true { SecureField(field.label, text: stringBinding(key)).textFieldStyle(.roundedBorder) }
                else { TextField(field.label, text: stringBinding(key)).textFieldStyle(.roundedBorder) }
            }
        default:
            Text("\(field.label): use Advanced JSON below to edit this setting.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func value(_ key: String) -> Any? { AppSettingsDocument.value(in: json, at: path + [key]) }
    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(get: { value(key) as? String ?? "" }, set: { set(key, $0) })
    }
    private func set(_ key: String, _ value: Any) {
        do { json = try AppSettingsDocument.replacing(in: json, at: path + [key], value: value); editError = nil }
        catch { editError = error.localizedDescription }
    }
}
