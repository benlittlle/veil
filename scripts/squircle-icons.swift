// Re-fits the generated Veil icons to Apple's icon grid: a 824 px continuous-corner squircle
// centred on a 1024 px canvas. macOS 26 puts icons that don't match this shape on a grey plate.
// Usage: swift scripts/squircle-icons.swift <src-dir> <out-dir>
import AppKit
import SwiftUI

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let canvas = 1024, tile: CGFloat = 824, margin: CGFloat = 100
// The generated tile's opaque area is about x 83–939, y 77–946. Crop inside it so the
// glossy rim and the old rounded corners fall outside the new mask.
let inset: CGFloat = 34
let crop = CGRect(x: 83 + inset, y: 77 + inset, width: 856 - 2 * inset, height: 869 - 2 * inset)

for name in ["graphite", "clay", "ocean", "plum", "forest", "gold", "indigo"] {
    guard let img = NSImage(contentsOf: src.appendingPathComponent("veil-icon-\(name).png")),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("skip \(name)"); continue }
    // Square crop centred in the tile region (CGImage coords are top-down here for cropping).
    let side = min(crop.width, crop.height)
    let sq = CGRect(x: crop.midX - side / 2, y: crop.midY - side / 2, width: side, height: side)
    guard let part = cg.cropping(to: sq) else { continue }
    let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: margin, y: margin, width: tile, height: tile)
    let mask = RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous).path(in: rect).cgPath
    ctx.addPath(mask); ctx.clip()
    ctx.draw(part, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("veil-icon-\(name).png"))
    print("wrote \(name)")
}
