import AppKit
import SwiftUI

/// The generated light application-icon artwork for views inside the app. Loading this resource directly avoids the
/// Launch Services cache behind `NSApplication.applicationIconImage` when another installed build shares our bundle ID.
enum BrandIcon {
    static let image: NSImage = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled AppIcon.svg")
        }
        image.isTemplate = false
        return image
    }()
}

extension NSColor {
    /// Brand blue for text, links and icons. The mascot's tail is #80C5EF (see `Color.brandFill`); in light mode
    /// text needs a deeper vivid sky, #0F74B3 (4.5:1 on the window, 5.0:1 on white); in dark mode the tail colour
    /// itself works as text (8.9:1). Mirrors AccentColor in the app's asset catalog.
    static let triwardenBrand = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x80 / 255, green: 0xC5 / 255, blue: 0xEF / 255, alpha: 1)
            : NSColor(srgbRed: 0x0F / 255, green: 0x74 / 255, blue: 0xB3 / 255, alpha: 1)
    }
}

extension Color {
    /// The tail's sky blue as a fill (buttons, the vault mark, selection). Pair with `onBrandFill`.
    static let brandFill = Color(red: 0x80 / 255, green: 0xC5 / 255, blue: 0xEF / 255)
    /// Primary buttons with white labels: one flat, slightly deeper tail sky (no gradient, no glow).
    static let brandButton = Color(red: 0x0F / 255, green: 0x74 / 255, blue: 0xB3 / 255)

    /// Navy text on `brandFill` (7.9:1).
    static let onBrandFill = Color(red: 0x0B / 255, green: 0x2A / 255, blue: 0x40 / 255)

    /// The tail itself: a pale sky tint for washes and soft fills (deep blue in dark mode).
    static let brandTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1B / 255, green: 0x3A / 255, blue: 0x52 / 255, alpha: 1)
            : NSColor(srgbRed: 0xCB / 255, green: 0xE4 / 255, blue: 0xF6 / 255, alpha: 1)
    })
}
