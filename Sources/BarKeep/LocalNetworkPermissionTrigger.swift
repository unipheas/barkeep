import Foundation
import Network

protocol LocalNetworkBrowser: AnyObject {
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

extension NWBrowser: LocalNetworkBrowser {}

/// Performs an explicit local-network operation so macOS presents its privacy
/// prompt before the Busy Bar client begins making direct-IP requests.
@MainActor
final class LocalNetworkPermissionTrigger {
    private let queue = DispatchQueue(label: "dev.barkeep.local-network-permission")
    private var browser: (any LocalNetworkBrowser)?
    private let makeBrowser: () -> any LocalNetworkBrowser
    var onAccessAvailable: (@Sendable () -> Void)?

    init(makeBrowser: @escaping () -> any LocalNetworkBrowser = {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        return NWBrowser(for: .bonjour(type: "_barkeep._tcp", domain: nil), using: parameters)
    }) {
        self.makeBrowser = makeBrowser
    }

    func requestAccess() {
        guard browser == nil else { return }
        let browser = makeBrowser()
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready:
                    self.onAccessAvailable?()
                    self.stop()
                case .failed, .cancelled:
                    self.stop()
                default:
                    break
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }
}
