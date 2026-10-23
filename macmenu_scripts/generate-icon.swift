#!/usr/bin/env swift
// Generates AppIcon.icns from the SF Symbol "contextualmenu.and.cursorarrow"

import AppKit

let sizes: [(CGFloat, String)] = [
    (16,   "icon_16x16"),
    (32,   "icon_16x16@2x"),
    (32,   "icon_32x32"),
    (64,   "icon_32x32@2x"),
    (128,  "icon_128x128"),
    (256,  "icon_128x128@2x"),
    (256,  "icon_256x256"),
    (512,  "icon_256x256@2x"),
    (512,  "icon_512x512"),
    (1024, "icon_512x512@2x"),
]

let iconsetPath = "/tmp/MenuDuJour.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

for (size, name) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Background: rounded rectangle with gradient
        let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.05, dy: size * 0.05),
                                   xRadius: size * 0.18, yRadius: size * 0.18)
        let gradient = NSGradient(starting: NSColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1.0),
                                  ending: NSColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1.0))!
        gradient.draw(in: bgPath, angle: -90)

        // SF Symbol
        let symbolSize = size * 0.55
        let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let symbolSize = symbol.size
            let x = (rect.width - symbolSize.width) / 2
            let y = (rect.height - symbolSize.height) / 2
            NSColor.white.setFill()
            let tinted = NSImage(size: symbolSize, flipped: false) { tintRect in
                symbol.draw(in: tintRect)
                NSColor.white.set()
                tintRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
        }
        return true
    }

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to render \(name)")
        continue
    }
    let filePath = "\(iconsetPath)/\(name).png"
    try png.write(to: URL(fileURLWithPath: filePath))
}

print("Iconset created at \(iconsetPath)")
print("Converting to icns...")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", "\(iconsetPath)/../MenuDuJour.icns"]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Icon created at /tmp/MenuDuJour.icns")
} else {
    print("iconutil failed with status \(process.terminationStatus)")
}
