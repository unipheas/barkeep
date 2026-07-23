import Foundation

/// Measures round-trip latency with one real ICMP ping per call.
enum PingMonitor {
    static func measure(host: String) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/ping")
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
