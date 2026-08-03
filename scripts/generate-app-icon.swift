import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift OUTPUT.png\n".utf8))
    exit(64)
}

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)
image.lockFocus()

guard let context = NSGraphicsContext.current else {
    FileHandle.standardError.write(Data("could not create graphics context\n".utf8))
    exit(1)
}

context.imageInterpolation = .high

let tileRect = NSRect(x: 32, y: 32, width: 960, height: 960)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 224, yRadius: 224)
let background = NSGradient(
    starting: NSColor(calibratedRed: 0.025, green: 0.055, blue: 0.085, alpha: 1),
    ending: NSColor(calibratedRed: 0.035, green: 0.20, blue: 0.21, alpha: 1)
)!
background.draw(in: tile, angle: -52)

NSGraphicsContext.saveGraphicsState()
let haloShadow = NSShadow()
haloShadow.shadowColor = NSColor(calibratedRed: 0.16, green: 0.95, blue: 0.78, alpha: 0.24)
haloShadow.shadowBlurRadius = 70
haloShadow.shadowOffset = .zero
haloShadow.set()
NSColor(calibratedRed: 0.12, green: 0.88, blue: 0.74, alpha: 0.18).setFill()
NSBezierPath(ovalIn: NSRect(x: 250, y: 230, width: 524, height: 524)).fill()
NSGraphicsContext.restoreGraphicsState()

let shield = NSBezierPath()
shield.move(to: NSPoint(x: 512, y: 844))
shield.line(to: NSPoint(x: 773, y: 749))
shield.line(to: NSPoint(x: 737, y: 468))
shield.curve(
    to: NSPoint(x: 512, y: 185),
    controlPoint1: NSPoint(x: 716, y: 328),
    controlPoint2: NSPoint(x: 614, y: 232)
)
shield.curve(
    to: NSPoint(x: 287, y: 468),
    controlPoint1: NSPoint(x: 410, y: 232),
    controlPoint2: NSPoint(x: 308, y: 328)
)
shield.line(to: NSPoint(x: 251, y: 749))
shield.close()
shield.lineJoinStyle = .round
NSColor(calibratedRed: 0.015, green: 0.055, blue: 0.075, alpha: 0.64).setFill()
shield.fill()
NSColor(calibratedRed: 0.19, green: 0.94, blue: 0.78, alpha: 0.78).setStroke()
shield.lineWidth = 12
shield.stroke()

let mark = NSBezierPath()
mark.move(to: NSPoint(x: 380, y: 353))
mark.line(to: NSPoint(x: 512, y: 684))
mark.line(to: NSPoint(x: 644, y: 353))
mark.move(to: NSPoint(x: 431, y: 475))
mark.line(to: NSPoint(x: 593, y: 475))
mark.lineCapStyle = .round
mark.lineJoinStyle = .round
mark.lineWidth = 42
NSColor(calibratedWhite: 0.98, alpha: 0.96).setStroke()
mark.stroke()

let nodeColor = NSColor(calibratedRed: 0.20, green: 0.98, blue: 0.80, alpha: 1)
nodeColor.setFill()
for point in [
    NSPoint(x: 512, y: 684),
    NSPoint(x: 380, y: 353),
    NSPoint(x: 644, y: 353),
    NSPoint(x: 512, y: 475),
] {
    NSBezierPath(
        ovalIn: NSRect(x: point.x - 17, y: point.y - 17, width: 34, height: 34)
    ).fill()
}

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("could not encode app icon\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
