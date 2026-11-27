import AppKit
import CoreText

let arguments = CommandLine.arguments
let fontURL = URL(fileURLWithPath: arguments[1])
let markerURL = URL(fileURLWithPath: arguments[2])
let output = URL(fileURLWithPath: arguments[3])
let scale = Int(arguments[4])!
let width = 520
let height = 320

CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
      let descriptor = descriptors.first,
      let fontName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
      let font = NSFont(name: fontName, size: 38),
      let mark = NSImage(contentsOf: markerURL),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not load the Pulse artwork or create the disk image background.")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSColor(srgbRed: 0.075, green: 0.078, blue: 0.085, alpha: 1).setFill()
bounds.fill()

// Finder draws its own labels in black over image backgrounds.
NSColor(srgbRed: 0.87, green: 0.88, blue: 0.89, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height - 219).fill()

let wordmark = NSAttributedString(string: "Pulse", attributes: [
    .font: font,
    .foregroundColor: NSColor(white: 0.97, alpha: 1),
])
let markSize = CGSize(width: 23, height: 28)
let wordmarkSize = wordmark.size()
let brandX = (CGFloat(width) - markSize.width - 12 - wordmarkSize.width) / 2
mark.isTemplate = true
let markRect = CGRect(origin: CGPoint(x: brandX, y: 255), size: markSize)
context.saveGraphicsState()
context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
mark.draw(in: markRect)
NSColor(white: 0.97, alpha: 1).setFill()
markRect.fill(using: .sourceIn)
context.cgContext.endTransparencyLayer()
context.restoreGraphicsState()
wordmark.draw(at: CGPoint(x: brandX + markSize.width + 12, y: 246))

// A soft step echoes the rounded shape of the Pulse mark.
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: 223, y: 168))
arrow.line(to: CGPoint(x: 245, y: 168))
arrow.curve(to: CGPoint(x: 263, y: 181),
            controlPoint1: CGPoint(x: 253, y: 168), controlPoint2: CGPoint(x: 255, y: 181))
arrow.line(to: CGPoint(x: 297, y: 181))
arrow.move(to: CGPoint(x: 285, y: 193))
arrow.line(to: CGPoint(x: 297, y: 181))
arrow.line(to: CGPoint(x: 285, y: 169))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor.white.setStroke()
arrow.stroke()

try bitmap.representation(using: .png, properties: [:])!.write(to: output)
