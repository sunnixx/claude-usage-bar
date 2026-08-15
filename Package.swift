// swift-tools-version: 6.0
import PackageDescription

// The executable is macOS-only until the Linux and Windows tray backends land
// (Tasks 6 and 7). Until then, Linux and Windows CI builds and tests the
// portable targets, which is the point of the phasing: everything verifiable is
// proven green before any unrunnable code is written.
var targets: [Target] = [
    .target(name: "ClaudeUsageCore"),
    .target(name: "ClaudeUsageTokens", dependencies: ["ClaudeUsageCore"]),
    .target(name: "ClaudeUsageTray", dependencies: ["ClaudeUsageCore"]),
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

#if os(macOS)
targets.append(
    .executableTarget(
        name: "ClaudeUsageBar",
        dependencies: ["ClaudeUsageCore", "ClaudeUsageTokens", "ClaudeUsageTray"]
    )
)
#endif

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: targets
)
