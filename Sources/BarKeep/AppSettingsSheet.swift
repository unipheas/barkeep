import SwiftUI

/// The settings sheet shares the app model so edits and save results remain in sync.
@MainActor
struct AppSettingsSheet: View {
    #if DEBUG
    // Inspect installed State in hosted interaction tests.
    internal var didAppear: ((Self) -> Void)?
    #endif
    @Bindable var model: DeviceAppsModel
    @State private var confirmReset = false
    @State private var advancedSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.settingsApp?.name ?? "App") Settings").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let schema = model.settingsSchema {
                        AppSettingsForm(fields: schema.fields, json: $model.settingsJSON)
                        DisclosureGroup("Advanced JSON", isExpanded: $advancedSettings) {
                            settingsEditor
                        }
                    } else { settingsEditor }
                }
            }.frame(height: 300)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Reset Defaults…") { confirmReset = true }
                Spacer()
                Button("Done") { model.closeSettings() }
                Button("Save") {
                    NSApp.keyWindow?.endEditing(for: nil)
                    Task {
                        await Task.yield()
                        await model.saveSettings()
                    }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 470).disabled(model.working)
            .alert("Reset app settings?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { Task { await model.resetSettings() } }
            } message: { Text("This replaces all settings with the app's defaults.") }
        #if DEBUG
        .onAppear { didAppear?(self) }
        #endif
    }

    private var settingsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep the version and all existing fields in this complete settings document.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.settingsJSON).font(.system(.body, design: .monospaced))
                .border(.quaternary).frame(height: 210)
        }
    }

}
