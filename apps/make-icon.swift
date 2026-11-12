#!/usr/bin/env swift
// Writes the app icon as an Icon Composer bundle: an emission spectrum — the
// trace the whole app is about — glowing across a deep-sea night, samundra
// being the sea.
//
//     swift apps/make-icon.swift        (or: make icon)
//
// The output is apps/Samundra/AppIcon.icon: icon.json plus one SVG per layer.
// Xcode's asset compiler turns it into every size the platform needs and
// applies the system shape and the glass, dark, clear and tinted treatments,
// so the artwork here is full bleed and carries no mask, rim, shadow or glow
// of its own.
//
// Layers, front to back, over the night-sea fill (which the dark appearance
// keeps, a shade deeper):
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
// The bundle is committed, so this only needs running when the design
// changes. To look at the result without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         apps/Samundra/AppIcon.icon --export-image --output-file icon.png \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.

import Foundation

let outDir = "apps/Samundra/AppIcon.icon"

guard FileManager.default.fileExists(atPath: "apps/Samundra") else {
    fatalError("run from the repository root")
}

// MARK: Geometry, on the 1024 × 1024 canvas with y downward

let side = 1024.0
let inset = 0.10 * side              // keeps the peaks clear of the system shape
let plotWidth = side - 2 * inset
let baseline = 0.78 * side           // y of zero signal
let amplitude = 0.58 * side          // height of a full-scale peak
let traceWidth = 20.0

// The trace: a few emission lines of different strengths on a low
// background, the same profile a gas-discharge lamp draws in the app.
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

func num(_ v: Double) -> String {
    let s = String(format: "%.1f", v)
    return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
}

// The peaks sit between the insets; the flat background on either side of
// them carries on past the canvas, so the system shape cuts the line rather
// than the line stopping short of it.
let overhang = 2 * traceWidth
func traceY(_ t: Double) -> Double { baseline - profile(t) * amplitude }
let steps = 512
let tracePoints: [String] =
    ["\(num(-overhang)),\(num(traceY(0)))"]
    + (0...steps).map { i in
        let t = Double(i) / Double(steps)
        return "\(num(inset + t * plotWidth)),\(num(traceY(t)))"
    }
    + ["\(num(side + overhang)),\(num(traceY(1)))"]

// MARK: Colour

// Visible-spectrum ramp, violet to red across the peaks: 395 nm to 675 nm,
// linear in sRGB between the classic primaries. Outside the insets the end
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
let rampStops = ramp.map { stop -> String in
    let offset = String(format: "%.4f", (stop.nm - 395) / (675 - 395))
    return "      <stop offset=\"\(offset)\" stop-color=\"\(stop.hex)\"/>"
}
let rampDef = (
    ["  <defs>",
     "    <linearGradient id=\"ramp\" gradientUnits=\"userSpaceOnUse\" "
        + "x1=\"\(num(inset))\" y1=\"0\" x2=\"\(num(inset + plotWidth))\" y2=\"0\">"]
    + rampStops
    + ["    </linearGradient>", "  </defs>"]
).joined(separator: "\n")

// What stands in for the ramp in the tinted and clear appearances.
let monoTone = "#AEAEAE"

// The sea at night: a suggestion of blue at the top, near-black depths. The
// dark appearance gets its own, deeper pair; left to itself the system would
// swap the fill for its neutral charcoal there and the sea would be gone.
let sea = ["extended-srgb:0.07500,0.11000,0.20000,1.00000", "extended-srgb:0.02000,0.03000,0.06000,1.00000"]
let seaDark = ["extended-srgb:0.05500,0.08500,0.16500,1.00000", "extended-srgb:0.01000,0.01500,0.03500,1.00000"]

// MARK: Layers

let rampPaint = "url(#ramp)"

func svg(_ body: String) -> String {
    let defs = body.contains(rampPaint) ? rampDef + "\n" : ""
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(defs)\(body)
    </svg>

    """
}

func wrapped(_ points: [String], indent: String) -> String {
    stride(from: 0, to: points.count, by: 10)
        .map { indent + points[$0..<min($0 + 10, points.count)].joined(separator: " ") }
        .joined(separator: "\n")
}

func trace(_ paint: String) -> String {
    svg("""
          <polyline fill="none" stroke="\(paint)" stroke-width="\(num(traceWidth))" stroke-linecap="round" stroke-linejoin="round" points="
        \(wrapped(tracePoints, indent: "    "))"/>
        """)
}

let areaPoints =
    ["\(num(-overhang)),\(num(side))"] + tracePoints + ["\(num(side + overhang)),\(num(side))"]
func area(_ paint: String) -> String {
    svg("""
          <polygon fill="\(paint)" points="
        \(wrapped(areaPoints, indent: "    "))"/>
        """)
}

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
              "\(sea[0])",
              "\(sea[1])"
            ]
          }
        },
        {
          "appearance" : "dark",
          "value" : {
            "linear-gradient" : [
              "\(seaDark[0])",
              "\(seaDark[1])"
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
              "opacity" : 0.45
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

// MARK: Output

let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir + "/Assets", withIntermediateDirectories: true)
try trace(rampPaint).write(toFile: outDir + "/Assets/Trace.svg", atomically: true, encoding: .utf8)
try trace(monoTone).write(toFile: outDir + "/Assets/Trace-Mono.svg", atomically: true, encoding: .utf8)
try area(rampPaint).write(toFile: outDir + "/Assets/Area.svg", atomically: true, encoding: .utf8)
try area(monoTone).write(toFile: outDir + "/Assets/Area-Mono.svg", atomically: true, encoding: .utf8)
try iconJSON.write(toFile: outDir + "/icon.json", atomically: true, encoding: .utf8)
print("wrote \(outDir)")
