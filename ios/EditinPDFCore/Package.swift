// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "EditinPDFCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "EditinPDFCore", targets: ["EditinPDFCore"])],
    targets: [
        .binaryTarget(name: "EditinPDFCoreFFI", path: "EditinPDFCoreFFI.xcframework"),
        .target(
            name: "EditinPDFCore",
            dependencies: ["EditinPDFCoreFFI"],
            path: "Sources/EditinPDFCore",
            // A binary target carries no link flags, so what the Rust static library needs from the
            // system is declared here: the libraries `rustc --print native-static-libs` lists for
            // editinpdf-core, less -lSystem -lc -lm, which every link has. CoreFoundation (time zones)
            // and iconv (the libc crate) on every slice; Security on macOS only (the engine's signing).
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(name: "EditinPDFCoreTests", dependencies: ["EditinPDFCore"], path: "Tests/EditinPDFCoreTests", resources: [.copy("Fixtures")]),
    ]
)
