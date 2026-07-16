#!/usr/bin/env swift
// Renders the app icon (1024x1024, opaque) — a clean Flipper-orange tile with a
// minimal white Flipper-Zero device silhouette and a Sub-GHz signal accent.
import AppKit

let size = 1024.0
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1)
}

// Vibrant Flipper-orange diagonal gradient background.
let bg = CGGradient(colorsSpace: cs, colors: [
    rgb(255, 150, 40), rgb(243, 110, 18), rgb(214, 86, 10)
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0), options: [])

let white = rgb(255, 255, 255)
let orange = rgb(243, 110, 18)
let dark = rgb(28, 24, 22)

// Device body: a rounded white tile (landscape, like a Flipper), centered.
let bw = 560.0, bh = 380.0
let bx = (size - bw) / 2, by = (size - bh) / 2 + 30
let body = CGRect(x: bx, y: by, width: bw, height: bh)
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
ctx.setFillColor(white)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Screen (left): dark rounded rect.
let screen = CGRect(x: bx + 48, y: by + bh - 230, width: 250, height: 175)
ctx.setFillColor(dark)
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 26, cornerHeight: 26, transform: nil))
ctx.fillPath()

// Signal arcs inside the screen (Sub-GHz vibe), in orange.
let sc = CGPoint(x: screen.minX + 60, y: screen.midY - 6)
ctx.setStrokeColor(orange)
ctx.setLineCap(.round)
for (i, r) in [34.0, 64.0, 94.0].enumerated() {
    ctx.setLineWidth(20 - Double(i) * 3)
    ctx.addArc(center: sc, radius: r, startAngle: -.pi * 0.42, endAngle: .pi * 0.42, clockwise: false)
    ctx.strokePath()
}
ctx.setFillColor(orange)
ctx.fillEllipse(in: CGRect(x: sc.x - 15, y: sc.y - 15, width: 30, height: 30))

// Round navigation button (right): orange ring + dark center.
let navC = CGPoint(x: bx + bw - 150, y: by + bh/2)
ctx.setFillColor(orange)
ctx.fillEllipse(in: CGRect(x: navC.x - 92, y: navC.y - 92, width: 184, height: 184))
ctx.setFillColor(white)
ctx.fillEllipse(in: CGRect(x: navC.x - 64, y: navC.y - 64, width: 128, height: 128))
ctx.setFillColor(dark)
ctx.fillEllipse(in: CGRect(x: navC.x - 30, y: navC.y - 30, width: 60, height: 60))

let img = ctx.makeImage()!
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
