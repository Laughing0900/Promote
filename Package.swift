// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Promote",
    platforms: [.macOS(.v14)],
    dependencies: [
        // ponytail: pinned to main — v1.13.0's mouseDragged drops mode-1002 drags (tmux mouse
        // copy-mode never sees MouseDrag1Pane); fixed upstream after 1.13.0. Back to `from:` on next tag.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "d5ee56e1c74777120f3af688600d336de4201bd2"),
    ],
    targets: [
        .executableTarget(name: "Promote", dependencies: ["SwiftTerm"]),
    ]
)
