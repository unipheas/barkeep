import SwiftUI

/// Full local API access stays in the native app; common app tasks have a dedicated tab.
@MainActor
struct DeviceToolsView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var selectedID: String? = DeviceEndpoint.all.first { $0.path == "/status" }?.id
    @State private var values: [String: String] = [:]
    @State private var json = ""
    @State private var upload: URL?
    @State private var response = ""
    @State private var responseData: Data?
    @State private var working = false
    @State private var error: String?
    @State private var confirm = false

    private var selected: DeviceEndpoint? { DeviceEndpoint.all.first { $0.id == selectedID } }
    private var matches: [DeviceEndpoint] {
        DeviceEndpoint.all.filter { search.isEmpty || "\($0.title) \($0.path) \($0.group)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack {
                TextField("Find a device control", text: $search).textFieldStyle(.roundedBorder).padding(10)
                List(selection: $selectedID) {
                    ForEach(Array(Set(matches.map(\.group))).sorted(), id: \.self) { group in
                        Section(group) {
                            ForEach(matches.filter { $0.group == group }) { endpoint in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(endpoint.title).font(.callout)
                                    Text("\(endpoint.method) \(endpoint.path)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }.tag(endpoint.id)
                            }
                        }
                    }
                }
            }.frame(width: 260)
            Divider()
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(selected.title).font(.title2.bold())
                        Text("\(state.host) · API \(DeviceEndpoint.apiVersion)").font(.caption).foregroundStyle(.secondary)
                        if !selected.detail.isEmpty { Text(selected.detail).font(.callout) }
                        if selected.path == "/status/ws" {
                            Text("Real-time status uses a WebSocket stream. Use the live preview in the Device tab; this request cannot run as ordinary HTTP.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(selected.parameters, id: \.name) { parameter in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(parameter.name + (parameter.required ? " *" : "")).frame(width: 120, alignment: .leading)
                                    if parameter.choices.isEmpty {
                                        TextField(parameter.required ? "Required" : "Optional", text: binding(parameter.name))
                                            .textFieldStyle(.roundedBorder)
                                    } else {
                                        Picker(parameter.name, selection: binding(parameter.name)) {
                                            Text("Choose…").tag("")
                                            ForEach(parameter.choices, id: \.self) { Text($0).tag($0) }
                                        }.labelsHidden()
                                    }
                                }
                                if !parameter.detail.isEmpty { Text(parameter.detail).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if selected.contentType == "application/json" {
                            Text("Request settings (JSON)").font(.headline)
                            TextEditor(text: $json).font(.system(.body, design: .monospaced)).frame(height: 190).border(.quaternary)
                            DisclosureGroup("Field reference") {
                                Text(selected.bodySchema).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        } else if selected.isBinary {
                            HStack {
                                Button("Choose File…") { chooseUpload() }
                                Text(upload?.lastPathComponent ?? "No file selected").font(.caption)
                            }
                        }
                        HStack {
                            Button(selected.isReadOnly ? "Read from Bar" : "Apply to Bar…") {
                                if selected.isReadOnly { Task { await execute(selected) } }
                                else { confirm = true }
                            }.buttonStyle(.borderedProminent).disabled(working || selected.path == "/status/ws")
                            if working { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Save Response…") { saveResponse() }.disabled(responseData == nil)
                        }
                        if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                        if !response.isEmpty {
                            Text("Response").font(.headline)
                            Text(response).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary)
                        }
                    }.padding(20)
                }
                .disabled(working)
                .alert("\(selected.title)?", isPresented: $confirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Apply") { Task { await execute(selected) } }
                } message: { Text("Send \(selected.method) \(selected.path) to \(state.host) with the values shown. This changes the device. Network changes can disconnect it; firmware installation may restart it.") }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .onChange(of: selectedID) { _, _ in resetForm() }
        .onChange(of: state.host) { _, _ in resetForm() }
        .onAppear { resetForm() }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func resetForm() {
        values = Dictionary(uniqueKeysWithValues: (selected?.parameters ?? []).map { ($0.name, $0.defaultValue) })
        json = selected?.bodyTemplate ?? ""; upload = nil; response = ""; responseData = nil; error = nil
    }

    private func chooseUpload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { if $0 == .OK { upload = panel.url } }
    }

    private func saveResponse() {
        guard let data = responseData else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "busy-bar-response"
        panel.begin {
            guard $0 == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }

    private func execute(_ endpoint: DeviceEndpoint) async {
        guard !working else { return }
        working = true; error = nil; response = ""; responseData = nil
        defer { working = false }
        do {
            if let upload {
                let size = try upload.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 256 * 1024 * 1024 else { throw BusyBarError(message: "Choose a file smaller than 256 MB.") }
            }
            let prepared = try endpoint.prepare(values: values, json: json, file: try upload.map { try Data(contentsOf: $0) })
            let data = try await state.client.api(endpoint.method, prepared.path, query: prepared.query,
                body: prepared.body, contentType: endpoint.contentType, timeout: 120)
            responseData = data
            response = (try? BusyBarClient.prettyJSON(data)) ?? String(data: data, encoding: .utf8) ?? "Received \(data.count) binary bytes. Save the response to a file."
            if response.isEmpty { response = "Completed successfully." }
        } catch { self.error = error.localizedDescription }
    }
}
