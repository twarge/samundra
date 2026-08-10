#!/usr/bin/env swift
// Renders the app icon: an emission spectrum — the trace the whole app is
// about — glowing across a deep-sea night, samundra being the sea.
//
//     swift apps/make-icon.swift
//
// writes AppIcon-1024.png into the asset catalog. Full-bleed square: the
// platform applies its own mask.

import AppKit
import UniformTypeIdentifiers

let side = 1024
let outPath = "apps/Samundra/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

guard FileManager.default.fileExists(atPath: "apps/Samundra") else {
    fatalError("run from the repository root")
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// The sea at night: near-black depths, a suggestion of blue toward the top.
let background = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(srgbRed: 0.075, green: 0.110, blue: 0.200, alpha: 1),
        CGColor(srgbRed: 0.020, green: 0.030, blue: 0.060, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    background,
    start: CGPoint(x: CGFloat(side) / 2, y: CGFloat(side)),
    end: CGPoint(x: CGFloat(side) / 2, y: 0),
    options: [])

// The trace: a few emission lines of different strengths on a low baseline,
// the same profile a gas-discharge lamp draws in the app.
struct Peak { let center: Double; let height: Double; let width: Double }
let peaks = [
    Peak(center: 0.18, height: 0.42, width: 0.022),
    Peak(center: 0.32, height: 0.78, width: 0.018),
    Peak(center: 0.47, height: 0.30, width: 0.025),
    Peak(center: 0.60, height: 0.95, width: 0.016),
    Peak(center: 0.72, height: 0.50, width: 0.020),
    Peak(center: 0.86, height: 0.26, width: 0.028),
]
func profile(_ t: Double) -> Double {
    var y = 0.035
    for p in peaks {
        let d = (t - p.center) / p.width
        y += p.height * exp(-d * d / 2)
    }
    return min(y, 1)
}

let inset = 0.10 * Double(side)          // breathing room inside the mask
let plotWidth = Double(side) - 2 * inset
let baseline = 0.22 * Double(side)
let amplitude = 0.58 * Double(side)

let path = CGMutablePath()
path.move(to: CGPoint(x: inset, y: baseline))
let steps = 512
for i in 0...steps {
    let t = Double(i) / Double(steps)
    path.addLine(to: CGPoint(x: inset + t * plotWidth, y: baseline + profile(t) * amplitude))
}
path.addLine(to: CGPoint(x: inset + plotWidth, y: baseline))
path.closeSubpath()

// Visible-spectrum ramp, violet to red across the trace.
func rampColor(_ t: Double) -> CGColor {
    let nm = 395.0 + t * (675.0 - 395.0)
    var r = 0.0, g = 0.0, b = 0.0
    switch nm {
    case ..<440: r = (440 - nm) / 60; b = 1
    case ..<490: g = (nm - 440) / 50; b = 1
    case ..<510: g = 1; b = (510 - nm) / 20
    case ..<580: r = (nm - 510) / 70; g = 1
    case ..<645: r = 1; g = (645 - nm) / 65
    default: r = 1
    }
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
let stops = 64
let ramp = CGGradient(
    colorsSpace: space,
    colors: (0...stops).map { rampColor(Double($0) / Double(stops)) } as CFArray,
    locations: (0...stops).map { CGFloat($0) / CGFloat(stops) })!

// Fill under the trace, dimmer, like the area style in the app…
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.setAlpha(0.45)
ctx.drawLinearGradient(
    ramp,
    start: CGPoint(x: inset, y: 0),
    end: CGPoint(x: inset + plotWidth, y: 0),
    options: [])
ctx.restoreGState()

// …then the trace itself at full strength with a soft glow.
ctx.saveGState()
ctx.setLineWidth(16)
ctx.setLineJoin(.round)
ctx.setShadow(
    offset: .zero, blur: 42,
    color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
ctx.addPath(path)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(
    ramp,
    start: CGPoint(x: inset, y: 0),
    end: CGPoint(x: inset + plotWidth, y: 0),
    options: [])
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")
