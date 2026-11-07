import Foundation
import os

private let log = Logger(subsystem: "dev.barkeep.mac", category: "slack")

/// Mirrors the bar's busy state to Slack: sets a status + DND snooze when
/// busy starts, clears both when it ends. Needs a Slack user token (xoxp-…)
/// with users.profile:write and dnd:write scopes.
final class SlackSync: @unchecked Sendable {
    private let lock = NSLock()
    private var settings = (token: "", text: "On a call", emoji: ":headphones:")
    private var pending: Task<String?, Never>?
    private var sequence = 0
    var token: String {
        get { lock.withLock { settings.token } }
        set { lock.withLock { settings.token = newValue } }
    }
    var statusText: String {
        get { lock.withLock { settings.text } }
        set { lock.withLock { settings.text = newValue } }
    }
    var statusEmoji: String {
        get { lock.withLock { settings.emoji } }
        set { lock.withLock { settings.emoji = newValue } }
    }

    private let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func setBusy(_ busy: Bool) async -> String? {
        // Serialize complete profile + DND transactions. A quick call-end must
        // not be overtaken by the preceding call-start's slower DND request.
        let (task, id) = lock.withLock {
            let previous = pending
            let snapshot = settings
            sequence += 1
            let id = sequence
            let task = Task {
                _ = await previous?.value
                return await self.apply(busy, token:snapshot.token, text:snapshot.text, emoji:snapshot.emoji)
            }
            pending = task
            return (task, id)
        }
        let result = await task.value
        lock.withLock { if sequence == id { pending = nil } }
        return result
    }

    private func apply(_ busy: Bool, token: String, text: String, emoji: String) async -> String? {
        guard !token.isEmpty else { return nil }
        do {
            if busy {
                try await call("users.profile.set", token:token, body: [
                    "profile": [
                        "status_text": text,
                        "status_emoji": emoji,
                        "status_expiration": 0,
                    ],
                ])
                try await call("dnd.setSnooze", token:token, body: ["num_minutes": 120])
                log.info("slack status set")
            } else {
                try await call("users.profile.set", token:token, body: [
                    "profile": ["status_text": "", "status_emoji": ""],
                ])
                try await call("dnd.endSnooze", token:token, body: [:], allowError: "snooze_not_active")
                log.info("slack status cleared")
            }
            return nil
        } catch {
            log.error("slack sync failed: \(error.localizedDescription, privacy: .public)")
            return "Slack: \(error.localizedDescription)"
        }
    }

    private func call(_ method: String, token: String, body: [String: Any], allowError: String? = nil) async throws {
        var req = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BusyBarError(message: "Slack request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if json?["ok"] as? Bool != true {
            let error = json?["error"] as? String ?? "unknown error"
            if error == allowError { return }
            throw BusyBarError(message: "\(method): \(error)")
        }
    }
}
