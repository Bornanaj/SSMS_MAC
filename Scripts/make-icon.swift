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

    // Deep navy through to cyan: the colour family SQL Server tooling lives in.
    let colors = [srgb(10, 46, 110).cgColor, srgb(16, 100, 176).cgColor,
                  srgb(38, 168, 214).cgColor] as CFArray
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

    // A wrench across the cylinder: the "management" half of the name, and the cue
    // that separates a tool from a plain database icon. Dropped below 64pt, where it
    // would smear into the cylinder.
    if size >= 64 {
        let headRadius = cylinder.width * 0.26
        let centre = CGPoint(x: cylinder.maxX - cylinder.width * 0.06,
                             y: cylinder.minY + cylinder.height * 0.10)

        context.saveGState()
        context.translateBy(x: centre.x, y: centre.y)
        context.rotate(by: -.pi / 4)

        let handleWidth = headRadius * 0.62
        let handleLength = cylinder.width * 0.62
        let handle = CGRect(x: -handleWidth / 2, y: -handleLength,
                            width: handleWidth, height: handleLength)

        // Outline first, so the wrench stays readable where it crosses the cylinder.
        context.setFillColor(srgb(10, 46, 110).withAlphaComponent(0.85).cgColor)
        let outlineWidth = 14 * scale
        context.addPath(CGPath(roundedRect: handle.insetBy(dx: -outlineWidth, dy: -outlineWidth),
                               cornerWidth: handleWidth, cornerHeight: handleWidth,
                               transform: nil))
        context.fillEllipse(in: CGRect(x: -headRadius - outlineWidth, y: -headRadius - outlineWidth,
                                       width: (headRadius + outlineWidth) * 2,
                                       height: (headRadius + outlineWidth) * 2))
        context.fillPath()

        context.setFillColor(NSColor.white.cgColor)
        context.addPath(CGPath(roundedRect: handle, cornerWidth: handleWidth / 2,
                               cornerHeight: handleWidth / 2, transform: nil))
        context.fillPath()
        context.fillEllipse(in: CGRect(x: -headRadius, y: -headRadius,
                                       width: headRadius * 2, height: headRadius * 2))

        // The bore and the open jaw are cut back out by repainting the plate gradient
        // through a clip, which keeps the wrench looking cut from the artwork rather
        // than pasted on top.
        context.saveGState()
        let bore = CGRect(x: -headRadius * 0.46, y: -headRadius * 0.46,
                          width: headRadius * 0.92, height: headRadius * 0.92)
        let jaw = CGRect(x: -headRadius * 0.40, y: 0,
                         width: headRadius * 0.80, height: headRadius * 1.4)
        context.addEllipse(in: bore)
        context.addRect(jaw)
        context.clip()
        context.rotate(by: .pi / 4)
        context.translateBy(x: -centre.x, y: -centre.y)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 0.55, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: plate.minX, y: plate.maxY),
                                       end: CGPoint(x: plate.maxX, y: plate.minY),
                                       options: [])
        }
        context.restoreGState()
        context.restoreGState()
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
