import ServiceManagement

/// Keep OS registration at a boundary so failure feedback can be tested without
/// changing Login Items or requiring a real permission failure.
@MainActor struct LoginItemService {
    var isEnabled: () -> Bool
    var setEnabled: (Bool) throws -> Void

    static var live: Self {
        Self(isEnabled: { SMAppService.mainApp.status == .enabled }, setEnabled: { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        })
    }
}
