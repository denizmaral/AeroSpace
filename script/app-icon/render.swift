import AppKit
import CoreGraphics

// MarSpace app icon: a squircle (continuous corners) with a night-blue gradient, frosted window tiles in a dwindle
// layout, the focused tile outlined by the cyan-to-green focus border gradient with a glow.
// Usage: swift script/app-icon/render.swift resources/Assets.xcassets/AppIcon.appiconset
// Writes icon_<size>.png for 16, 32, 64, 128, 256, 512, 1024 (the small sizes are simplified to stay legible)

func superellipse(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let (cx, cy, a, b) = (rect.midX, rect.midY, rect.width / 2, rect.height / 2)
    let steps = 720
    for i in 0 ... steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let (c, s) = (cos(t), sin(t))
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024) // Draw in 1024 units
    let small = size <= 32
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: Apple's icon grid, 824 pt body centered with a soft drop shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = superellipse(in: body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x101426))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: rgb, colors: [color(0x1C2551), color(0x0B1024)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
    // A soft light from the top left
    let light = CGGradient(colorsSpace: rgb, colors: [color(0x5A7BFF, 0.35), color(0x5A7BFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: 260, y: 860), startRadius: 0, endCenter: CGPoint(x: 260, y: 860), endRadius: 620, options: [])

    // Tiles: dwindle layout. The gaps and the radius grow on small sizes so that they stay visible
    let inset: CGFloat = small ? 170 : 190
    let gap: CGFloat = small ? 56 : 40
    let area = body.insetBy(dx: inset - 100, dy: inset - 100)
    let radius: CGFloat = small ? 44 : 34
    let leftWidth = (area.width - gap) * 0.56
    let left = CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
    let rightX = left.maxX + gap
    let rightHeight = (area.height - gap) / 2
    let topRight = CGRect(x: rightX, y: area.minY + rightHeight + gap, width: area.maxX - rightX, height: rightHeight)
    let bottomRight = CGRect(x: rightX, y: area.minY, width: area.maxX - rightX, height: rightHeight)

    func tile(_ rect: CGRect, alpha: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let fill = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, alpha), color(0xC9D6FF, alpha * 0.82)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        if !small { // The title bar with its three buttons
            let bar = CGRect(x: rect.minX, y: rect.maxY - 58, width: rect.width, height: 58)
            ctx.setFillColor(color(0xFFFFFF, alpha * 0.45))
            ctx.fill(bar)
            for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
                ctx.setFillColor(color(hex, 0.95))
                ctx.fillEllipse(in: CGRect(x: rect.minX + 30 + CGFloat(index) * 34, y: rect.maxY - 41, width: 22, height: 22))
            }
        }
        ctx.restoreGState()
    }
    tile(topRight, alpha: 0.78)
    tile(bottomRight, alpha: 0.78)
    tile(left, alpha: 0.96)

    // The focus border around the left tile: the gradient of MarSpace's focus border, with a glow
    let borderWidth: CGFloat = small ? 34 : 20
    let border = left.insetBy(dx: -borderWidth * 0.9, dy: -borderWidth * 0.9)
    let borderPath = CGPath(roundedRect: border, cornerWidth: radius + borderWidth, cornerHeight: radius + borderWidth, transform: nil)
        .copy(strokingWithWidth: borderWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let focus = CGGradient(colorsSpace: rgb, colors: [color(0x33CCFF), color(0x00FF99)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: small ? 0 : 46, color: color(0x22E6C8, 0.85))
    ctx.addPath(borderPath)
    ctx.setFillColor(color(0x22E6C8))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(borderPath)
    ctx.clip()
    ctx.drawLinearGradient(focus, start: CGPoint(x: border.minX, y: border.maxY), end: CGPoint(x: border.maxX, y: border.minY), options: [])
    ctx.restoreGState()

    // A thin highlight along the edge of the body
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

let output = URL(filePath: CommandLine.arguments[1])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(cgImage: render(size: size))
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: "icon_\(size).png"))
}
print("rendered")
