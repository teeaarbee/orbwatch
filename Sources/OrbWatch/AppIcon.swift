import AppKit

/// Draws the OrbWatch app icon procedurally — a radar/gauge "orb" on a blue→
/// purple squircle — so we get a crisp Dock icon (set at launch) and can export
/// a real .icns for the bundle without shipping binary art.
enum AppIcon {
    /// Renders the icon at `size`×`size` pixels.
    static func draw(_ size: CGFloat) {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)

        // Squircle background with a diagonal gradient.
        let inset = size * 0.06
        let body = rect.insetBy(dx: inset, dy: inset)
        let radius = size * 0.225
        let bg = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(
            colors: [
                NSColor(srgbRed: 0.18, green: 0.42, blue: 1.00, alpha: 1),
                NSColor(srgbRed: 0.52, green: 0.24, blue: 1.00, alpha: 1),
            ])!
        gradient.draw(in: bg, angle: -55)

        let center = NSPoint(x: size / 2, y: size / 2)

        // Concentric gauge rings.
        NSColor.white.withAlphaComponent(0.30).setStroke()
        for f in [0.34, 0.24, 0.14] {
            let r = size * f
            let ring = NSBezierPath(ovalIn: NSRect(
                x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = size * 0.012
            ring.stroke()
        }

        // Tick marks around the outer ring.
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let outer = size * 0.34
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi
            let p1 = NSPoint(x: center.x + cos(a) * outer,
                             y: center.y + sin(a) * outer)
            let p2 = NSPoint(x: center.x + cos(a) * (outer - size * 0.04),
                             y: center.y + sin(a) * (outer - size * 0.04))
            let tick = NSBezierPath()
            tick.move(to: p1); tick.line(to: p2)
            tick.lineWidth = size * 0.012
            tick.stroke()
        }

        // Needle pointing up-right.
        let angle: CGFloat = .pi * 0.32
        let tip = NSPoint(x: center.x + cos(angle) * size * 0.30,
                          y: center.y + sin(angle) * size * 0.30)
        let needle = NSBezierPath()
        needle.move(to: center); needle.line(to: tip)
        needle.lineWidth = size * 0.035
        needle.lineCapStyle = .round
        NSColor.white.setStroke()
        needle.stroke()

        // Hub.
        let hubR = size * 0.045
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hubR, y: center.y - hubR,
                                    width: hubR * 2, height: hubR * 2)).fill()
    }

    static func image(_ size: Int = 512) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        draw(CGFloat(size))
        img.unlockFocus()
        return img
    }

    private static func png(_ size: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// Writes an .iconset folder + compiles AppIcon.icns into `dir`.
    static func exportICNS(to dir: String) throws {
        let fm = FileManager.default
        let iconset = (dir as NSString).appendingPathComponent("AppIcon.iconset")
        try? fm.removeItem(atPath: iconset)
        try fm.createDirectory(atPath: iconset,
                               withIntermediateDirectories: true)
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        for s in sizes {
            let data = png(s)
            // 1x name; the @2x of half the size shares the pixels.
            try data.write(to: URL(fileURLWithPath:
                "\(iconset)/icon_\(s)x\(s).png"))
            if s >= 32 {
                try data.write(to: URL(fileURLWithPath:
                    "\(iconset)/icon_\(s/2)x\(s/2)@2x.png"))
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset, "-o",
                       "\(dir)/AppIcon.icns"]
        try p.run(); p.waitUntilExit()
    }
}
