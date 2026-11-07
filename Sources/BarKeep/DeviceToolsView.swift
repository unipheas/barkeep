import SwiftUI

/// Full local API access stays in the native app; common app tasks have a dedicated tab.
@MainActor
struct DeviceToolsView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var selectedID: String?
    @State private var model: DeviceToolsModel
    private let exportFile: FileExport.Handler

    init(endpoint: DeviceEndpoint? = nil, model: DeviceToolsModel? = nil,
         exportFile: @escaping FileExport.Handler = FileExport.present) {
        self.exportFile = exportFile
        _selectedID = State(initialValue: (endpoint ?? DeviceEndpoint.all.first { $0.path == "/status" })?.id)
        _model = State(initialValue: model ?? DeviceToolsModel())
    }

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
            if selected?.path == "/status/ws" {
                ScrollView { StatusStreamView().padding(20) }
            } else if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(selected.title).font(.title2.bold())
                        Text("\(state.host) · API \(DeviceEndpoint.apiVersion)").font(.caption).foregroundStyle(.secondary)
                        if !selected.detail.isEmpty { Text(selected.detail).font(.callout) }
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
                            TextEditor(text: $model.json).font(.system(.body, design: .monospaced)).frame(height: 190).border(.quaternary)
                            DisclosureGroup("Field reference") {
                                Text(selected.bodySchema).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        } else if selected.isBinary {
                            HStack {
                                Button("Choose File…") { chooseUpload() }
                                Text(model.upload?.lastPathComponent ?? "No file selected").font(.caption)
                            }
                        }
                        HStack {
                            Button(selected.isReadOnly ? "Read from Bar" : "Apply to Bar…") {
                                if selected.isReadOnly { Task { await model.execute(selected, client: state.client) } }
                                else { model.prepareConfirmation(selected, client: state.client) }
                            }.buttonStyle(.borderedProminent).disabled(model.working)
                            if model.working { ProgressView().controlSize(.small) }
                            Spacer()
                            Button("Save Response…") { saveResponse() }.disabled(model.responseData == nil)
                        }
                        if let error = model.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                        if !model.response.isEmpty {
                            Text("Response").font(.headline)
                            Text(model.response).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary)
                        }
                    }.padding(20)
                }
                .disabled(model.working)
                .alert("\(selected.title)?", isPresented: $model.confirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Apply") { Task { await model.applyConfirmed(client: state.client) } }
                } message: { Text("Send \(selected.method) \(selected.path) to \(model.confirmationHost ?? state.host) with the values shown. This changes the device. Network changes can disconnect it; firmware installation may restart it.") }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .onChange(of: selectedID) { _, _ in resetForm() }
        .onChange(of: state.host) { _, _ in resetForm() }
        .onChange(of: state.token) { _, _ in resetForm() }
        .onAppear { resetForm() }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 })
    }

    private func resetForm() { model.reset(for: selected) }

    private func chooseUpload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { if $0 == .OK { model.upload = panel.url } }
    }

    private func saveResponse() {
        guard let data = model.responseData else { return }
        exportFile(data, "busy-bar-response") { result in
            if case .failure(let error) = result { model.error = error.localizedDescription }
        }
    }

}
