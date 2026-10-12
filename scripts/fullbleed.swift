// Makes a full-bleed 1024x1024 version of the icon (no rounded corners, no transparent margin),
// so macOS can apply its own mask instead of putting the artwork on a tile.
import AppKit

let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let rep0 = NSBitmapImageRep(data: src.tiffRepresentation!)!
let navy = rep0.colorAt(x: 160, y: 800)!      // plain background area of the artwork

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
navy.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
// Crop slightly inside the original rounded body (drops its rim and shadow) and fill the canvas.
let inset: CGFloat = 135
let crop = NSRect(x: inset, y: inset, width: 1254 - 2 * inset, height: 1254 - 2 * inset)
src.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: crop, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
