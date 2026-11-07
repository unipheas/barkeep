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
    @State private var lastPaintedCell: CanvasCell?

    private let cellSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                Toggle("Eraser", isOn: $erasing)
                    .toggleStyle(.button)
                Button("Clear Canvas") {
                    lastPaintedCell = nil
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
                .onEnded { _ in lastPaintedCell = nil }
        )
    }

    private func paint(at point: CGPoint) {
        guard point.x >= 0, point.y >= 0,
              point.x < CGFloat(Self.columns) * cellSize,
              point.y < CGFloat(Self.rows) * cellSize else {
            lastPaintedCell = nil
            return
        }
        let cell = CanvasCell(x: Int(point.x / cellSize), y: Int(point.y / cellSize))
        let hex = erasing ? nil : MessageRenderer.rgbaHex(from: NSColor(color))
        for pixel in CanvasCell.line(from: lastPaintedCell ?? cell, to: cell) {
            grid[pixel.y][pixel.x] = hex
        }
        lastPaintedCell = cell
    }
}

/// Connect successive input samples so fast drags leave a continuous stroke.
struct CanvasCell: Equatable {
    let x: Int
    let y: Int

    static func line(from start: Self, to end: Self) -> [Self] {
        var x = start.x, y = start.y
        let dx = abs(end.x - x), dy = -abs(end.y - y)
        let sx = x < end.x ? 1 : -1, sy = y < end.y ? 1 : -1
        var error = dx + dy
        var cells: [Self] = []
        while true {
            cells.append(Self(x: x, y: y))
            if x == end.x && y == end.y { return cells }
            let twiceError = 2 * error
            if twiceError >= dy { error += dy; x += sx }
            if twiceError <= dx { error += dx; y += sy }
        }
    }
}
