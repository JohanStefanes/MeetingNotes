// Speaker diarization for diarize.py: FluidAudio's offline pipeline (pyannote segmentation, WeSpeaker, VBx) on Core ML.
// A separate process, so the models leave memory as soon as the meeting is labelled. JSON on stdout, logs on stderr.
//
//   meeting-diarize audio.wav [--speakers N | --max-speakers N]  → {"turns": [{"start", "end", "speaker", "embedding"}]}
//   meeting-diarize audio.wav --spans < [[start, end], …]         → {"embeddings": [[…], …]}
//
// Every embedding comes from embedSpans, so turn vectors and the enrolled voice (diarize.py --enroll) share one space.
// Models download once to ~/Library/Application Support/FluidAudio/Models, after that it runs offline.
import FluidAudio
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else {
    FileHandle.standardError.write(Data("usage: meeting-diarize audio.wav [--speakers N | --max-speakers N | --spans]\n".utf8))
    exit(2)
}
func number(_ flag: String) -> Int? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil }
}

var config = OfflineDiarizerConfig.default
if let n = number("--speakers") {
    config = config.withSpeakers(exactly: n)
} else if let n = number("--max-speakers") {
    config = config.withSpeakers(max: n)
}
let manager = OfflineDiarizerManager(config: config)
try await manager.prepareModels()
let (source, _) = try AudioSourceFactory().makeDiskBackedSource(
    from: URL(fileURLWithPath: args[1]), targetSampleRate: config.segmentation.sampleRate)
defer { source.cleanup() }

let output: [String: Any]
if args.contains("--spans") {
    let pairs = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [[Double]] ?? []
    let spans = pairs.filter { $0.count == 2 && $0[1] > $0[0] }.map { $0[0]..<$0[1] }
    output = ["embeddings": spans.isEmpty ? [] : try await manager.embedSpans(audioSource: source, spans: spans)]
} else {
    let segments = try await manager.process(audioSource: source, audioLoadingSeconds: 0).segments
    let spans = segments.map { Double($0.startTimeSeconds)..<Double($0.endTimeSeconds) }
    let vectors = spans.isEmpty ? [] : try await manager.embedSpans(audioSource: source, spans: spans)
    output = ["turns": zip(segments, vectors).map { seg, vec in
        ["start": Double(seg.startTimeSeconds), "end": Double(seg.endTimeSeconds), "speaker": seg.speakerId, "embedding": vec]
    }]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
