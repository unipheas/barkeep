import Foundation
import Network

/// Performs an explicit local-network operation so macOS presents its privacy
/// prompt before the Busy Bar client begins making direct-IP requests.
final class LocalNetworkPermissionTrigger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.barkeep.local-network-permission")
    private var browser: NWBrowser?
    var onAccessAvailable: (@Sendable () -> Void)?

    func requestAccess() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: "_barkeep._tcp", domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onAccessAvailable?()
                self?.stop()
            case .failed, .cancelled:
                self?.stop()
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }
}
