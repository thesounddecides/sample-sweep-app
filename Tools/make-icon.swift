// Draws the Sample Sweep icon: an audio file being swept into a dustpan.
// Everything is laid out in a 1024x1024 space and scaled down per size.
import AppKit

let accent   = NSColor(calibratedRed: 0.42, green: 0.85, blue: 0.60, alpha: 1)
let handleUp = NSColor(calibratedRed: 0.83, green: 0.64, blue: 0.36, alpha: 1)
let handleLo = NSColor(calibratedRed: 0.66, green: 0.47, blue: 0.24, alpha: 1)
let bristle  = NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.42, alpha: 1)
let panFace  = NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.74, alpha: 1)
let panDark  = NSColor(calibratedRed: 0.40, green: 0.45, blue: 0.52, alpha: 1)

func rotated(_ ctx: CGContext, degrees: CGFloat, about: CGPoint, _ body: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: about.x, y: about.y)
    ctx.rotate(by: degrees * .pi / 180)
    ctx.translateBy(x: -about.x, y: -about.y)
    body()
    ctx.restoreGState()
}

func drawArtwork(_ ctx: CGContext) {
    // ---- backdrop -------------------------------------------------------
    let inset: CGFloat = 56
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let round = CGPath(roundedRect: rect, cornerWidth: 225, cornerHeight: 225, transform: nil)
    ctx.saveGState(); ctx.addPath(round); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.20, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])

    // ---- dustpan (right side, opening to the left) ----------------------
    let panBottomY: CGFloat = 250
    let panBackX: CGFloat = 838
    let lipTipX: CGFloat = 470

    // Thin ramp/lip the file slides over.
    let lip = CGMutablePath()
    lip.move(to: CGPoint(x: lipTipX, y: panBottomY))
    lip.addLine(to: CGPoint(x: 640, y: panBottomY + 34))
    lip.addLine(to: CGPoint(x: 640, y: panBottomY))
    lip.closeSubpath()
    ctx.addPath(lip); ctx.setFillColor(panDark.cgColor); ctx.fillPath()

    // Pan body.
    let pan = CGMutablePath()
    pan.move(to: CGPoint(x: lipTipX, y: panBottomY))
    pan.addLine(to: CGPoint(x: panBackX, y: panBottomY))
    pan.addLine(to: CGPoint(x: panBackX, y: panBottomY + 250))
    pan.addLine(to: CGPoint(x: 648, y: panBottomY + 96))
    pan.closeSubpath()
    ctx.addPath(pan); ctx.setFillColor(panFace.cgColor); ctx.fillPath()

    // Inner shadow on the pan floor, so it reads as a container.
    let floor = CGMutablePath()
    floor.move(to: CGPoint(x: lipTipX + 30, y: panBottomY + 6))
    floor.addLine(to: CGPoint(x: panBackX - 8, y: panBottomY + 6))
    floor.addLine(to: CGPoint(x: panBackX - 8, y: panBottomY + 58))
    floor.closeSubpath()
    ctx.addPath(floor); ctx.setFillColor(panDark.withAlphaComponent(0.55).cgColor); ctx.fillPath()

    // Back wall, lifted a shade so the pan has depth.
    let wall = CGMutablePath()
    wall.move(to: CGPoint(x: panBackX - 46, y: panBottomY))
    wall.addLine(to: CGPoint(x: panBackX, y: panBottomY))
    wall.addLine(to: CGPoint(x: panBackX, y: panBottomY + 250))
    wall.addLine(to: CGPoint(x: panBackX - 46, y: panBottomY + 222))
    wall.closeSubpath()
    ctx.addPath(wall); ctx.setFillColor(panDark.cgColor); ctx.fillPath()

    // Handle stub.
    ctx.setStrokeColor(panDark.cgColor)
    ctx.setLineWidth(30); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: panBackX + 4, y: panBottomY + 190))
    ctx.addLine(to: CGPoint(x: panBackX + 78, y: panBottomY + 236))
    ctx.strokePath()

    // ---- broom (upper left, mid-stroke) ---------------------------------
    rotated(ctx, degrees: 0, about: .zero) {
        // Handle.
        let handle = CGMutablePath()
        handle.move(to: CGPoint(x: 172, y: 893))
        handle.addLine(to: CGPoint(x: 346, y: 689))
        ctx.addPath(handle)
        ctx.setStrokeColor(handleUp.cgColor)
        ctx.setLineWidth(44); ctx.setLineCap(.round)
        ctx.strokePath()

        // Bristle head, square to the handle.
        rotated(ctx, degrees: 41, about: CGPoint(x: 384, y: 645)) {
            let collar = CGRect(x: 384 - 104, y: 645 - 34, width: 208, height: 68)
            ctx.addPath(CGPath(roundedRect: collar, cornerWidth: 26, cornerHeight: 26, transform: nil))
            ctx.setFillColor(handleLo.cgColor); ctx.fillPath()

            let head = CGRect(x: 384 - 122, y: 645 - 168, width: 244, height: 142)
            ctx.addPath(CGPath(roundedRect: head, cornerWidth: 22, cornerHeight: 22, transform: nil))
            ctx.setFillColor(bristle.cgColor); ctx.fillPath()

            ctx.setStrokeColor(handleLo.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(9)
            for i in 1...4 {
                let x = 384 - 122 + CGFloat(i) * 48.8
                ctx.move(to: CGPoint(x: x, y: 645 - 158))
                ctx.addLine(to: CGPoint(x: x, y: 645 - 44))
            }
            ctx.strokePath()
        }
    }

    // ---- motion lines trailing the broom --------------------------------
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(13)
    for (dx, dy, len) in [(CGFloat(0), CGFloat(0), CGFloat(96)),
                          (46, 52, 132),
                          (96, 100, 96)] {
        ctx.move(to: CGPoint(x: 150 + dx, y: 560 + dy))
        ctx.addLine(to: CGPoint(x: 150 + dx + len, y: 560 + dy))
        ctx.strokePath()
    }

    // ---- the audio file, tumbling into the pan --------------------------
    rotated(ctx, degrees: -21, about: CGPoint(x: 636, y: 498)) {
        let card = CGRect(x: 636 - 108, y: 498 - 134, width: 216, height: 268)
        let fold: CGFloat = 62

        let page = CGMutablePath()
        page.move(to: CGPoint(x: card.minX + 16, y: card.minY))
        page.addLine(to: CGPoint(x: card.maxX - 16, y: card.minY))
        page.addQuadCurve(to: CGPoint(x: card.maxX, y: card.minY + 16),
                          control: CGPoint(x: card.maxX, y: card.minY))
        page.addLine(to: CGPoint(x: card.maxX, y: card.maxY - fold))
        page.addLine(to: CGPoint(x: card.maxX - fold, y: card.maxY))
        page.addLine(to: CGPoint(x: card.minX + 16, y: card.maxY))
        page.addQuadCurve(to: CGPoint(x: card.minX, y: card.maxY - 16),
                          control: CGPoint(x: card.minX, y: card.maxY))
        page.addLine(to: CGPoint(x: card.minX, y: card.minY + 16))
        page.addQuadCurve(to: CGPoint(x: card.minX + 16, y: card.minY),
                          control: CGPoint(x: card.minX, y: card.minY))
        page.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(page); ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()

        // Folded corner.
        let corner = CGMutablePath()
        corner.move(to: CGPoint(x: card.maxX, y: card.maxY - fold))
        corner.addLine(to: CGPoint(x: card.maxX - fold, y: card.maxY - fold))
        corner.addLine(to: CGPoint(x: card.maxX - fold, y: card.maxY))
        corner.closeSubpath()
        ctx.addPath(corner); ctx.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor); ctx.fillPath()

        // Waveform on the page.
        let bars: [CGFloat] = [0.30, 0.62, 0.94, 0.50, 0.78, 0.36]
        let barW: CGFloat = 19, gap: CGFloat = 12
        let span = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
        var x = card.midX - span / 2
        let midY = card.midY - 14
        for h in bars {
            let bh = 128 * h
            let r = CGRect(x: x, y: midY - bh / 2, width: barW, height: bh)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
            ctx.setFillColor(accent.cgColor); ctx.fillPath()
            x += barW + gap
        }
    }
    ctx.restoreGState()
}

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    drawArtwork(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (px, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                   (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                   (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                   (1024, "icon_512x512@2x")] {
    let data = render(size: CGFloat(px)).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset written to \(out)")
