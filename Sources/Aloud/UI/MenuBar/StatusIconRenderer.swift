import AppKit

/// Draws the menu bar glyph in code so idle/active states are just two
/// small data sets, no image assets to keep in sync.
enum StatusIconRenderer {
    private static let size = NSSize(width: 18, height: 18)

    static func idleImage() -> NSImage {
        makeImage(heights: [0.3, 0.55, 0.8, 0.55, 0.3], filled: false)
    }

    /// A short loop of frames for the pulsing "active" state.
    static func activeFrames() -> [NSImage] {
        let heightSets: [[CGFloat]] = [
            [0.3, 0.55, 0.8, 0.55, 0.3],
            [0.5, 0.8, 0.5, 0.8, 0.5],
            [0.8, 0.5, 0.3, 0.5, 0.8],
            [0.5, 0.8, 0.5, 0.8, 0.5],
        ]
        return heightSets.map { makeImage(heights: $0, filled: true) }
    }

    /// Renders into an explicit CGContext bitmap and wraps the resulting
    /// CGImage, rather than using NSImage(size:flipped:drawingHandler:) or
    /// lockFocus/unlockFocus — both produced an image that rendered fine
    /// locally but came out blank in the menu bar itself. Modern macOS
    /// hosts third-party status items out-of-process (Control Center), and
    /// a live/cached image representation apparently doesn't survive that
    /// handoff reliably; a fully-flattened CGImage-backed NSImage does.
    private static func makeImage(heights: [CGFloat], filled: Bool) -> NSImage {
        let scale: CGFloat = 2
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: size)
        }
        context.scaleBy(x: scale, y: scale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawWaveform(in: NSRect(origin: .zero, size: size), heights: heights, filled: filled)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else {
            return NSImage(size: size)
        }
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = true
        return image
    }

    private static func drawWaveform(in rect: NSRect, heights: [CGFloat], filled: Bool) {
        let barWidth: CGFloat = 2.2
        let spacing: CGFloat = 1.6
        let count = CGFloat(heights.count)
        let totalWidth = count * barWidth + (count - 1) * spacing
        var x = rect.midX - totalWidth / 2

        for h in heights {
            let barHeight = max(rect.height * h, barWidth)
            let barRect = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            if filled {
                NSColor.black.setFill()
                path.fill()
            } else {
                path.lineWidth = 1.1
                NSColor.black.withAlphaComponent(0.85).setStroke()
                path.stroke()
            }
            x += barWidth + spacing
        }
    }
}
