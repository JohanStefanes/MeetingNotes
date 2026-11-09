// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MeetingNotes",
    platforms: [.macOS("14.2")],
    // Only the diarizer: drops FluidAudio's TTS backends and the NeMo text-normalization binary.
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"])],
    targets: [
        .executableTarget(name: "MeetingNotes", path: "Sources/MeetingNotes"),
        .executableTarget(name: "meeting-diarize", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Sources/meeting-diarize"),
    ],
    swiftLanguageModes: [.v5]
)
