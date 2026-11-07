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
        let min: Int?
        let max: Int?
        let min_length: Int?
        let max_length: Int?
    }
    let version: Int
    let fields: [String: Field]

    func validate(_ json: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              (root["version"] as? Int) == version,
              let values = root["values"] as? [String: Any] else {
            throw BusyBarError(message: "Keep settings version \(version) and the complete values document.")
        }
        try Self.validate(fields, values: values)
    }

    private static func validate(_ fields: [String: Field], values: [String: Any]) throws {
        for key in fields.keys.sorted() {
            let field = fields[key]!
            let value = values[key]
            func rejection(_ reason: String) -> BusyBarError {
                BusyBarError(message: "\(field.label): \(reason)")
            }
            switch field.type {
            case "group":
                guard let nested = value as? [String: Any] else { throw rejection("keep the complete group.") }
                try validate(field.fields ?? [:], values: nested)
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw rejection("choose enabled or disabled.")
                }
            case "integer":
                let lower = field.min ?? Int(Int32.min), upper = field.max ?? Int(Int32.max)
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= Double(lower), number.doubleValue <= Double(upper) else {
                    throw rejection("enter a whole number from \(lower) to \(upper).")
                }
            case "enum":
                guard let text = value as? String, field.options?.contains(where: { $0.value == text }) == true else {
                    throw rejection("choose one of the listed options.")
                }
            case "string":
                let lower = field.min_length ?? 0, upper = field.max_length ?? 64
                guard let text = value as? String, (lower...Swift.max(lower, upper)).contains(text.utf8.count) else {
                    throw rejection("enter text between \(lower) and \(upper) UTF-8 bytes.")
                }
            case "color", "time":
                let pattern = field.type == "color" ? "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$" : "^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$"
                guard let text = value as? String, text.range(of:pattern,options:.regularExpression) != nil else {
                    throw rejection(field.type == "color" ? "use #RRGGBB or #RRGGBBAA." : "use HH:MM or HH:MM:SS (24-hour time).")
                }
            default: break // Preserve future field types for firmware validation.
            }
        }
    }
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
        root["values"] = update(values, ArraySlice(path))
        return try BusyBarClient.prettyJSON(JSONSerialization.data(withJSONObject: root))
    }
}

@MainActor
struct AppSettingsForm: View {
    #if DEBUG
    // Inspect installed State in hosted interaction tests.
    internal var didAppear: ((Self) -> Void)?
    #endif
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
        #if DEBUG
        .onAppear { didAppear?(self) }
        #endif
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
