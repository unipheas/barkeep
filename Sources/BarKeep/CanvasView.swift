import SwiftUI

/// A 72x16 pixel-art canvas matching the Busy Bar front display.
@MainActor
struct CanvasView: View {
    @Environment(AppState.self) private var state

    static let columns = BusyBarClient.displayWidth
    static let rows = BusyBarClient.displayHeight

    @State private var grid: [[String?]] = Array(
        repeating: Array(repeating: nil, count: CanvasView.columns),
        count: CanvasView.rows
    )
    @State private var color = Color.red
    @State private var erasing = false
    @State private var timeoutSeconds = 30

    private let cellSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                Toggle("Eraser", isOn: $erasing)
                    .toggleStyle(.button)
                Button("Clear Canvas") {
                    grid = Array(
                        repeating: Array(repeating: nil, count: Self.columns),
                        count: Self.rows
                    )
                }
                Spacer()
                Picker("Show for", selection: $timeoutSeconds) {
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                    Text("2 min").tag(120)
                    Text("Until cleared").tag(0)
                }
                .frame(maxWidth: 180)
                Button("Send to Bar") {
                    state.sendDrawing(grid, timeoutSeconds: timeoutSeconds)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.onCall)
                .help(state.onCall ? "Unavailable during a busy session" : "")
            }
            if state.onCall {
                Text("Sending is unavailable while a busy session is active — the bar rejects drawing during sessions.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            canvas
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Click or drag to paint. The grid is exactly the bar's 72×16 front display.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(
            width: CGFloat(Self.columns) * cellSize + 32,
            height: CGFloat(Self.rows) * cellSize + 140
        )
    }

    private var canvas: some View {
        Canvas { context, _ in
            for y in 0..<Self.rows {
                for x in 0..<Self.columns {
                    let rect = CGRect(
                        x: CGFloat(x) * cellSize, y: CGFloat(y) * cellSize,
                        width: cellSize - 1, height: cellSize - 1
                    )
                    if let hex = grid[y][x], let nsColor = MessageRenderer.nsColor(fromRGBAHex: hex) {
                        context.fill(Path(rect), with: .color(Color(nsColor)))
                    } else {
                        context.fill(Path(rect), with: .color(Color(white: 0.14)))
                    }
                }
            }
        }
        .frame(
            width: CGFloat(Self.columns) * cellSize,
            height: CGFloat(Self.rows) * cellSize
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in paint(at: value.location) }
        )
    }

    private func paint(at point: CGPoint) {
        let x = Int(point.x / cellSize)
        let y = Int(point.y / cellSize)
        guard (0..<Self.columns).contains(x), (0..<Self.rows).contains(y) else { return }
        grid[y][x] = erasing ? nil : MessageRenderer.rgbaHex(from: NSColor(color))
    }
}
