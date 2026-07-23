import Foundation
import os

private let log = Logger(subsystem: "dev.barkeep.mac", category: "slack")

/// Mirrors the bar's busy state to Slack: sets a status + DND snooze when
/// busy starts, clears both when it ends. Needs a Slack user token (xoxp-…)
/// with users.profile:write and dnd:write scopes.
final class SlackSync: @unchecked Sendable {
    var token: String = ""
    var statusText: String = "On a call"
    var statusEmoji: String = ":headphones:"

    private let session = URLSession(configuration: .ephemeral)

    func setBusy(_ busy: Bool) async -> String? {
        guard !token.isEmpty else { return nil }
        do {
            if busy {
                try await call("users.profile.set", body: [
                    "profile": [
                        "status_text": statusText,
                        "status_emoji": statusEmoji,
                        "status_expiration": 0,
                    ],
                ])
                try await call("dnd.setSnooze", body: ["num_minutes": 120])
                log.info("slack status set")
            } else {
                try await call("users.profile.set", body: [
                    "profile": ["status_text": "", "status_emoji": ""],
                ])
                try await call("dnd.endSnooze", body: [:], allowError: "snooze_not_active")
                log.info("slack status cleared")
            }
            return nil
        } catch {
            log.error("slack sync failed: \(error.localizedDescription, privacy: .public)")
            return "Slack: \(error.localizedDescription)"
        }
    }

    private func call(_ method: String, body: [String: Any], allowError: String? = nil) async throws {
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        let (data, _) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["ok"] as? Bool != true {
            let error = json?["error"] as? String ?? "unknown error"
            if error == allowError { return }
            throw BusyBarError(message: "\(method): \(error)")
        }
    }
}
