import AppKit

/// Renders text containing emoji or other non-ASCII characters into a
/// 72x16 PNG for the Busy Bar front display (device text elements only
/// accept printable ASCII).
enum MessageRenderer {
    static func isPlainASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }
    }

    static func renderToPNG(_ text: String, colorHex: String) -> Data? {
        let width = BusyBarClient.displayWidth
        let height = BusyBarClient.displayHeight

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: nsColor(fromRGBAHex: colorHex) ?? .white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var textSize = attributed.size()
        textSize.width = ceil(textSize.width)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let scale = min(1, CGFloat(width) / max(textSize.width, 1))
        let drawWidth = textSize.width * scale
        let drawHeight = textSize.height * scale
        context.cgContext.saveGState()
        context.cgContext.translateBy(
            x: (CGFloat(width) - drawWidth) / 2,
            y: (CGFloat(height) - drawHeight) / 2
        )
        context.cgContext.scaleBy(x: scale, y: scale)
        attributed.draw(at: .zero)
        context.cgContext.restoreGState()
        context.flushGraphics()

        return rep.representation(using: .png, properties: [:])
    }

    /// Renders a single emoji into a square PNG icon (for the 16px display rows).
    static func renderEmojiIcon(_ emoji: String, size: Int = 16) -> Data? {
        let attributed = NSAttributedString(string: emoji, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(size) - 3),
        ])
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let textSize = attributed.size()
        attributed.draw(at: NSPoint(
            x: (CGFloat(size) - textSize.width) / 2,
            y: (CGFloat(size) - textSize.height) / 2
        ))
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// Encodes a pixel grid (row-major, hex color strings or nil for off) as a PNG.
    static func renderGridToPNG(_ grid: [[String?]]) -> Data? {
        let height = grid.count
        let width = grid.first?.count ?? 0
        guard width > 0, height > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        for y in 0..<height {
            for x in 0..<width {
                let color = grid[y][x].flatMap { nsColor(fromRGBAHex: $0) } ?? .black
                rep.setColor(color, atX: x, y: y)
            }
        }
        return rep.representation(using: .png, properties: [:])
    }

    static func nsColor(fromRGBAHex hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 8, let raw = UInt64(value, radix: 16) else { return nil }
        return NSColor(
            deviceRed: CGFloat((raw >> 24) & 0xFF) / 255,
            green: CGFloat((raw >> 16) & 0xFF) / 255,
            blue: CGFloat((raw >> 8) & 0xFF) / 255,
            alpha: CGFloat(raw & 0xFF) / 255
        )
    }

    static func rgbaHex(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        return String(
            format: "#%02X%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255)),
            Int(round(rgb.alphaComponent * 255))
        )
    }
}
