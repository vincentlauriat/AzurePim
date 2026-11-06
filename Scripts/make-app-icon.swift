#!/usr/bin/env swift
// Generates the AzurePim app icon set (shield + countdown dial) into AppIcon.appiconset,
// plus docs/assets/icon-256.png for the README and the landing page.
// Usage: ./Scripts/make-app-icon.swift
import AppKit

let canvas: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("AzurePim/Assets.xcassets/AppIcon.appiconset")
let docsIcon = root.appendingPathComponent("docs/assets/icon-256.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func arc(_ ctx: CGContext, center: CGPoint, ring: (radius: CGFloat, width: CGFloat),
         angles: (from: CGFloat, sweep: CGFloat), _ stroke: CGColor) {
    ctx.saveGState()
    ctx.setLineWidth(ring.width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(stroke)
    ctx.addArc(center: center, radius: ring.radius, startAngle: angles.from * .pi / 180,
               endAngle: (angles.from - angles.sweep) * .pi / 180, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()
}

func draw(_ ctx: CGContext) {
    // Body on the macOS icon grid: 824 pt square, 185 pt corner radius, soft drop shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0x0B4FC9))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0x3D8BFF), color(0x0A3FB0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Shield.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: 512, y: 815))
    shield.addCurve(to: CGPoint(x: 265, y: 720), control1: CGPoint(x: 430, y: 760), control2: CGPoint(x: 340, y: 735))
    shield.addCurve(to: CGPoint(x: 512, y: 205), control1: CGPoint(x: 255, y: 450), control2: CGPoint(x: 330, y: 300))
    shield.addCurve(to: CGPoint(x: 759, y: 720), control1: CGPoint(x: 694, y: 300), control2: CGPoint(x: 769, y: 450))
    shield.addCurve(to: CGPoint(x: 512, y: 815), control1: CGPoint(x: 684, y: 735), control2: CGPoint(x: 594, y: 760))
    ctx.addPath(shield)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()

    // Countdown dial: faint track, green remaining time, clock hands.
    let center = CGPoint(x: 512, y: 530)
    arc(ctx, center: center, ring: (150, 44), angles: (0, 360), color(0x0A3FB0, 0.15))
    arc(ctx, center: center, ring: (150, 44), angles: (90, 250), color(0x10B981))
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(40)
    ctx.setStrokeColor(color(0x0A3FB0))
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + 95))
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + 70, y: center.y - 40))
    ctx.strokePath()
    ctx.restoreGState()
}

func render(_ size: Int) -> Data {
    // Exactly size×size pixels (no Retina backing-scale doubling).
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let url = iconSet.appendingPathComponent("icon_\(size).png")
    try render(size).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
try render(256).write(to: docsIcon)
print("wrote docs/assets/icon-256.png")
