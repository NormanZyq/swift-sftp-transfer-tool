// swift-tools-version:5.9
import PackageDescription

// 原生 macOS SFTP 双窗格传输工具。
let package = Package(
    name: "SFTPTransfer",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14) // Citadel 要求 macOS 14+
    ],
    dependencies: [
        // 锁定到具体 commit（可复现构建），而非跟随移动的分支。
        .package(
            url: "https://github.com/orlandos-nl/Citadel.git",
            revision: "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SFTPTransfer",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
