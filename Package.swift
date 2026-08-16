// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(name: "HeadroomCore"),
    .target(name: "HeadroomTokens", dependencies: ["HeadroomCore"]),
    .testTarget(
        name: "HeadroomCoreTests",
        dependencies: ["HeadroomCore", "HeadroomTokens"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(
        name: "HeadroomTrayTests",
        dependencies: ["HeadroomCore", "HeadroomTray"]
    ),
]

// The dependency on CAppIndicator must be added inside the same #if os(Linux)
// block that appends the systemLibrary target — naming CAppIndicator in the
// dependency list on macOS is an unresolvable target reference and breaks
// manifest loading for the primary platform, even with a .when(platforms:)
// condition.
var trayDependencies: [Target.Dependency] = ["HeadroomCore"]

#if os(Linux)
trayDependencies.append("CAppIndicator")
targets.append(
    .systemLibrary(
        name: "CAppIndicator",
        path: "Sources/CAppIndicator",
        pkgConfig: "ayatana-appindicator3-0.1",
        providers: [.apt(["libayatana-appindicator3-dev", "libgtk-3-dev"])]
    )
)
#endif

targets.append(.target(name: "HeadroomTray", dependencies: trayDependencies))

targets.append(
    .executableTarget(
        name: "Headroom",
        dependencies: ["HeadroomCore", "HeadroomTokens", "HeadroomTray"]
    )
)

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    targets: targets
)
