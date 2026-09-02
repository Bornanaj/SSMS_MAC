#!/usr/bin/env swift
import AppKit
import Foundation

// Background art for the .pkg installer. Apple draws it bottom-left behind the content
// panel, and only the leftmost ~30% of the width stays visible beside that panel, so
// every readable element lives inside that strip. Anything wider is atmosphere.

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/installer-background.png"
let iconPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/AppIcon.icns"

let size = NSSize(width: 620, height: 418)

func srgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
context.scaleBy(x: 2, y: 2)

// Same navy-to-cyan family as the app icon.
let colors = [srgb(9, 38, 92).cgColor, srgb(14, 84, 150).cgColor,
              srgb(32, 150, 196).cgColor] as CFArray
if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors, locations: [0, 0.6, 1]) {
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size.height),
                               end: CGPoint(x: size.width, y: 0),
                               options: [])
}

// A faint grid, so the panel reads as a tool rather than a plain gradient.
context.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
context.setLineWidth(1)
for x in stride(from: 0.0, through: Double(size.width), by: 28) {
    context.move(to: CGPoint(x: x, y: 0))
    context.addLine(to: CGPoint(x: x, y: size.height))
}
for y in stride(from: 0.0, through: Double(size.height), by: 28) {
    context.move(to: CGPoint(x: 0, y: y))
    context.addLine(to: CGPoint(x: size.width, y: y))
}
context.strokePath()

// A soft glow behind where the icon goes.
if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                                  NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                         locations: [0, 1]) {
    context.drawRadialGradient(glow,
                               startCenter: CGPoint(x: 84, y: 148), startRadius: 0,
                               endCenter: CGPoint(x: 84, y: 148), endRadius: 150,
                               options: [])
}

if let image = NSImage(contentsOfFile: iconPath) {
    let target = NSRect(x: 26, y: 92, width: 112, height: 112)
    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        context.draw(cgImage, in: target)
    }
}

func draw(_ text: String, at point: NSPoint, size fontSize: CGFloat,
          weight: NSFont.Weight, alpha: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha)
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    line.draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

draw("SSMS for Mac", at: NSPoint(x: 26, y: 56), size: 19, weight: .semibold, alpha: 0.96)
draw("SQL Server", at: NSPoint(x: 27, y: 36), size: 12, weight: .regular, alpha: 0.74)
draw("client for macOS", at: NSPoint(x: 27, y: 19), size: 12, weight: .regular, alpha: 0.74)

guard let image = context.makeImage() else { exit(2) }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = size
guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
