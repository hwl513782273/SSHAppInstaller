import AppKit
import Foundation

// 生成 1024x1024 主图标:透明背景 + 圆角方形渐变 + 白色 "下载/安装" 符号
// 透明圆角满足 macOS squircle 规则(hasAlpha),系统会套标准圆角
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no graphics context") }

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = size * 0.22
let roundRect = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
let colors = [NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor,
             NSColor(red: 0.37, green: 0.36, blue: 0.90, alpha: 1).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray,
                          locations: [0, 1])!
roundRect.addClip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

if let sym = NSImage(systemSymbolName: "square.and.arrow.down.fill", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.52, weight: .bold)
    let colored = NSImage.SymbolConfiguration(paletteColors: [NSColor.white])
    let finalCfg = cfg.applying(colored)
    if let s = sym.withSymbolConfiguration(finalCfg) {
        let ds = s.size
        let dest = NSRect(x: (size - ds.width) / 2, y: (size - ds.height) / 2, width: ds.width, height: ds.height)
        s.draw(in: dest, from: NSZeroRect, operation: NSCompositingOperation.sourceOver, fraction: CGFloat(1.0))
    }
}
img.unlockFocus()

if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "/tmp/icon_master.png"))
    print("wrote /tmp/icon_master.png")
} else {
    fatalError("png export failed")
}
