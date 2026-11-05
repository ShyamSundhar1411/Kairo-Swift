// swift-tools-version:5.9
import PackageDescription

// On-device domain for the iPhone and Apple Watch apps.
//
// The five LLM roles used to live here as a second target. They now run in the
// Python backend (../../backend), so this package holds only what must work
// offline and must never leave the device: the state machines, the arbitration
// policy, the evidence gate, and the ports the apps implement against.

let package = Package(
    name: "Kairo",
    platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "KairoKit", targets: ["KairoKit"]),
        .executable(name: "kairo-uml", targets: ["kairo-uml"]),
    ],
    targets: [
        // Pure domain + orchestration. No HealthKit, no SwiftUI, no networking.
        // This is the layer the original UML describes, and it builds without Xcode.
        .target(name: "KairoKit"),
        // Generates PlantUML for every state machine straight from its transition table,
        // so the diagrams in the report cannot drift from the code that implements them.
        .executableTarget(name: "kairo-uml", dependencies: ["KairoKit"]),
        .testTarget(name: "KairoKitTests", dependencies: ["KairoKit"]),
    ]
)
