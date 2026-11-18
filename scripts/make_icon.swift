// Renders the Debrief app icon (cute, flat style).
//   swift scripts/make_icon.swift <out-dir> [variant]      variant: mic | bubble | buddy | all (default: all)
// Writes <out-dir>/AppIcon-<variant>-1024.png, and with "all" also <out-dir>/icon-options.png,
// a comparison sheet with each option at large and small (Dock / menu) sizes.
import AppKit

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let which = args.count > 2 ? args[2] : "all"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let ink = rgb(0x3B2F3F)          // eyes / mouth
let rad = { (d: CGFloat) in d * .pi / 180 }

struct Painter {
    let ctx: CGContext

    func background(_ top: UInt32, _ bottom: UInt32) {
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        // Gradient and highlight in one transparency layer that casts the shadow, so no
        // separately filled base shape can peek out along the anti-aliased corners.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.22))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 250, y: 924), end: CGPoint(x: 774, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Soft glossy highlight in the top-left.
        let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                               endCenter: CGPoint(x: 300, y: 820), endRadius: 420, options: [])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// White shape with a soft drop shadow.
    func whiteShape(_ path: CGPath, shadow: CGFloat = 0.18) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x000000, shadow))
        ctx.addPath(path); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
    }

    func dot(_ c: CGPoint, _ r: CGFloat, _ color: CGColor) {
        ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    func blush(_ c: CGPoint, _ color: CGColor) {
        ctx.setFillColor(color); ctx.fillEllipse(in: CGRect(x: c.x - 30, y: c.y - 16, width: 60, height: 32))
    }

    func arc(_ c: CGPoint, _ r: CGFloat, from a: CGFloat, to b: CGFloat, width: CGFloat, color: CGColor) {
        let p = CGMutablePath()
        p.addArc(center: c, radius: r, startAngle: rad(a), endAngle: rad(b), clockwise: false)
        ctx.addPath(p); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.strokePath()
    }

    /// Four-point sparkle.
    func sparkle(_ c: CGPoint, _ s: CGFloat, _ color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y + s))
        p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + s * 0.18, y: c.y + s * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x + s * 0.18, y: c.y - s * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - s * 0.18, y: c.y - s * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x - s * 0.18, y: c.y + s * 0.18))
        ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
    }
}

/// A: a little microphone with a face.
func drawMic(_ p: Painter) {
    p.background(0xFFC3A0, 0xFF7A9C)
    let ctx = p.ctx
    // Stand: U-shaped holder, stem and base.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x000000, 0.15))
    p.arc(CGPoint(x: 512, y: 540), 196, from: 200, to: 340, width: 36, color: rgb(0xFFFFFF))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fill(CGRect(x: 494, y: 250, width: 36, height: 100))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 392, y: 222, width: 240, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    // Mic capsule.
    p.whiteShape(CGPath(roundedRect: CGRect(x: 367, y: 420, width: 290, height: 400), cornerWidth: 145, cornerHeight: 145, transform: nil))
    // Grille stripes, very light.
    for y in [740.0, 705.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 440, y: y, width: 144, height: 12), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(rgb(0xFF7A9C, 0.25)); ctx.fillPath()
    }
    // Face.
    p.dot(CGPoint(x: 462, y: 610), 22, ink)
    p.dot(CGPoint(x: 562, y: 610), 22, ink)
    p.dot(CGPoint(x: 469, y: 618), 7, rgb(0xFFFFFF))
    p.dot(CGPoint(x: 569, y: 618), 7, rgb(0xFFFFFF))
    p.blush(CGPoint(x: 424, y: 562), rgb(0xFF8FA8, 0.65))
    p.blush(CGPoint(x: 600, y: 562), rgb(0xFF8FA8, 0.65))
    p.arc(CGPoint(x: 512, y: 586), 28, from: 205, to: 335, width: 12, color: ink)
}

