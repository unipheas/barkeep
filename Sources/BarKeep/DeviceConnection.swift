import Foundation

enum DeviceConnectionMode: String, CaseIterable, Identifiable {
    case usb, wifi
    var id: String { rawValue }
    var title: String { self == .usb ? "USB" : "Wi-Fi" }
}

/// Keep the Wi-Fi endpoint when USB is selected, including when migrating the
/// original single-host setting. USB never sends the saved Wi-Fi password.
struct DeviceConnection {
    static let usbHost = "10.0.4.20"
    var mode: DeviceConnectionMode
    var wifiHost: String
    var password: String

    init(defaults: UserDefaults) {
        let legacyHost = BusyBarClient.normalizedHost(defaults.string(forKey: "host") ?? Self.usbHost)
        mode = defaults.string(forKey: "connectionMode").flatMap(DeviceConnectionMode.init(rawValue:))
            ?? (legacyHost == Self.usbHost ? .usb : .wifi)
        wifiHost = defaults.string(forKey: "wifiHost") ?? (legacyHost == Self.usbHost ? "" : legacyHost)
        password = defaults.string(forKey: "token") ?? ""
    }

    var host: String {
        if mode == .usb { return Self.usbHost }
        let address = BusyBarClient.normalizedHost(wifiHost)
        // The USB interface is not a Wi-Fi route, even if pasted into this field.
        if BusyBarClient.webInterfaceURL(for: address)?.host == Self.usbHost { return "" }
        return address
    }
    var configurationHelp: String? {
        guard mode == .wifi, host.isEmpty else { return nil }
        return wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter the bar’s Wi-Fi address in Settings."
            : "Enter the bar’s Wi-Fi address in Settings. 10.0.4.20 is its USB address."
    }
    var token: String { mode == .wifi ? password : "" }
    var needsWiFiHost: Bool { mode == .wifi && host.isEmpty }

    func save(to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: "connectionMode")
        defaults.set(wifiHost, forKey: "wifiHost")
        defaults.set(password, forKey: "token")
        defaults.set(host, forKey: "host")
    }
}
