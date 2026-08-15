// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(name: "ClaudeUsageCore"),
    .target(name: "ClaudeUsageTokens", dependencies: ["ClaudeUsageCore"]),
    .testTarget(
        name: "ClaudeUsageCoreTests",
        dependencies: ["ClaudeUsageCore", "ClaudeUsageTokens"],
        resources: [.copy("Fixtures")]
    ),
    .testTarget(
        name: "ClaudeUsageTrayTests",
        dependencies: ["ClaudeUsageCore", "ClaudeUsageTray"]
    ),
]

// The dependency on CAppIndicator must be added inside the same #if os(Linux)
// block that appends the systemLibrary target — naming CAppIndicator in the
// dependency list on macOS is an unresolvable target reference and breaks
// manifest loading for the primary platform, even with a .when(platforms:)
// condition.
var trayDependencies: [Target.Dependency] = ["ClaudeUsageCore"]

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

targets.append(.target(name: "ClaudeUsageTray", dependencies: trayDependencies))

targets.append(
    .executableTarget(
        name: "ClaudeUsageBar",
        dependencies: ["ClaudeUsageCore", "ClaudeUsageTokens", "ClaudeUsageTray"]
    )
)

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: targets
)
