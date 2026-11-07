import Foundation

/// Measures round-trip latency with one real ICMP ping per call.
enum PingMonitor {
    static func measure(host: String, executableURL: URL = URL(fileURLWithPath: "/sbin/ping")) async -> Double? {
        // Process arguments are never shell-expanded, and an address cannot become
        // a ping option (for example an accidentally pasted "-f").
        guard host.range(of: "^[A-Za-z0-9_:][A-Za-z0-9_.:%-]{0,252}$", options: .regularExpression) != nil else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = ["-c", "1", "-t", "2", host]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8),
                      let range = output.range(of: "time=[0-9.]+", options: .regularExpression),
                      let ms = Double(output[range].dropFirst("time=".count)) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ms)
            }
        }
    }
}
