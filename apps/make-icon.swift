#!/usr/bin/env swift
// Writes the app icon: an emission spectrum — the trace the whole app is
// about — glowing across a deep-sea night, samundra being the sea.
//
//     swift apps/make-icon.swift        (or: make icon)
//
// There are two outputs, one drawing in two forms, both named AppIcon so each
// platform takes its own.
//
// macOS: apps/Samundra/AppIcon.icon, an Icon Composer bundle (icon.json plus
// one SVG per layer). Xcode's asset compiler turns it into every size the
// platform needs and applies the system shape and the glass, dark, clear and
// tinted treatments, so the artwork is full bleed and carries no mask, rim,
// shadow or glow of its own. Layers, front to back, over the night-sea fill
// (which the dark appearance keeps, a shade deeper):
//
//     Trace   the spectrum line, violet to red, running off both sides of
//             the icon (glass; its shadow takes the layer's colour, which is
//             the glow)
//     Area    everything under the line down to the bottom edge, the same
//             ramp, dimmer (flat)
//
// The tinted and clear appearances reduce a layer to its brightness, and a
// rainbow's brightness is uneven: blue comes out far darker than yellow, in
// bands. So for those appearances each layer has a second image, the same
// shape in one neutral tone (Trace-Mono, Area-Mono). Default and dark use
// the colour.
//
// visionOS: apps/Samundra/Assets.xcassets/AppIcon.solidimagestack. An .icon
// gives visionOS nothing, and its image stack takes PNGs, not SVGs, so the
// same layers are rasterised here: Front is the line, Middle the area, Back
// the sea. visionOS crops to a circle and lifts the layers apart, so the
// peaks are drawn smaller there to sit inside it; the line and the area
// still run out to the edge.
//
// Both are committed, so this only needs running when the design changes. To
// look at the macOS icon without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         apps/Samundra/AppIcon.icon --export-image --output-file icon.png \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let iconDir = "apps/Samundra/AppIcon.icon"
let stackDir = "apps/Samundra/Assets.xcassets/AppIcon.solidimagestack"

guard FileManager.default.fileExists(atPath: "apps/Samundra") else {
    fatalError("run from the repository root")
}

// MARK: The spectrum

// A few emission lines of different strengths on a low background, the same
// profile a gas-discharge lamp draws in the app.
struct Peak { let center: Double; let height: Double; let width: Double }
let peaks = [
    Peak(center: 0.18, height: 0.42, width: 0.022),
    Peak(center: 0.32, height: 0.78, width: 0.018),
    Peak(center: 0.47, height: 0.30, width: 0.025),
    Peak(center: 0.60, height: 0.95, width: 0.016),
    Peak(center: 0.72, height: 0.50, width: 0.020),
    Peak(center: 0.86, height: 0.26, width: 0.028),
]
let background = 0.035
func profile(_ t: Double) -> Double {
    var y = background
    for p in peaks {
        let d = (t - p.center) / p.width
        y += p.height * exp(-d * d / 2)
    }
    return min(y, 1)
}

// MARK: Colour

// Visible-spectrum ramp, violet to red across the peaks: 395 nm to 675 nm,
// linear in sRGB between the classic primaries. Outside the peaks the end
// colours carry on to the edges.
let ramp: [(nm: Double, hex: String)] = [
    (395, "#BF00FF"),
    (440, "#0000FF"),
    (490, "#00FFFF"),
    (510, "#00FF00"),
    (580, "#FFFF00"),
    (645, "#FF0000"),
    (675, "#FF0000"),
]
let rampPaint = "url(#ramp)"

// What stands in for the ramp in the tinted and clear appearances.
let monoTone = "#AEAEAE"

// How much of the ramp's strength the area under the line keeps.
let areaOpacity = 0.45

// The sea at night: a suggestion of blue at the top, near-black depths. The
// dark appearance gets its own, deeper pair; left to itself the system would
// swap the fill for its neutral charcoal there and the sea would be gone.
typealias RGB = (r: Double, g: Double, b: Double)
let sea: [RGB] = [(0.075, 0.110, 0.200), (0.020, 0.030, 0.060)]
let seaDark: [RGB] = [(0.055, 0.085, 0.165), (0.010, 0.015, 0.035)]

