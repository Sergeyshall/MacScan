// Renders Resources/AppIcon.icns: a glossy red apple under a chrome loupe, in the 2007–2010 Aqua style.
// Run: swift scripts/make-icon.swift  (needs only CoreGraphics; output is committed)
import AppKit

let size = 1024.0
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
    CGGradient(colorsSpace: space, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
}

// Leopard-era (2007–2010) style: a freeform glossy object, no tile, soft ground shadow.

func fill(_ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func stops(_ list: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: list.map { color($0.0, $0.1) } as CFArray, locations: list.map(\.2))!
}

// Relative sizes of the two objects, and the scale that fits the whole scene in the icon.
let appleScale = 2.3, loupeScale = 1.5, fit = 0.78
ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: fit, y: fit); ctx.translateBy(x: -430, y: -490)

// Ground shadow
ctx.saveGState()
ctx.translateBy(x: 430, y: 0); ctx.scaleBy(x: 1, y: 0.16)
ctx.drawRadialGradient(stops([(0x000000, 0.45, 0), (0x000000, 0, 1)]), startCenter: .zero, startRadius: 0,
                       endCenter: .zero, endRadius: 560, options: [])
ctx.restoreGState()

/// Glossy red apple with leaf, centered at c, scaled by s.
func drawApple(_ c: CGPoint, _ s: Double) {
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    let body = CGMutablePath()
    body.move(to: p(0, 150))
    body.addCurve(to: p(200, 40), control1: p(70, 215), control2: p(205, 200))
    body.addCurve(to: p(45, -205), control1: p(200, -110), control2: p(115, -210))
    body.addQuadCurve(to: p(-45, -205), control: p(0, -180))
    body.addCurve(to: p(-200, 40), control1: p(-115, -210), control2: p(-200, -110))
    body.addCurve(to: p(0, 150), control1: p(-205, 200), control2: p(-70, 215))
    body.closeSubpath()

    // Body: radial shading, lit from the upper left
    ctx.saveGState(); ctx.addPath(body); ctx.clip()
    ctx.drawRadialGradient(stops([(0xFF8A80, 1, 0), (0xE8202A, 1, 0.45), (0x9E0B14, 1, 0.85), (0x5C0309, 1, 1)]),
                           startCenter: p(-70, 70), startRadius: 0, endCenter: p(10, -10), endRadius: 260 * s, options: [.drawsAfterEndLocation])
    // Warm reflected light along the bottom edge
    ctx.drawRadialGradient(stops([(0xFF6A3D, 0.45, 0), (0xFF6A3D, 0, 1)]),
                           startCenter: p(40, -230), startRadius: 0, endCenter: p(40, -230), endRadius: 150 * s, options: [])
    ctx.restoreGState()

    // Glossy specular highlight (the Aqua "wet" look)
    let gloss = CGPath(ellipseIn: CGRect(origin: p(-150, 40), size: CGSize(width: 190 * s, height: 140 * s)), transform: nil)
    fill(gloss, stops([(0xFFFFFF, 0.85, 0), (0xFFFFFF, 0.0, 1)]), from: p(-60, 180), to: p(-60, 40))
    ctx.addEllipse(in: CGRect(origin: p(-118, 105), size: CGSize(width: 42 * s, height: 30 * s)))
    ctx.setFillColor(color(0xFFFFFF, 0.9)); ctx.fillPath()

    // Stem
    let stem = CGMutablePath()
    stem.move(to: p(0, 140)); stem.addQuadCurve(to: p(28, 255), control: p(-8, 205))
    let stemOutline = stem.copy(strokingWithWidth: 22 * s, lineCap: .round, lineJoin: .round, miterLimit: 1)
    fill(stemOutline, stops([(0x8B5A2B, 1, 0), (0x3B220E, 1, 1)]), from: p(-12, 200), to: p(20, 200))

    // Leaf with vein
    ctx.saveGState()
    ctx.translateBy(x: p(105, 230).x, y: p(105, 230).y); ctx.rotate(by: .pi / 7)
    let leaf = CGMutablePath()
    leaf.move(to: CGPoint(x: -80 * s, y: 0))
    leaf.addQuadCurve(to: CGPoint(x: 80 * s, y: 0), control: CGPoint(x: 0, y: 70 * s))
    leaf.addQuadCurve(to: CGPoint(x: -80 * s, y: 0), control: CGPoint(x: 0, y: -70 * s))
    fill(leaf, stops([(0x9BE86A, 1, 0), (0x2E8B2E, 1, 0.6), (0x175E1A, 1, 1)]), from: CGPoint(x: 0, y: 35 * s), to: CGPoint(x: 0, y: -35 * s))
    ctx.setStrokeColor(color(0xD8FFC0, 0.7)); ctx.setLineWidth(4 * s)
    ctx.move(to: CGPoint(x: -70 * s, y: 0)); ctx.addQuadCurve(to: CGPoint(x: 70 * s, y: 0), control: CGPoint(x: 0, y: 8 * s)); ctx.strokePath()
    ctx.restoreGState()
}

let appleCenter = CGPoint(x: 430, y: 470)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
ctx.beginTransparencyLayer(auxiliaryInfo: nil); drawApple(appleCenter, appleScale); ctx.endTransparencyLayer()
ctx.restoreGState()

// Loupe
let lens = CGPoint(x: 360, y: 560), radius = 175.0 * loupeScale, ring = 40.0 * loupeScale
let L = loupeScale
let angle = -Double.pi / 4
func onAxis(_ d: Double) -> CGPoint { CGPoint(x: lens.x + d * cos(angle), y: lens.y + d * sin(angle)) }

