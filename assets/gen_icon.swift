// Generates the BarKeep app icon: 8-bit LED invader above a status bar,
// on a dark rounded square. Usage: swift gen_icon.swift <size> <out.png>
import AppKit

let size = CGFloat(Int(CommandLine.arguments[1])!)
let outPath = CommandLine.arguments[2]

// Logical 32x32 pixel grid.
let GRID = 32
var grid = [[String?]](repeating: [String?](repeating: nil, count: GRID), count: GRID)

let invader: [String] = [
    "..#.....#..",
    "...#...#...",
    "..#######..",
    ".##.###.##.",
    "###########",
    "#.#######.#",
    "#.#.....#.#",
    "...##.##...",
]

// Invader scaled 2x, centered horizontally, upper area.
let invW = invader[0].count * 2
let offX = (GRID - invW) / 2
let offY = 4
for (row, line) in invader.enumerated() {
    for (col, ch) in line.enumerated() where ch == "#" {
        for dy in 0..<2 {
            for dx in 0..<2 {
                grid[offY + row * 2 + dy][offX + col * 2 + dx] = "amber"
            }
        }
    }
}

// LED status bar below: green -> yellow -> red segments, 3 wide + 1 gap.
let segments = ["green", "green", "yellow", "yellow", "red", "red"]
let barY = 23
var x = offX - 1
for seg in segments {
    for dx in 0..<3 {
        for dy in 0..<3 {
            grid[barY + dy][x + dx] = seg
        }
    }
    x += 4
}

let palette: [String: NSColor] = [
    "amber":  NSColor(deviceRed: 1.00, green: 0.70, blue: 0.00, alpha: 1),
    "green":  NSColor(deviceRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
    "yellow": NSColor(deviceRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
    "red":    NSColor(deviceRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

// macOS-style rounded square with a small transparent margin.
let margin = size * 0.05
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let bg = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
NSColor(deviceRed: 0.08, green: 0.08, blue: 0.11, alpha: 1).setFill()
bg.fill()

// Pixel grid (flip y: grid row 0 is the top).
let cell = (size - margin * 2) / CGFloat(GRID)
for row in 0..<GRID {
    for col in 0..<GRID {
        guard let key = grid[row][col], let color = palette[key] else { continue }
        color.setFill()
        let px = margin + CGFloat(col) * cell
        let py = size - margin - CGFloat(row + 1) * cell
        CGRect(x: px, y: py, width: cell + 0.5, height: cell + 0.5).fill()
    }
}

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
