// Draws WinPhone's app icon and writes it as an .iconset folder:
//   swift tools/icon/make-icon.swift <folder>.iconset && iconutil -c icns <folder>.iconset -o app/Resources/AppIcon.icns
// A phone on the blue of the app's device tile, with the waves of a connection beside it.
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let unit = size / 1024
    // The plate: the system's icon shape, 824 of 1024 with room for its shadow.
    let plate = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = CGPath(roundedRect: plate, cornerWidth: 186 * unit, cornerHeight: 186 * unit, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 24 * unit, color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(CGColor(red: 0.10, green: 0.38, blue: 0.95, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [CGColor(red: 0.20, green: 0.62, blue: 1.0, alpha: 1), CGColor(red: 0.08, green: 0.30, blue: 0.90, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // A soft light from the top, as on the system's own icons.
    let shine = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(gray: 1, alpha: 0.20), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shine, start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.midY), options: [])
    context.restoreGState()

    // The phone.
    let body = CGRect(x: 318 * unit, y: 262 * unit, width: 292 * unit, height: 500 * unit)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 22 * unit, color: CGColor(gray: 0, alpha: 0.25))
    context.addPath(CGPath(roundedRect: body, cornerWidth: 58 * unit, cornerHeight: 58 * unit, transform: nil))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()
    let screen = body.insetBy(dx: 24 * unit, dy: 24 * unit)
    context.saveGState()
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 36 * unit, cornerHeight: 36 * unit, transform: nil))
    context.clip()
    let glass = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(red: 0.42, green: 0.74, blue: 1.0, alpha: 1), CGColor(red: 0.16, green: 0.44, blue: 0.96, alpha: 1)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(glass, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    context.restoreGState()
    // The camera's dot.
    context.setFillColor(CGColor(gray: 1, alpha: 0.9))
    context.fillEllipse(in: CGRect(x: body.midX - 11 * unit, y: screen.maxY - 40 * unit, width: 22 * unit, height: 22 * unit))

    // The connection: two arcs leaving the phone to the right.
    context.setLineCap(.round)
    for (radius, alpha, width) in [(118.0, 0.95, 34.0), (196.0, 0.6, 34.0)] {
        context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
        context.setLineWidth(width * unit)
        context.addArc(center: CGPoint(x: body.maxX + 6 * unit, y: body.midY), radius: radius * unit, startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
        context.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = draw(size: CGFloat(points * scale))
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}
