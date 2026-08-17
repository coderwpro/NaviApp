import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, a])!
}

let cyan      = rgb(64, 216, 255)
let cyanDeep  = rgb(20, 150, 210)
let bodyLight = rgb(238, 244, 252)
let bodyMid   = rgb(199, 213, 230)
let bodyDark  = rgb(163, 181, 203)
let ink       = rgb(18, 28, 44)

// ── Background: deep navy, slightly brighter behind the head ────────────────
if let g = CGGradient(colorsSpace: cs, colors: [rgb(24, 44, 74), rgb(8, 14, 26)] as CFArray,
                      locations: [0, 1]) {
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: S/2, y: S*0.60), startRadius: 0,
                           endCenter: CGPoint(x: S/2, y: S*0.55), endRadius: S*0.78,
                           options: [.drawsAfterEndLocation])
}

// helper: rounded rect path
func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillRounded(_ r: CGRect, _ radius: CGFloat, _ top: CGColor, _ bottom: CGColor) {
    ctx.saveGState()
    ctx.addPath(roundedPath(r, radius)); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY),
                               end: CGPoint(x: r.midX, y: r.minY), options: [])
    }
    ctx.restoreGState()
}

// ── Ears — drawn first so the head overlaps them ────────────────────────────
for side in [-1.0, 1.0] as [CGFloat] {
    ctx.saveGState()
    ctx.translateBy(x: S/2 + side * 316, y: 672)
    ctx.rotate(by: side * 0.30)
    let ear = CGRect(x: -86, y: -150, width: 172, height: 300)
    ctx.saveGState()
    ctx.addPath(roundedPath(ear, 74)); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [bodyMid, bodyDark] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 130), end: CGPoint(x: 0, y: -130), options: [])
    }
    ctx.restoreGState()
    // inner ear
    ctx.setFillColor(cyanDeep.copy(alpha: 0.35)!)
    ctx.addPath(roundedPath(CGRect(x: -34, y: -70, width: 68, height: 150), 34))
    ctx.fillPath()
    ctx.restoreGState()
}

// ── Head ────────────────────────────────────────────────────────────────────
let head = CGRect(x: (S - 660)/2, y: 250, width: 660, height: 560)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 0, 0, 0.55))
fillRounded(head, 200, bodyLight, bodyMid)
ctx.restoreGState()

// ── Antenna — drawn after the head so the stalk actually connects to it ─────
ctx.setStrokeColor(bodyDark)
ctx.setLineWidth(22)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: S/2, y: 762))
ctx.addLine(to: CGPoint(x: S/2, y: 856))
ctx.strokePath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: cyan)
ctx.setFillColor(cyan)
ctx.fillEllipse(in: CGRect(x: S/2 - 40, y: 846, width: 80, height: 80))
ctx.restoreGState()
ctx.setFillColor(rgb(255, 255, 255, 0.85))
ctx.fillEllipse(in: CGRect(x: S/2 - 14, y: 886, width: 28, height: 28))

// visor panel behind the eyes — the "robot" tell
let visor = CGRect(x: (S - 520)/2, y: 470, width: 520, height: 250)
fillRounded(visor, 118, rgb(30, 48, 78), rgb(14, 24, 42))

// ── Eyes ────────────────────────────────────────────────────────────────────
for side in [-1.0, 1.0] as [CGFloat] {
    let cx = S/2 + side * 122
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 52, color: cyan)
    ctx.setFillColor(cyan)
    ctx.addPath(roundedPath(CGRect(x: cx - 74, y: 512, width: 148, height: 166), 74))
    ctx.fillPath()
    ctx.restoreGState()
    // highlights
    ctx.setFillColor(rgb(255, 255, 255, 0.92))
    ctx.fillEllipse(in: CGRect(x: cx - 46, y: 606, width: 46, height: 46))
    ctx.setFillColor(rgb(255, 255, 255, 0.55))
    ctx.fillEllipse(in: CGRect(x: cx + 10, y: 566, width: 22, height: 22))
}

// ── Muzzle ──────────────────────────────────────────────────────────────────
let muzzle = CGRect(x: (S - 330)/2, y: 292, width: 330, height: 196)
fillRounded(muzzle, 96, rgb(252, 253, 255), rgb(225, 234, 246))

// nose
ctx.setFillColor(ink)
ctx.addPath(roundedPath(CGRect(x: S/2 - 52, y: 396, width: 104, height: 72), 34))
ctx.fillPath()
ctx.setFillColor(rgb(255, 255, 255, 0.35))
ctx.fillEllipse(in: CGRect(x: S/2 - 30, y: 440, width: 34, height: 18))

// smile: two arcs under the nose
ctx.setStrokeColor(ink)
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: S/2, y: 396))
ctx.addLine(to: CGPoint(x: S/2, y: 372))
ctx.strokePath()
for side in [-1.0, 1.0] as [CGFloat] {
    ctx.addArc(center: CGPoint(x: S/2 + side * 44, y: 374), radius: 44,
               startAngle: side > 0 ? .pi : 0,
               endAngle: side > 0 ? 0 : .pi,
               clockwise: side > 0 ? false : true)
    ctx.strokePath()
}

// cheeks
for side in [-1.0, 1.0] as [CGFloat] {
    ctx.setFillColor(rgb(255, 138, 170, 0.32))
    ctx.fillEllipse(in: CGRect(x: S/2 + side * 232 - 46, y: 352, width: 92, height: 62))
}

// ── Collar tag, a small nod to the robot's cyan ─────────────────────────────
let collar = CGRect(x: (S - 470)/2, y: 176, width: 470, height: 66)
fillRounded(collar, 33, cyanDeep, rgb(12, 90, 132))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 26, color: cyan)
ctx.setFillColor(cyan)
ctx.fillEllipse(in: CGRect(x: S/2 - 30, y: 150, width: 60, height: 60))
ctx.restoreGState()

// ── Write PNG ───────────────────────────────────────────────────────────────
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no image") }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
