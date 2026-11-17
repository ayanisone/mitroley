import AppKit

// The app icon: two footprints mid-stride, the foley artist's signature sound, as frosted glass
// on a deep burgundy tile. Palette: 786F50 olive, C39583 rose, 582419 oxblood, 967F59 khaki, 441015 burgundy.
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()
func hex(_ h: Int, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: rgb, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
func mix(_ h: Int, white w: Double, _ a: Double = 1) -> CGColor {
    let c = [Double((h >> 16) & 255) / 255, Double((h >> 8) & 255) / 255, Double(h & 255) / 255].map { $0 + (1 - $0) * w }
    return CGColor(colorSpace: rgb, components: [c[0], c[1], c[2], a])!
}
func gradient(_ stops: [(Double, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: stops.map(\.1) as CFArray, locations: stops.map { CGFloat($0.0) })!
}
let olive = 0x786F50, rose = 0xC39583, oxblood = 0x582419, khaki = 0x967F59, burgundy = 0x441015

let inset = 100.0
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Tile shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: hex(0x1A0507, 0.55))
ctx.addPath(tilePath); ctx.setFillColor(hex(burgundy)); ctx.fillPath()
ctx.restoreGState()

// Tile: oxblood falling to burgundy, with a rose bloom where the light enters
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([(0, hex(oxblood)), (0.45, mix(burgundy, white: 0.06)), (1, hex(burgundy))]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.drawRadialGradient(gradient([(0, hex(rose, 0.30)), (1, hex(rose, 0))]),
                       startCenter: CGPoint(x: 320, y: 810), startRadius: 0, endCenter: CGPoint(x: 320, y: 810), endRadius: 560, options: [])
ctx.drawRadialGradient(gradient([(0, hex(olive, 0.30)), (1, hex(olive, 0))]),
                       startCenter: CGPoint(x: 780, y: 220), startRadius: 0, endCenter: CGPoint(x: 780, y: 220), endRadius: 420, options: [])
ctx.restoreGState()

/// One shoe print: a sole and a heel, drawn around the origin and then placed.
func print(at centre: CGPoint, angle: Double, scale: Double, tint: Int) {
    var t = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: angle * .pi / 180).scaledBy(x: scale, y: scale)
    let shape = CGMutablePath()
    // Sole: wider at the ball of the foot, narrowing toward the arch
    let sole = CGMutablePath()
    sole.move(to: CGPoint(x: 0, y: 190))
    sole.addCurve(to: CGPoint(x: 92, y: 80), control1: CGPoint(x: 62, y: 190), control2: CGPoint(x: 98, y: 140))
    sole.addCurve(to: CGPoint(x: 62, y: -66), control1: CGPoint(x: 88, y: 20), control2: CGPoint(x: 72, y: -30))
    sole.addCurve(to: CGPoint(x: -58, y: -66), control1: CGPoint(x: 52, y: -100), control2: CGPoint(x: -48, y: -100))
    sole.addCurve(to: CGPoint(x: -84, y: 80), control1: CGPoint(x: -68, y: -30), control2: CGPoint(x: -82, y: 20))
    sole.addCurve(to: CGPoint(x: 0, y: 190), control1: CGPoint(x: -90, y: 140), control2: CGPoint(x: -62, y: 190))
    sole.closeSubpath()
    shape.addPath(sole, transform: t)
    shape.addPath(CGPath(roundedRect: CGRect(x: -58, y: -226, width: 116, height: 112), cornerWidth: 50, cornerHeight: 50, transform: nil), transform: t)
    let box = shape.boundingBoxOfPath

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0x1A0507, 0.6))
    ctx.addPath(shape); ctx.setFillColor(hex(tint)); ctx.fillPath()
    ctx.restoreGState()
    // Frosted body: pale where the light lands, the tint showing through below
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, mix(tint, white: 0.62)), (0.5, mix(tint, white: 0.28)), (1, hex(tint))]),
                           start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.drawLinearGradient(gradient([(0, CGColor(colorSpace: rgb, components: [1, 1, 1, 0.38])!), (1, CGColor(colorSpace: rgb, components: [1, 1, 1, 0])!)]),
                           start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.midX, y: box.midY), options: [])
    ctx.restoreGState()
    // Rim light
    ctx.saveGState()
    ctx.addPath(shape); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, CGColor(colorSpace: rgb, components: [1, 1, 1, 0.95])!), (0.5, CGColor(colorSpace: rgb, components: [1, 1, 1, 0.2])!), (1, hex(burgundy, 0.5))]),
                           start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
    ctx.restoreGState()
    _ = t; t = .identity
}

// Mid-stride: the back foot in khaki, the leading foot in rose
print(at: CGPoint(x: 392, y: 430), angle: 10, scale: 1.0, tint: khaki)
print(at: CGPoint(x: 632, y: 596), angle: -10, scale: 1.0, tint: rose)

// Tile rim, like the edge of a glass slab
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
ctx.setLineWidth(6); ctx.replacePathWithStrokedPath(); ctx.clip()
ctx.drawLinearGradient(gradient([(0, hex(rose, 0.85)), (0.35, hex(rose, 0.15)), (0.75, hex(0x1A0507, 0.15)), (1, hex(0x1A0507, 0.5))]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