// Glossy black handle with a chrome ferrule
let handle = CGMutablePath(); handle.move(to: onAxis(radius + 70 * L)); handle.addLine(to: onAxis(radius + 330 * L))
let handleOutline = handle.copy(strokingWithWidth: 88 * L, lineCap: .round, lineJoin: .round, miterLimit: 1)
let across = (CGPoint(x: onAxis(0).x - 44 * sin(-angle), y: onAxis(0).y - 44 * cos(-angle)),
              CGPoint(x: onAxis(0).x + 44 * sin(-angle), y: onAxis(0).y + 44 * cos(-angle)))
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.45))
ctx.addPath(handleOutline); ctx.setFillColor(color(0x111111)); ctx.fillPath()
ctx.restoreGState()
func perpendicular(_ path: CGPath, at d: Double, _ g: CGGradient, half: Double) {
    let m = onAxis(d), nx = -sin(angle), ny = cos(angle)
    fill(path, g, from: CGPoint(x: m.x + nx * half, y: m.y + ny * half), to: CGPoint(x: m.x - nx * half, y: m.y - ny * half))
}
perpendicular(handleOutline, at: radius + 200 * L,
              stops([(0x6A6A6E, 1, 0), (0x1C1C1E, 1, 0.35), (0x000000, 1, 0.7), (0x3A3A3E, 1, 1)]), half: 44 * L)
// Gloss streak along the handle
let streak = CGMutablePath(); streak.move(to: onAxis(radius + 95 * L)); streak.addLine(to: onAxis(radius + 305 * L))
let streakShape = streak.copy(strokingWithWidth: 14 * L, lineCap: .round, lineJoin: .round, miterLimit: 1)
ctx.saveGState(); ctx.translateBy(x: -sin(angle) * 20 * L, y: cos(angle) * 20 * L)
ctx.addPath(streakShape); ctx.setFillColor(color(0xFFFFFF, 0.35)); ctx.fillPath(); ctx.restoreGState()
// Ferrule (metal collar)
let collar = CGMutablePath(); collar.move(to: onAxis(radius + 8 * L)); collar.addLine(to: onAxis(radius + 78 * L))
let collarShape = collar.copy(strokingWithWidth: 74 * L, lineCap: .butt, lineJoin: .miter, miterLimit: 1)
perpendicular(collarShape, at: radius + 40 * L,
              stops([(0xFFFFFF, 1, 0), (0xB8BCC4, 1, 0.3), (0x5D6168, 1, 0.65), (0xD9DCE1, 1, 1)]), half: 37 * L)

// Magnified apple inside the lens
let lensRect = CGRect(x: lens.x - radius, y: lens.y - radius, width: radius * 2, height: radius * 2)
ctx.saveGState()
ctx.addEllipse(in: lensRect); ctx.clip()
ctx.translateBy(x: lens.x, y: lens.y); ctx.scaleBy(x: 1.3, y: 1.3); ctx.translateBy(x: -lens.x, y: -lens.y)
drawApple(appleCenter, appleScale)
ctx.restoreGState()

// Glass: slight blue tint, inner shadow at the rim, and a big curved glare
ctx.saveGState()
ctx.addEllipse(in: lensRect); ctx.clip()
ctx.setFillColor(color(0xCFE8FF, 0.12)); ctx.fill(lensRect)
ctx.drawRadialGradient(stops([(0x000000, 0, 0.8), (0x000000, 0.35, 1)]), startCenter: lens, startRadius: 0,
                       endCenter: lens, endRadius: radius, options: [])
let glare = CGMutablePath()
glare.addArc(center: lens, radius: radius - 18 * L, startAngle: .pi * 0.52, endAngle: .pi * 1.02, clockwise: false)
glare.addArc(center: CGPoint(x: lens.x + 30 * L, y: lens.y - 30 * L), radius: radius - 40 * L, startAngle: .pi * 1.02, endAngle: .pi * 0.52, clockwise: true)
glare.closeSubpath()
fill(glare, stops([(0xFFFFFF, 0.75, 0), (0xFFFFFF, 0.05, 1)]), from: CGPoint(x: lens.x - radius, y: lens.y + radius), to: lens)
ctx.restoreGState()

// Chrome ring
let ringPath = CGPath(ellipseIn: lensRect, transform: nil).copy(strokingWithWidth: ring, lineCap: .round, lineJoin: .round, miterLimit: 1)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.45))
ctx.addPath(ringPath); ctx.setFillColor(color(0x8A8E96)); ctx.fillPath()
ctx.restoreGState()
fill(ringPath, stops([(0xFFFFFF, 1, 0), (0xC9CDD3, 1, 0.22), (0x6B7079, 1, 0.45), (0xF2F4F7, 1, 0.6), (0x8D929B, 1, 0.8), (0xE4E7EB, 1, 1)]),
     from: CGPoint(x: lensRect.minX, y: lensRect.maxY), to: CGPoint(x: lensRect.maxX, y: lensRect.minY))
// Bevel lines on the ring
for (r, a) in [(radius + ring / 2 - 2, 0.55), (radius - ring / 2 + 2, 0.35)] {
    ctx.setStrokeColor(color(0x000000, a)); ctx.setLineWidth(2.5)
    ctx.strokeEllipse(in: CGRect(x: lens.x - r, y: lens.y - r, width: r * 2, height: r * 2))
}
ctx.setStrokeColor(color(0xFFFFFF, 0.8)); ctx.setLineWidth(3)
ctx.addArc(center: lens, radius: radius + ring / 2 - 7 * L, startAngle: .pi * 0.55, endAngle: .pi * 0.95, clockwise: false); ctx.strokePath()

// Write iconset → icns
let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = NSBitmapImageRep(cgImage: ctx.makeImage()!)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! master.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run(); task.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
