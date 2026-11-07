import Foundation
import Observation

struct DeviceApp: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let api_version: String
    let author: String
    let description: String
    let is_debug: Bool
    let icon_path: String?
}

struct StagedApp: Decodable {
    let install_key: UInt32
    let staged: DeviceApp
    let installed: DeviceApp?
}

extension BusyBarClient {
    func api(_ method: String, _ path: String, query: [String: String] = [:],
             body: Data? = nil, contentType: String = "application/json",
             timeout: TimeInterval = 6) async throws -> Data {
        var req = try request(method, path, query: query, body: body, contentType: contentType)
        req.timeoutInterval = timeout
        return try await send(req)
    }

    func apps() async throws -> [DeviceApp] {
        struct List: Decodable { let apps: [DeviceApp] }
        return try JSONDecoder().decode(List.self, from: await api("GET", "/apps/list")).apps
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func stageApp(_ data: Data) async throws -> StagedApp {
        guard !data.isEmpty else { throw BusyBarError(message: "The app package is empty.") }
        return try JSONDecoder().decode(StagedApp.self, from: await api(
            "POST", "/apps/stage", body: data, contentType: "application/octet-stream", timeout: 120))
    }

    func installApp(key: UInt32) async throws {
        _ = try await api("POST", "/apps/install", query: ["install_key": String(key)], timeout: 120)
    }

    func launchApp(id: String) async throws {
        _ = try await api("POST", "/apps/launch", query: appQuery(id))
    }

    func removeApp(id: String) async throws {
        _ = try await api("DELETE", "/apps", query: appQuery(id))
    }

    func quitApp() async throws { _ = try await api("POST", "/apps/quit") }

    func appSettings(id: String) async throws -> String {
        try Self.prettyJSON(await api("GET", "/apps/settings", query: appQuery(id)))
    }

    func saveAppSettings(id: String, json: String) async throws {
        let data = Data(json.utf8)
        let document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = document?["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue >= 1, version.doubleValue.rounded() == version.doubleValue,
              document?["values"] is [String: Any] else {
            throw BusyBarError(message: "Settings need an integer version and a values object. Load the current settings first.")
        }
        _ = try await api("PUT", "/apps/settings", query: appQuery(id), body: data)
    }

    func resetAppSettings(id: String) async throws {
        _ = try await api("DELETE", "/apps/settings", query: appQuery(id))
    }

    func appQuery(_ id: String) throws -> [String: String] {
        guard id.range(of: "^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,31}$", options: .regularExpression) != nil else {
            throw BusyBarError(message: "Invalid app ID. Use up to 32 letters, digits, dots, underscores or dashes; do not start with a dot.")
        }
        return ["app_id": id]
    }

    static func prettyJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return String(decoding: try JSONSerialization.data(withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}

@Observable @MainActor
final class DeviceAppsModel {
    private(set) var apps: [DeviceApp] = []
    private(set) var working = false
    private(set) var loaded = false
    private(set) var message: String?
    private(set) var error: String?
    private(set) var staged: StagedApp?
    private(set) var settingsApp: DeviceApp?
    var settingsJSON = ""
    private(set) var settingsSchema: AppSettingsSchema?
    private let client: BusyBarClient
    private let liveClient: BusyBarClient
    private let launchAction: ((BusyBarClient, DeviceApp) async throws -> Void)?
    private let stopAction: (() -> Void)?
    private let removeAction: ((DeviceApp) -> Void)?

    init(client: BusyBarClient,
         launchAction: ((BusyBarClient, DeviceApp) async throws -> Void)? = nil,
         stopAction: (() -> Void)? = nil,
         removeAction: ((DeviceApp) -> Void)? = nil) {
        self.liveClient = client; self.client = client.snapshot()
        self.launchAction = launchAction; self.stopAction = stopAction
        self.removeAction = removeAction
    }

    func refresh() async {
        await perform {
            self.apps = try await self.client.apps()
            self.loaded = true
        }
    }

    func stage(url: URL) async {
        await perform {
            self.staged = nil
            guard ["tgz", "tar", "gz"].contains(url.pathExtension.lowercased()) else {
                throw BusyBarError(message: "Choose a Busy Bar app package (.tgz or .tar).")
            }
            // Bound memory use before loading a selected file. Firmware validates the archive.
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 64 * 1024 * 1024 else { throw BusyBarError(message: "App packages must be under 64 MB.") }
            let host = self.client.host
            let staged = try await self.client.stageApp(Data(contentsOf: url))
            guard host == self.liveClient.host, self.client.token == self.liveClient.token else { throw BusyBarError(message: "Device changed during upload. Upload again.") }
            self.staged = staged
            self.message = "Ready to install \(staged.staged.name)."
        }
    }

    func cancelInstall() { staged = nil; message = nil }

    func install() async {
        guard let staged else { return }
        await perform {
            // Single-use key: discard even if the response is lost; do not retry blindly.
            self.cancelInstall()
            try await self.client.installApp(key: staged.install_key)
            self.message = "Installed \(staged.staged.name) \(staged.staged.version)."
            self.apps = try await self.client.apps()
            self.loaded = true
        }
    }

    func launch(_ app: DeviceApp) async {
        await perform {
            if let launchAction = self.launchAction { try await launchAction(self.client, app) }
            else { try await self.client.launchApp(id: app.id) }
            self.message = "Launched \(app.name)."
        }
    }

    func stop() async {
        await perform {
            try await self.client.quitApp()
            self.stopAction?()
            self.message = "App stopped."
        }
    }

    func remove(_ app: DeviceApp) async {
        await perform {
            try await self.client.removeApp(id: app.id)
            self.removeAction?(app)
            self.apps.removeAll { $0.id == app.id }
            if self.settingsApp?.id == app.id { self.closeSettings() }
            self.message = "Removed \(app.name). Its settings are preserved on the bar."
        }
    }

    func loadSettings(_ app: DeviceApp) async {
        await perform {
            self.closeSettings()
            let json = try await self.client.appSettings(id: app.id)
            self.settingsJSON = json
            // The optional schema lives with the package metadata. Older apps can still use JSON.
            if let data = try? await self.client.api("GET", "/storage/read",
                query: ["path": "/ext/user_assets/\(app.id)/appmeta/settings.json"]),
               let schema = try? JSONDecoder().decode(AppSettingsSchema.self, from: data),
               let document = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               document["version"] as? Int == schema.version {
                self.settingsSchema = schema
            }
            self.settingsApp = app
        }
    }

    func closeSettings() { settingsApp = nil; settingsJSON = ""; settingsSchema = nil }

    func saveSettings() async {
        guard let app = settingsApp else { return }
        await perform {
            try await self.client.saveAppSettings(id: app.id, json: self.settingsJSON)
            self.settingsJSON = try await self.client.appSettings(id: app.id)
            self.message = "Saved \(app.name) settings. Relaunch the app to apply them."
        }
    }

    func resetSettings() async {
        guard let app = settingsApp else { return }
        await perform {
            try await self.client.resetAppSettings(id: app.id)
            self.settingsJSON = try await self.client.appSettings(id: app.id)
            self.message = "Restored default settings."
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !working else { return }
        working = true; error = nil; message = nil
        defer { working = false }
        do {
            guard client.host == liveClient.host, client.token == liveClient.token else {
                cancelInstall(); closeSettings()
                throw BusyBarError(message: "Device changed. Refresh the Apps tab before continuing.")
            }
            try await operation()
        }
        catch {
            if let apiError = error as? BusyBarError, apiError.statusCode == 404 {
                self.error = "JS apps need Busy Bar firmware 1.3.1 or later. Check for a firmware update in Settings."
            } else { self.error = error.localizedDescription }
        }
    }
}
