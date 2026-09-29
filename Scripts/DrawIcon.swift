import AppKit

// Akiakane（秋茜 = アキアカネ、赤とんぼ）のアイコンを描くスクリプト。
// 秋の夕空を思わせる朱色のグラデーションに、白いとんぼのシルエットを置く。
//
// アプリのターゲットには含めない（アプリの同期フォルダは Akiakane/ なので、Scripts/ は入らない）。
// 使い方:
//   swiftc -O -o /tmp/DrawIcon Scripts/DrawIcon.swift && /tmp/DrawIcon /tmp/icon_1024.png
//   その後 sips で各サイズに縮小して Akiakane/Assets.xcassets/AppIcon.appiconset/ に置く。
let size: CGFloat = 1024
let outputPath = CommandLine.arguments[1]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)
cg.interpolationQuality = .high

// 座標は上が原点になるよう反転して扱う（座標を考えやすくするため）。
cg.translateBy(x: 0, y: size)
cg.scaleBy(x: 1, y: -1)

// macOS のアイコンテンプレートに合わせ、1024 のうち 824 を角丸四角が占める。
let inset: CGFloat = 100
let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = plate.width * 0.2237
let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 影
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
cg.addPath(platePath)
cg.setFillColor(NSColor(red: 0.85, green: 0.30, blue: 0.18, alpha: 1).cgColor)
cg.fillPath()
cg.restoreGState()

// 朱色のグラデーション（上が明るい橙、下が深い茜色）
cg.saveGState()
cg.addPath(platePath)
cg.clip()
let colors = [
    NSColor(red: 0.99, green: 0.60, blue: 0.32, alpha: 1).cgColor,
    NSColor(red: 0.90, green: 0.33, blue: 0.18, alpha: 1).cgColor,
    NSColor(red: 0.66, green: 0.13, blue: 0.12, alpha: 1).cgColor
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: plate.minY), end: CGPoint(x: 512, y: plate.maxY), options: [])

// 夕日の淡い光を左上に
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(white: 1, alpha: 0.30).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                      locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 250), startRadius: 0,
                      endCenter: CGPoint(x: 330, y: 250), endRadius: 520, options: [])
cg.restoreGState()

// とんぼ
let cx: CGFloat = 512
let ivory = NSColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
let wingFill = NSColor(white: 1, alpha: 0.62)
let wingStroke = NSColor(white: 1, alpha: 0.95)

func wing(center: CGPoint, width: CGFloat, height: CGFloat, angle: CGFloat) {
    cg.saveGState()
    cg.translateBy(x: center.x, y: center.y)
    cg.rotate(by: angle * .pi / 180)
    // 先端がやや細くなる羽の形を、楕円を2つ重ねて作る。
    let outline = CGMutablePath()
    outline.addEllipse(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    cg.addPath(outline)
    cg.setFillColor(wingFill.cgColor)
    cg.fillPath()
    cg.addPath(outline)
    cg.setStrokeColor(wingStroke.cgColor)
    cg.setLineWidth(7)
    cg.strokePath()
    // 翅脈（主脈1本と横脈）
    cg.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor)
    cg.setLineWidth(4)
    cg.move(to: CGPoint(x: -width / 2 + 10, y: 0))
    cg.addLine(to: CGPoint(x: width / 2 - 10, y: 0))
    cg.strokePath()
    cg.setLineWidth(2.5)
    for i in 1...5 {
        let x = -width / 2 + width * CGFloat(i) / 6
        let h = height / 2 * sqrt(max(0, 1 - pow(x / (width / 2), 2))) - 6
        cg.move(to: CGPoint(x: x, y: -h))
        cg.addLine(to: CGPoint(x: x, y: h))
    }
    cg.strokePath()
    cg.restoreGState()
}

// 影を薄く付けて背景から浮かせる
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.25).cgColor)

// 後翅（下側、やや水平）
wing(center: CGPoint(x: cx - 175, y: 505), width: 320, height: 118, angle: -8)
wing(center: CGPoint(x: cx + 175, y: 505), width: 320, height: 118, angle: 8)
// 前翅（上側、やや上向き）
wing(center: CGPoint(x: cx - 185, y: 405), width: 340, height: 104, angle: -20)
wing(center: CGPoint(x: cx + 185, y: 405), width: 340, height: 104, angle: 20)

// 胸部
cg.setFillColor(ivory.cgColor)
cg.fillEllipse(in: CGRect(x: cx - 46, y: 380, width: 92, height: 130))

// 腹部（下に向かって細くなる）
let abdomen = CGMutablePath()
abdomen.move(to: CGPoint(x: cx - 30, y: 490))
abdomen.addCurve(to: CGPoint(x: cx - 11, y: 860),
                 control1: CGPoint(x: cx - 34, y: 620), control2: CGPoint(x: cx - 14, y: 760))
abdomen.addArc(center: CGPoint(x: cx, y: 860), radius: 11, startAngle: .pi, endAngle: 0, clockwise: true)
abdomen.addCurve(to: CGPoint(x: cx + 30, y: 490),
                 control1: CGPoint(x: cx + 14, y: 760), control2: CGPoint(x: cx + 34, y: 620))
abdomen.closeSubpath()
cg.addPath(abdomen)
cg.fillPath()

// 頭と複眼
cg.fillEllipse(in: CGRect(x: cx - 52, y: 290, width: 104, height: 104))
cg.setFillColor(NSColor(red: 0.62, green: 0.14, blue: 0.12, alpha: 1).cgColor)
cg.fillEllipse(in: CGRect(x: cx - 54, y: 300, width: 50, height: 56))
cg.fillEllipse(in: CGRect(x: cx + 4, y: 300, width: 50, height: 56))
cg.restoreGState()

// 腹部の節（背景色の細い線）
cg.setStrokeColor(NSColor(red: 0.80, green: 0.28, blue: 0.16, alpha: 0.9).cgColor)
cg.setLineWidth(5)
for y in stride(from: CGFloat(540), through: 820, by: 46) {
    let t = (y - 490) / (860 - 490)
    let halfWidth = 30 - 19 * t
    cg.move(to: CGPoint(x: cx - halfWidth + 3, y: y))
    cg.addLine(to: CGPoint(x: cx + halfWidth - 3, y: y))
}
cg.strokePath()

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
