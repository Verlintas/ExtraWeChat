import AppKit
import SwiftUI

enum BrandAssets {
    /// The app's own icon (the same artwork shown in Finder/Dock).
    static var appIcon: Image {
        if let image = NSImage(named: NSImage.applicationIconName) {
            return Image(nsImage: image)
        }
        return Image(systemName: "bubble.left.and.bubble.right.fill")
    }

    /// Monochrome template for the menu bar, derived from WeChat.png.
    static var menuBarIcon: NSImage {
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill",
                       accessibilityDescription: "ExtraWeChat") ?? NSImage()
    }
}
