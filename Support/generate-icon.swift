import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Support/generate-icon.swift <output.png>")
}

let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("Could not create icon bitmap") }

NSGraphicsContext.saveGraphicsState()
guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Could not create graphics context") }
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.clear(CGRect(x: 0, y: 0, width: size, height: size))
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)
context.setFillColor(CGColor(red: 183 / 255, green: 218 / 255, blue: 230 / 255, alpha: 1))

func point(_ x: Double, _ y: Double) -> CGPoint {
    // Normalize the original SVG path to the full canvas height while preserving its proportions.
    let sourceX = 14.080 + x * 0.05973
    let sourceY = 53.479 + y * 0.05973
    let minimumY = 53.479 - 625 * 0.05973
    let maximumY = 53.479 + 12 * 0.05973
    let scale = Double(size) / (maximumY - minimumY)
    return CGPoint(
        x: Double(size) / 2 + (sourceX - 32) * scale,
        y: (sourceY - minimumY) * scale
    )
}

let path = CGMutablePath()
path.move(to: point(0, -625))
path.addLine(to: point(600, -625))
path.addLine(to: point(300, 12))
path.closeSubpath()
path.move(to: point(91.4, -567))
path.addLine(to: point(300, -124.1))
path.addLine(to: point(508.6, -567))
path.closeSubpath()
context.addPath(path)
context.drawPath(using: .eoFill)
graphics.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
