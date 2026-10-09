// Dibuja el ícono de la app (1024x1024) y lo guarda como PNG.
import AppKit

let tam: CGFloat = 1024
let img = NSImage(size: NSSize(width: tam, height: tam))
img.lockFocus()
let marco = NSRect(x: 100, y: 100, width: 824, height: 824)
let forma = NSBezierPath(roundedRect: marco, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.10, green: 0.78, blue: 0.72, alpha: 1),
                    NSColor(red: 0.12, green: 0.42, blue: 0.95, alpha: 1)])!.draw(in: forma, angle: -65)
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let s = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let r = NSRect(x: (tam - s.size.width) / 2, y: (tam - s.size.height) / 2 + 10, width: s.size.width, height: s.size.height)
    s.draw(in: r)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
