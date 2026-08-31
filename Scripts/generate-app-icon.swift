import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: generate-app-icon.swift OUTPUT.png\n".utf8))
  exit(64)
}

let size = 1_024
guard
  let bitmap = NSBitmapImageRep(
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
  ),
  let context = NSGraphicsContext(bitmapImageRep: bitmap)
else {
  FileHandle.standardError.write(Data("Unable to create the icon canvas.\n".utf8))
  exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
context.imageInterpolation = .high

let tileRect = NSRect(x: 92, y: 92, width: 840, height: 840)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 220, yRadius: 220)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.55, alpha: 0.28)
shadow.shadowBlurRadius = 62
shadow.shadowOffset = NSSize(width: 0, height: -24)
shadow.set()
let gradient = NSGradient(
  starting: NSColor(calibratedRed: 0.51, green: 0.46, blue: 0.98, alpha: 1),
  ending: NSColor(calibratedRed: 0.39, green: 0.31, blue: 0.91, alpha: 1)
)!
gradient.draw(in: tile, angle: -45)

NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by: 512, yBy: 512)
transform.rotate(byDegrees: -12)
transform.translateX(by: -512, yBy: -512)
transform.concat()

let leaf = NSBezierPath()
leaf.move(to: NSPoint(x: 350, y: 470))
leaf.curve(
  to: NSPoint(x: 690, y: 680),
  controlPoint1: NSPoint(x: 400, y: 660),
  controlPoint2: NSPoint(x: 570, y: 735)
)
leaf.curve(
  to: NSPoint(x: 520, y: 350),
  controlPoint1: NSPoint(x: 715, y: 500),
  controlPoint2: NSPoint(x: 650, y: 370)
)
leaf.curve(
  to: NSPoint(x: 350, y: 470),
  controlPoint1: NSPoint(x: 455, y: 335),
  controlPoint2: NSPoint(x: 385, y: 390)
)
leaf.close()
NSColor.white.setFill()
leaf.fill()

let vein = NSBezierPath()
vein.move(to: NSPoint(x: 330, y: 350))
vein.curve(
  to: NSPoint(x: 640, y: 615),
  controlPoint1: NSPoint(x: 430, y: 410),
  controlPoint2: NSPoint(x: 535, y: 520)
)
vein.lineWidth = 34
vein.lineCapStyle = .round
NSColor.white.setStroke()
vein.stroke()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("Unable to encode the app icon.\n".utf8))
  exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