func extended(_ c: RGB) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b)
}

func hex(_ c: RGB) -> String {
    String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
}

// MARK: Drawing, on the 1024 × 1024 canvas with y downward

let side = 1024.0

func num(_ v: Double) -> String {
    let s = String(format: "%.1f", v)
    return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
}

func wrapped(_ points: [String], indent: String) -> String {
    stride(from: 0, to: points.count, by: 10)
        .map { indent + points[$0..<min($0 + 10, points.count)].joined(separator: " ") }
        .joined(separator: "\n")
}

func document(defs: String = "", _ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(defs)\(body)
    </svg>

    """
}

/// The line and the area under it at one size. `scale` shrinks the peaks
/// about the centre of the canvas. The flat background on either side of
/// them carries on past the canvas whatever the scale, and the area runs
/// down to the bottom edge, so the system shape cuts both rather than
/// either stopping short of it.
struct Spectrum {
    let inset: Double         // keeps the peaks clear of the system shape
    let plotWidth: Double
    let baseline: Double      // y of zero signal
    let amplitude: Double     // height of a full-scale peak
    let traceWidth: Double

    init(scale: Double) {
        let centre = side / 2
        inset = 0.10 * side * scale + centre * (1 - scale)
        plotWidth = side - 2 * inset
        baseline = 0.78 * side * scale + centre * (1 - scale)
        amplitude = 0.58 * side * scale
        traceWidth = 20 * scale
    }

    var overhang: Double { 2 * traceWidth }

    var tracePoints: [String] {
        func y(_ t: Double) -> Double { baseline - profile(t) * amplitude }
        let steps = 512
        return ["\(num(-overhang)),\(num(y(0)))"]
            + (0...steps).map { i in
                let t = Double(i) / Double(steps)
                return "\(num(inset + t * plotWidth)),\(num(y(t)))"
            }
            + ["\(num(side + overhang)),\(num(y(1)))"]
    }

    var areaPoints: [String] {
        ["\(num(-overhang)),\(num(side))"] + tracePoints + ["\(num(side + overhang)),\(num(side))"]
    }

    var rampDef: String {
        let stops = ramp.map { stop -> String in
            let offset = String(format: "%.4f", (stop.nm - 395) / (675 - 395))
            return "      <stop offset=\"\(offset)\" stop-color=\"\(stop.hex)\"/>"
        }
        return (
            ["  <defs>",
             "    <linearGradient id=\"ramp\" gradientUnits=\"userSpaceOnUse\" "
                + "x1=\"\(num(inset))\" y1=\"0\" x2=\"\(num(inset + plotWidth))\" y2=\"0\">"]
            + stops
            + ["    </linearGradient>", "  </defs>"]
        ).joined(separator: "\n")
    }

    func svg(_ body: String) -> String {
        document(defs: body.contains(rampPaint) ? rampDef + "\n" : "", body)
    }

    func trace(_ paint: String) -> String {
        svg("""
              <polyline fill="none" stroke="\(paint)" stroke-width="\(num(traceWidth))" stroke-linecap="round" stroke-linejoin="round" points="
            \(wrapped(tracePoints, indent: "    "))"/>
            """)
    }

    func area(_ paint: String, opacity: Double = 1) -> String {
        let fade = opacity < 1 ? " fill-opacity=\"\(opacity)\"" : ""
        return svg("""
              <polygon fill="\(paint)"\(fade) points="
            \(wrapped(areaPoints, indent: "    "))"/>
            """)
    }
}

// MARK: macOS, the Icon Composer bundle

let mac = Spectrum(scale: 1)

// Colour by default, the neutral tone when the system tints or clears.
func images(_ name: String) -> String {
    """
    "image-name-specializations" : [
                {
                  "value" : "\(name).svg"
                },
                {
                  "appearance" : "tinted",
                  "value" : "\(name)-Mono.svg"
                }
              ]
    """
}

let iconJSON = """
    {
      "fill-specializations" : [
        {
          "value" : {
            "linear-gradient" : [
              "\(extended(sea[0]))",
              "\(extended(sea[1]))"
            ]
          }
        },
        {
          "appearance" : "dark",
          "value" : {
            "linear-gradient" : [
              "\(extended(seaDark[0]))",
              "\(extended(seaDark[1]))"
            ]
          }
        }
      ],
      "groups" : [
        {
          "layers" : [
            {
              \(images("Trace")),
              "name" : "Trace"
            }
          ],
          "shadow" : {
            "kind" : "layer-color",
            "opacity" : 0.5
          },
          "translucency" : {
            "enabled" : false,
            "value" : 0.5
          }
        },
        {
          "layers" : [
            {
              "glass" : false,
              \(images("Area")),
              "name" : "Area",
              "opacity" : \(areaOpacity)
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.0
          },
          "translucency" : {
            "enabled" : false,
            "value" : 0.5
          }
        }
      ],
      "supported-platforms" : {
        "squares" : "shared"
      }
    }

    """

let fm = FileManager.default
try? fm.removeItem(atPath: iconDir)
try fm.createDirectory(atPath: iconDir + "/Assets", withIntermediateDirectories: true)
try mac.trace(rampPaint).write(toFile: iconDir + "/Assets/Trace.svg", atomically: true, encoding: .utf8)
try mac.trace(monoTone).write(toFile: iconDir + "/Assets/Trace-Mono.svg", atomically: true, encoding: .utf8)
try mac.area(rampPaint).write(toFile: iconDir + "/Assets/Area.svg", atomically: true, encoding: .utf8)
try mac.area(monoTone).write(toFile: iconDir + "/Assets/Area-Mono.svg", atomically: true, encoding: .utf8)
try iconJSON.write(toFile: iconDir + "/icon.json", atomically: true, encoding: .utf8)
print("wrote \(iconDir)")

// MARK: visionOS, the solid image stack

// The peaks at this size clear the circle with room for the layers to shift
// against each other as the icon turns.
let vision = Spectrum(scale: 0.84)

let seaSVG = document("""
      <defs>
        <linearGradient id="sea" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="1024">
          <stop offset="0" stop-color="\(hex(sea[0]))"/>
          <stop offset="1" stop-color="\(hex(sea[1]))"/>
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" fill="url(#sea)"/>
    """)

// Front to back. Only the back is opaque.
let stackLayers: [(name: String, svg: String, opaque: Bool)] = [
    ("Front", vision.trace(rampPaint), false),
    ("Middle", vision.area(rampPaint, opacity: areaOpacity), false),
    ("Back", seaSVG, true),
]

func png(_ svg: String, opaque: Bool) -> Data {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let image = NSImage(data: Data(svg.utf8)),
          let context = CGContext(
              data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)
    else { fatalError("could not draw a layer") }

    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current = nil

    let data = NSMutableData()
    guard let drawn = context.makeImage(),
          let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("could not encode a layer") }
    CGImageDestinationAddImage(dest, drawn, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not encode a layer") }
    return data as Data
}

let catalogInfo = """
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    """

try? fm.removeItem(atPath: stackDir)
for layer in stackLayers {
    let layerDir = "\(stackDir)/\(layer.name).solidimagestacklayer"
    let imageSet = layerDir + "/Content.imageset"
    try fm.createDirectory(atPath: imageSet, withIntermediateDirectories: true)
    try png(layer.svg, opaque: layer.opaque).write(to: URL(fileURLWithPath: "\(imageSet)/\(layer.name).png"))
    try """
        {
          "images" : [
            {
              "filename" : "\(layer.name).png",
              "idiom" : "vision",
              "scale" : "2x"
            }
          ],
        \(catalogInfo)
        }

        """.write(toFile: imageSet + "/Contents.json", atomically: true, encoding: .utf8)
    try """
        {
        \(catalogInfo)
        }

        """.write(toFile: layerDir + "/Contents.json", atomically: true, encoding: .utf8)
}
try """
    {
    \(catalogInfo),
      "layers" : [
    \(stackLayers.map { "    {\n      \"filename\" : \"\($0.name).solidimagestacklayer\"\n    }" }.joined(separator: ",\n"))
      ]
    }

    """.write(toFile: stackDir + "/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(stackDir)")
