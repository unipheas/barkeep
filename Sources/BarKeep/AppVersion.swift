import Foundation

enum AppVersion {
    static var current: String {
        displayVersion(from: Bundle.main.infoDictionary)
    }

    static func displayVersion(from info: [String: Any]?) -> String {
        info?["CFBundleShortVersionString"] as? String ?? "development"
    }
}
