// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

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
    ///
    /// Loaded as a plain file from Contents/Resources. We deliberately avoid
    /// SwiftPM's `Bundle.module`: its generated accessor crashes when the
    /// resource bundle layout differs between local Xcode and CI runners.
    static var menuBarIcon: NSImage {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("MenuBarIcon.png"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MenuBarIcon.png"),
        ].compactMap { $0 }

        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }
        return NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill",
                       accessibilityDescription: "ExtraWeChat") ?? NSImage()
    }
}
