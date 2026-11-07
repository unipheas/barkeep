import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AppsTab: View {
    @Environment(AppState.self) private var state
    @State private var model: DeviceAppsModel?

    var body: some View {
        Group {
            if let model { AppsContent(model: model) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: state.connectionRevision) {
            let model = DeviceAppsModel(client: state.client,
                launchAction: { client, app in try await state.launchDeviceApp(app, on: client) },
                stopAction: { state.resumeWidgets() },
                removeAction: { state.deviceAppRemoved($0) })
            self.model = model
            await model.refresh()
        }
    }
}

@MainActor
struct AppsContent: View {
    @Bindable var model: DeviceAppsModel
    @State private var removing: DeviceApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Apps on your bar").font(.subheadline.bold())
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Upload…") { choosePackage() }
            }
            .controlSize(.small)
            Text("Install a .tgz or .tar package built with Busy Tools. Apps run on the bar even when your Mac disconnects.")
                .font(.caption2).foregroundStyle(.secondary)

            if let staged = model.staged {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(staged.staged.name) · \(staged.staged.version)").font(.subheadline.bold())
                    Text(staged.staged.id).font(.caption2).textSelection(.enabled)
                    Text("By \(staged.staged.author) · API \(staged.staged.api_version)").font(.caption2)
                    if let old = staged.installed {
                        Text("Replaces installed version \(old.version).").font(.caption2).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Cancel") { model.cancelInstall() }
                        Spacer()
                        Button("Install App") { Task { await model.install() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.apps) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(app.name).font(.subheadline.bold())
                                Spacer()
                                Text(app.version).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(app.description).font(.caption2).foregroundStyle(.secondary)
                            Text(app.id).font(.caption2.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Run") { Task { await model.launch(app) } }
                                Button("Settings…") { Task { await model.loadSettings(app) } }
                                Spacer()
                                Button("Remove…", role: .destructive) { removing = app }
                            }.controlSize(.small)
                        }
                        Divider()
                    }
                    if model.loaded && model.apps.isEmpty {
                        Text("No apps installed. Upload an app package to get started.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 230)
            Button("Stop Running App") { Task { await model.stop() } }.controlSize(.small)

            if model.working { ProgressView("Working…").controlSize(.small).font(.caption) }
            if let message = model.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption2).foregroundStyle(.red).textSelection(.enabled) }
        }
        .disabled(model.working)
        .alert("Remove \(removing?.name ?? "app")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let app = removing { Task { await model.remove(app) } }
                removing = nil
            }
        } message: { Text("The app will be removed from your bar. Its saved settings will be kept.") }
        .sheet(isPresented: Binding(get: { model.settingsApp != nil }, set: { if !$0 { model.closeSettings() } })) {
            AppSettingsSheet(model: model)
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "Upload Busy Bar App"
        panel.allowedContentTypes = [UTType(filenameExtension: "tgz"), UTType(filenameExtension: "tar"), UTType.gzip].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.stage(url: url) }
        }
    }
}