/// B: a happy speech bubble with a sparkle (a conversation, reviewed).
func drawBubble(_ p: Painter) {
    p.background(0x9BF2D5, 0x3DB8B0)
    let ctx = p.ctx
    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: CGRect(x: 250, y: 360, width: 524, height: 410), cornerWidth: 160, cornerHeight: 160)
    // Tail at the bottom left.
    bubble.move(to: CGPoint(x: 340, y: 400))
    bubble.addQuadCurve(to: CGPoint(x: 290, y: 280), control: CGPoint(x: 330, y: 330))
    bubble.addQuadCurve(to: CGPoint(x: 450, y: 375), control: CGPoint(x: 380, y: 300))
    bubble.closeSubpath()
    p.whiteShape(bubble)
    // Happy closed eyes (^ ^), blush, smile.
    p.arc(CGPoint(x: 432, y: 570), 32, from: 25, to: 155, width: 15, color: ink)
    p.arc(CGPoint(x: 592, y: 570), 32, from: 25, to: 155, width: 15, color: ink)
    p.blush(CGPoint(x: 392, y: 520), rgb(0xFF9EB1, 0.7))
    p.blush(CGPoint(x: 632, y: 520), rgb(0xFF9EB1, 0.7))
    p.arc(CGPoint(x: 512, y: 540), 40, from: 205, to: 335, width: 14, color: ink)
    p.sparkle(CGPoint(x: 760, y: 790), 70, rgb(0xFFD25E))
    p.sparkle(CGPoint(x: 842, y: 690), 34, rgb(0xFFFFFF, 0.9))
}

/// C: a round buddy wearing headphones (listens to your interview with you).
func drawBuddy(_ p: Painter) {
    p.background(0xC7B6FF, 0x7FB8FF)
    let ctx = p.ctx
    let pink = rgb(0xFF7FA8)
    p.whiteShape(CGPath(ellipseIn: CGRect(x: 287, y: 250, width: 450, height: 420), transform: nil))
    // Headband over the top, ear cups on the sides.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.15))
    p.arc(CGPoint(x: 512, y: 470), 262, from: 8, to: 172, width: 44, color: pink)
    for x in [214.0, 732.0] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 390, width: 78, height: 170), cornerWidth: 39, cornerHeight: 39, transform: nil))
        ctx.setFillColor(pink); ctx.fillPath()
    }
    ctx.restoreGState()
    // Face.
    p.dot(CGPoint(x: 450, y: 480), 24, ink)
    p.dot(CGPoint(x: 574, y: 480), 24, ink)
    p.dot(CGPoint(x: 458, y: 489), 8, rgb(0xFFFFFF))
    p.dot(CGPoint(x: 582, y: 489), 8, rgb(0xFFFFFF))
    p.blush(CGPoint(x: 408, y: 428), rgb(0xFF9EB8, 0.65))
    p.blush(CGPoint(x: 616, y: 428), rgb(0xFF9EB8, 0.65))
    p.arc(CGPoint(x: 512, y: 452), 30, from: 205, to: 335, width: 12, color: ink)
    // Little sound waves.
    p.arc(CGPoint(x: 512, y: 470), 330, from: -12, to: 12, width: 18, color: rgb(0xFFFFFF, 0.85))
    p.arc(CGPoint(x: 512, y: 470), 380, from: -9, to: 9, width: 18, color: rgb(0xFFFFFF, 0.6))
}

func render(_ draw: (Painter) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(Painter(ctx: NSGraphicsContext.current!.cgContext))
    NSGraphicsContext.current = nil
    return rep
}

let variants: [(String, String, (Painter) -> Void)] = [
    ("mic", "A  小麦克风", drawMic), ("bubble", "B  开心气泡", drawBubble), ("buddy", "C  耳机团子", drawBuddy),
]
var reps: [(String, NSBitmapImageRep)] = []
for (key, label, draw) in variants where which == "all" || which == key {
    let rep = render(draw)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("AppIcon-\(key)-1024.png"))
    reps.append((label, rep))
}

if which == "all" {
    // Comparison sheet: each option at 300 px, then at Dock (64) and menu (32) sizes, on light and dark.
    let w = 1080, h = 560
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(rgb(0xF5F5F7)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(rgb(0x1E1E1E)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: 110))
    for (i, (label, rep)) in reps.enumerated() {
        let x = CGFloat(30 + i * 350)
        let img = rep.cgImage!
        ctx.draw(img, in: CGRect(x: x, y: 190, width: 300, height: 300))
        ctx.draw(img, in: CGRect(x: x + 60, y: 25, width: 64, height: 64))       // dark backdrop
        ctx.draw(img, in: CGRect(x: x + 160, y: 41, width: 32, height: 32))
        ctx.draw(img, in: CGRect(x: x + 220, y: 125, width: 48, height: 48))     // light backdrop
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black]
        NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: x + 20, y: 500))
    }
    NSGraphicsContext.current = nil
    try! sheet.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent("icon-options.png"))
}
print("done")
