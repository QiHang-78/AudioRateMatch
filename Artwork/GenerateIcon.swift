// Original AudioRateMatch artwork, distributed under the project's MIT license.
// Render with scripts/generate-icons.sh. Coordinates use a 1024-point canvas.
import AppKit

func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let midnight = rgba(8, 25, 49)
let ocean = rgba(26, 73, 111)
let mint = rgba(92, 239, 214)
let ice = rgba(235, 250, 255)

func drawArrow(_ context: CGContext, from start: CGFloat, to end: CGFloat, color: CGColor, compact: Bool) {
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 254
    let radians = CGFloat.pi / 180
    let angle = end * radians
    let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    let tangent = CGPoint(x: -sin(angle), y: cos(angle))
    let normal = CGPoint(x: cos(angle), y: sin(angle))
    let width: CGFloat = compact ? 62 : 46

    context.saveGState()
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.addArc(center: center, radius: radius, startAngle: start * radians,
                   endAngle: angle, clockwise: false)
    context.strokePath()

    // Rounded corners soften the arrowhead without a separate raster overlay.
    let tip = CGPoint(x: point.x + tangent.x * 52, y: point.y + tangent.y * 52)
    let back = CGPoint(x: point.x - tangent.x * 26, y: point.y - tangent.y * 26)
    let halfWidth: CGFloat = compact ? 58 : 51
    context.setFillColor(color)
    context.setLineJoin(.round)
    context.setLineWidth(12)
    context.move(to: tip)
    context.addLine(to: CGPoint(x: back.x + normal.x * halfWidth, y: back.y + normal.y * halfWidth))
    context.addLine(to: CGPoint(x: back.x - normal.x * halfWidth, y: back.y - normal.y * halfWidth))
    context.closePath()
    context.drawPath(using: .fillStroke)
    context.restoreGState()
}

func renderIcon(pixels: Int) throws -> Data {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate bitmap"])
    }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let compact = pixels <= 64
    let bounds = CGRect(x: 96, y: 96, width: 832, height: 832)
    let tile = CGPath(roundedRect: bounds, cornerWidth: 188, cornerHeight: 188, transform: nil)

    // Leave a transparent margin for Finder and the Dock, including the shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: compact ? 10 : 27,
                      color: rgba(0, 10, 27, 0.27))
    context.addPath(tile)
    context.setFillColor(midnight)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let background = CGGradient(colorsSpace: colorSpace, colors: [ocean, midnight] as CFArray,
                                locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 230, y: 928),
                               end: CGPoint(x: 790, y: 96), options: [])
    if !compact {
        let light = CGGradient(colorsSpace: colorSpace,
                               colors: [rgba(69, 205, 204, 0.19), rgba(69, 205, 204, 0)] as CFArray,
                               locations: [0, 1])!
        context.drawRadialGradient(light, startCenter: CGPoint(x: 260, y: 885), startRadius: 0,
                                   endCenter: CGPoint(x: 260, y: 885), endRadius: 790, options: [])
    }
    context.restoreGState()

    if !compact {
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 186,
                              cornerHeight: 186, transform: nil))
        context.setStrokeColor(rgba(179, 230, 245, 0.16))
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()
    }

    drawArrow(context, from: 24, to: 151, color: mint, compact: compact)
    drawArrow(context, from: 204, to: 331, color: ice, compact: compact)

    let heights: [CGFloat] = compact ? [108, 246, 108] : [80, 158, 248, 158, 80]
    let spacing: CGFloat = compact ? 104 : 73
    let barWidth: CGFloat = compact ? 62 : 42
    context.setFillColor(ice)
    for (index, height) in heights.enumerated() {
        let x = 512 + (CGFloat(index) - CGFloat(heights.count - 1) / 2) * spacing
        let rect = CGRect(x: x - barWidth / 2, y: 512 - height / 2, width: barWidth, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2,
                              cornerHeight: barWidth / 2, transform: nil))
        context.fillPath()
    }

    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot encode PNG"])
    }
    return data
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: GenerateIcon ICONSET_DIRECTORY PREVIEW_PNG\n", stderr)
    exit(2)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let preview = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try renderIcon(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try renderIcon(pixels: 1024).write(to: preview)
print("Generated icon set and 1024px preview")
