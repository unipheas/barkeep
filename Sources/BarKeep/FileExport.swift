import AppKit

/// Shared native export flow. Cancellation does not modify the destination or UI error.
@MainActor enum FileExport {
    typealias Completion = (Result<Void, Error>) -> Void
    typealias Handler = @MainActor (Data, String, @escaping Completion) -> Void

    static func present(_ data: Data, suggestedName: String, completion: @escaping Completion) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(write(data, to: url))
        }
    }

    static func write(_ data: Data, to url: URL) -> Result<Void, Error> {
        Result { try data.write(to: url, options: .atomic) }
    }
}
