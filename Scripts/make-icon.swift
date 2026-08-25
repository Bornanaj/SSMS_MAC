#!/usr/bin/env swift
import AppKit
import Foundation

// Renders the app icon into an .iconset. Run through Scripts/build-app.sh; the
// artwork is drawn at every size rather than downsampled so the 16pt version
// stays legible.

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/AppIcon.iconset"

func srgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

/// macOS app icons sit inside a rounded square that leaves a margin on the canvas.
func drawIcon(size: CGFloat, in context: CGContext) {
    let scale = size / 1024
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = 100 * scale
    let plate = CGRect(x: inset, y: inset + 16 * scale,
                       width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237

    // Plate with a soft shadow, like a stock macOS icon.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale),
                      blur: 34 * scale,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
    let plainPath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
    context.addPath(plainPath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(plainPath)
    context.clip()

    // Deep blue to teal, the colours a database tool wants to read as.
    let colors = [srgb(23, 58, 122).cgColor, srgb(18, 116, 152).cgColor,
                  srgb(20, 158, 150).cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: plate.minX, y: plate.maxY),
                                   end: CGPoint(x: plate.maxX, y: plate.minY),
                                   options: [])
    }

    // Gloss across the top third.
    let glossColors = [NSColor.white.withAlphaComponent(0.20).cgColor,
                       NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
    if let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: glossColors, locations: [0, 1]) {
        context.drawLinearGradient(gloss,
                                   start: CGPoint(x: plate.midX, y: plate.maxY),
                                   end: CGPoint(x: plate.midX, y: plate.midY),
                                   options: [])
    }

    // Database cylinder: three stacked bands.
    let cylinderWidth = plate.width * 0.46
    let cylinderHeight = plate.height * 0.44
    let cylinder = CGRect(x: plate.midX - cylinderWidth / 2,
                          y: plate.midY - cylinderHeight / 2 + plate.height * 0.07,
                          width: cylinderWidth, height: cylinderHeight)
    let ellipseHeight = cylinderWidth * 0.30
    let bandCount = 3
    let bandHeight = (cylinder.height - ellipseHeight) / CGFloat(bandCount)

    context.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
    context.setStrokeColor(srgb(16, 48, 96).withAlphaComponent(0.55).cgColor)
    context.setLineWidth(max(1, 7 * scale))

    // Body first, then the separating rims, then the top face.
    let bodyRect = CGRect(x: cylinder.minX, y: cylinder.minY + ellipseHeight / 2,
                          width: cylinder.width, height: cylinder.height - ellipseHeight)
    context.fill(bodyRect)
    context.fillEllipse(in: CGRect(x: cylinder.minX, y: cylinder.minY,
                                   width: cylinder.width, height: ellipseHeight))

    for band in 1..<bandCount {
        let y = cylinder.minY + ellipseHeight / 2 + bandHeight * CGFloat(band)
        let rim = CGRect(x: cylinder.minX, y: y - ellipseHeight / 2,
                         width: cylinder.width, height: ellipseHeight)
        context.saveGState()
        context.addRect(CGRect(x: cylinder.minX, y: y - ellipseHeight / 2,
                               width: cylinder.width, height: ellipseHeight / 2))
        context.clip()
        context.strokeEllipse(in: rim)
        context.restoreGState()
    }

    let topFace = CGRect(x: cylinder.minX, y: cylinder.maxY - ellipseHeight,
                         width: cylinder.width, height: ellipseHeight)
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: topFace)
    context.setStrokeColor(srgb(16, 48, 96).withAlphaComponent(0.35).cgColor)
    context.strokeEllipse(in: topFace)

    // Terminal prompt on the cylinder body, so it reads as a query tool and not
    // just a generic database. Dropped at small sizes where it would smear.
    if size >= 64 {
        let promptColor = srgb(18, 116, 152)
        context.setStrokeColor(promptColor.cgColor)
        context.setLineWidth(max(2, 26 * scale))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let chevronHeight = cylinder.height * 0.20
        let originX = cylinder.minX + cylinder.width * 0.24
        let originY = cylinder.minY + cylinder.height * 0.34
        context.move(to: CGPoint(x: originX, y: originY + chevronHeight / 2))
        context.addLine(to: CGPoint(x: originX + chevronHeight * 0.62, y: originY))
        context.addLine(to: CGPoint(x: originX, y: originY - chevronHeight / 2))
        context.strokePath()

        let underscoreY = originY - chevronHeight / 2
        context.move(to: CGPoint(x: originX + chevronHeight * 0.85, y: underscoreY))
        context.addLine(to: CGPoint(x: cylinder.maxX - cylinder.width * 0.20, y: underscoreY))
        context.strokePath()
    }

    context.restoreGState()
}

func writePNG(size: CGFloat, to url: URL) throws {
    let pixels = Int(size)
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }

    drawIcon(size: size, in: context)

    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let sizes: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

let directory = URL(fileURLWithPath: outputDirectory)
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for entry in sizes {
    try writePNG(size: entry.pixels,
                 to: directory.appendingPathComponent("\(entry.name).png"))
}
print("wrote \(sizes.count) images to \(outputDirectory)")
