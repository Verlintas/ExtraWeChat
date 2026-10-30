// swift-tools-version: 5.9
// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "ExtraWeChat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ExtraWeChat", targets: ["ExtraWeChat"])
    ],
    targets: [
        .executableTarget(
            name: "ExtraWeChat",
            path: "Sources/ExtraWeChat"
        )
    ]
)
