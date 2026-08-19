// Generates the dmg window background: 600x400, matching the Finder window
// bounds set in make-dmg.sh. Icon slots sit at x=150 and x=450, y=185.
import AppKit

let W: CGFloat = 600, H: CGFloat = 400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Backdrop, same palette as the app icon.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.20, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

let accent = NSColor(calibratedRed: 0.42, green: 0.85, blue: 0.60, alpha: 1)

// Arrow between the two icon slots. Finder's y runs from the top; these are
// CoreGraphics coords, so the slot centre y=185-from-top is H-185 here.
let midY = H - 185
ctx.setStrokeColor(accent.withAlphaComponent(0.55).cgColor)
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 252, y: midY))
ctx.addLine(to: CGPoint(x: 342, y: midY))
ctx.strokePath()
ctx.setFillColor(accent.withAlphaComponent(0.55).cgColor)
ctx.move(to: CGPoint(x: 356, y: midY))
ctx.addLine(to: CGPoint(x: 340, y: midY + 9))
ctx.addLine(to: CGPoint(x: 340, y: midY - 9))
ctx.closePath()
ctx.fillPath()

func draw(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
          _ color: NSColor, centeredAt x: CGFloat, y: CGFloat) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: style,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let bounds = s.size()
    s.draw(in: CGRect(x: x - 200, y: y - bounds.height / 2, width: 400, height: bounds.height + 4))
}

draw("Sample Sweep", 21, .semibold, NSColor(white: 0.96, alpha: 1), centeredAt: W / 2, y: H - 58)
draw("Drag the app into your Applications folder", 13, .regular,
     NSColor(white: 0.62, alpha: 1), centeredAt: W / 2, y: H - 84)
draw("by Sound Decisions", 11, .regular, NSColor(white: 0.42, alpha: 1),
     centeredAt: W / 2, y: 34)

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("background written to \(out)")
