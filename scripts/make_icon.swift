// make_icon.swift — 生成 TunnelPad 应用图标（1024px PNG）
//
// 用法: swift scripts/make_icon.swift <输出.png>
// 生成 iconset 并合成 icns（在仓库根目录）:
//   mkdir -p /tmp/TunnelPad.iconset
//   sips -z 16 16     out.png --out /tmp/TunnelPad.iconset/icon_16x16.png
//   sips -z 32 32     out.png --out /tmp/TunnelPad.iconset/icon_16x16@2x.png
//   sips -z 32 32     out.png --out /tmp/TunnelPad.iconset/icon_32x32.png
//   sips -z 64 64     out.png --out /tmp/TunnelPad.iconset/icon_32x32@2x.png
//   sips -z 128 128   out.png --out /tmp/TunnelPad.iconset/icon_128x128.png
//   sips -z 256 256   out.png --out /tmp/TunnelPad.iconset/icon_128x128@2x.png
//   sips -z 256 256   out.png --out /tmp/TunnelPad.iconset/icon_256x256.png
//   sips -z 512 512   out.png --out /tmp/TunnelPad.iconset/icon_256x256@2x.png
//   sips -z 512 512   out.png --out /tmp/TunnelPad.iconset/icon_512x512.png
//   sips -z 1024 1024 out.png --out /tmp/TunnelPad.iconset/icon_512x512@2x.png
//   iconutil -c icns /tmp/TunnelPad.iconset -o App/Resources/TunnelPad.icns

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法: swift scripts/make_icon.swift <输出.png>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 背景圆角矩形（蓝色渐变）
let inset: CGFloat = 64
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180).addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.92, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.30, blue: 0.68, alpha: 1),
])?.draw(in: rect, angle: -90)

// TunnelPad 字标：外圈 + 居中 T。
let ringRect = NSRect(x: 218, y: 218, width: 588, height: 588)
let ring = NSBezierPath(ovalIn: ringRect)
ring.lineWidth = 52
NSColor.white.withAlphaComponent(0.96).setStroke()
ring.stroke()

let letter = "T" as NSString
let letterFont = NSFont.systemFont(ofSize: 432, weight: .bold)
let letterAttributes: [NSAttributedString.Key: Any] = [
    .font: letterFont,
    .foregroundColor: NSColor.white,
]
let letterSize = letter.size(withAttributes: letterAttributes)
let letterRect = NSRect(
    x: (size - letterSize.width) / 2,
    y: (size - letterSize.height) / 2 - 38,
    width: letterSize.width,
    height: letterSize.height
)
letter.draw(in: letterRect, withAttributes: letterAttributes)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("生成 PNG 失败\n".utf8))
    exit(1)
}
do {
    try png.write(to: outputURL)
    print("已生成 \(outputURL.path)")
} catch {
    FileHandle.standardError.write(Data("写入失败: \(error)\n".utf8))
    exit(1)
}
