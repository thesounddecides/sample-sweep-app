// Renders the 1200x630 Open Graph card for /sample-sweep, in the same family
// as the site's og-default.jpg: near-black ground, one line of headline,
// one line of mono tagline. Usage: make-og-card <icon.png> <out.jpg>
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-og-card <icon.png> <out.jpg>"); exit(2) }
let iconPath = args[1], outPath = args[2]

let W: CGFloat = 1200, H: CGFloat = 630
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Ground: same near-black radial as the Composure card.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.06, green: 0.065, blue: 0.075, alpha: 1).cgColor,
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: CGPoint(x: W / 2, y: H * 0.62), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H * 0.62), endRadius: W * 0.62, options: [])

// Icon, with a soft glow beneath so it sits in the dark like the wordmark does.
if let icon = NSImage(contentsOfFile: iconPath) {
    let size: CGFloat = 220
    let rect = CGRect(x: W / 2 - size / 2, y: H - 92 - size, width: size, height: size)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60,
                  color: NSColor(calibratedRed: 0.42, green: 0.85, blue: 0.60, alpha: 0.28).cgColor)
    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()
    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

func draw(_ text: String, font: NSFont, color: NSColor, y: CGFloat, tracking: CGFloat = 0) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
    if tracking != 0 { attrs[.kern] = tracking }
    let s = NSAttributedString(string: text, attributes: attrs)
    let h = s.size().height
    s.draw(in: CGRect(x: 0, y: y - h / 2, width: W, height: h + 6))
}

draw("Sample Sweep",
     font: NSFont.systemFont(ofSize: 74, weight: .semibold),
     color: NSColor(white: 0.97, alpha: 1), y: 232)
draw("Find unused samples in your Ableton projects",
     font: NSFont.systemFont(ofSize: 34, weight: .regular),
     color: NSColor(calibratedRed: 0.72, green: 0.78, blue: 0.86, alpha: 1), y: 152)
draw("FREE FOR MACOS  ·  BY SOUND DECISIONS",
     font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium),
     color: NSColor(white: 0.55, alpha: 1), y: 90, tracking: 3)

NSGraphicsContext.restoreGraphicsState()
let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
try! jpg.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
