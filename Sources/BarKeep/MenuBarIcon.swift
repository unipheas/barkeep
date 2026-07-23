import AppKit

/// The BarKeep invader, rendered at menu-bar size from the same pixel
/// pattern as the app icon. Template (monochrome) when idle so it follows
/// the menu bar appearance; red when a busy session is active.
enum MenuBarIcon {
    private static let pattern: [String] = [
        "..#.....#..",
        "...#...#...",
        "..#######..",
        ".##.###.##.",
        "###########",
        "#.#######.#",
        "#.#.....#.#",
        "...##.##...",
    ]

    static let idle: NSImage = render(color: .black, template: true, alpha: 1)
    static let onCall: NSImage = render(color: NSColor(deviceRed: 1, green: 0.23, blue: 0.19, alpha: 1), template: false, alpha: 1)
    static let unreachable: NSImage = render(color: .black, template: true, alpha: 0.35)

    static func current(onCall active: Bool, reachable: Bool) -> NSImage {
        if !reachable { return unreachable }
        return active ? onCall : idle
    }

    private static func render(color: NSColor, template: Bool, alpha: CGFloat) -> NSImage {
        let cols = pattern[0].count
        let rows = pattern.count
        let cell: CGFloat = 1.5
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let offsetX = (size.width - CGFloat(cols) * cell) / 2
            let offsetY = (size.height - CGFloat(rows) * cell) / 2
            color.withAlphaComponent(alpha).setFill()
            for (row, line) in pattern.enumerated() {
                for (col, ch) in line.enumerated() where ch == "#" {
                    NSRect(
                        x: offsetX + CGFloat(col) * cell,
                        y: offsetY + CGFloat(row) * cell,
                        width: cell, height: cell
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
