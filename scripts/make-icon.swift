// Renders Resources/AppIcon.icns: white SF Symbol waveform on a black rounded square (macOS icon grid).
import AppKit
let out = CommandLine.arguments[1]
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)   // Apple's 1024 grid: 824 body, ~185 corner
NSGradient(colors: [NSColor(white: 0.18, alpha: 1), NSColor(white: 0.02, alpha: 1)])!
    .draw(in: NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185), angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold).applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
sym.draw(in: NSRect(x: (size - sym.size.width) / 2, y: (size - sym.size.height) / 2,
                    width: sym.size.width, height: sym.size.height))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
