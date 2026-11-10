import AVFoundation
import CoreAudio

// Microphone + the Mac's own sound (Teams, Zoom, browser …) as one synchronized stereo stream: a Core Audio process
// tap (macOS 14.2+) on all audio except ours, joined with the mic in a private aggregate device (drift compensated).
// The IO block writes float32 frames [mic, system] into a FIFO that the meeting script's ffmpeg reads.
// Without the "System Audio Recording" permission the tap delivers silence; the speaker step then treats the
// recording as mono, so nothing breaks.
final class SystemAudio {
    let sampleRate: Double
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var fd: Int32 = -1
    private let micChannels: Int

    /// micUID nil = system default input
    init(micUID: String?) throws {
        guard let mic = micUID ?? Self.defaultInputUID(), let micID = Self.device(uid: mic) else {
            throw Failure("Kein Mikrofon gefunden")
        }
        micChannels = max(1, Self.inputChannels(micID))

        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Mac-Ton-Tap")

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetingNotes",
            kAudioAggregateDeviceUIDKey: "MeetingNotes-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: mic,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: mic]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate), "Aggregat-Gerät")
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        var rate = Float64(48000)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, &rate)
        sampleRate = rate
    }

    /// Opens the FIFO (blocks until ffmpeg opens it for reading, so call off the main thread) and starts capture.
    func start(fifo: String) throws {
        fd = open(fifo, O_WRONLY)
        guard fd >= 0 else { throw Failure("FIFO lässt sich nicht öffnen") }
        let micCh = micChannels
        let out = fd
        let opened = Date()
        var waiting = true   // only touched on the serial tap queue
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, DispatchQueue(label: "MeetingNotes.tap")) {
            _, input, _, _, _ in
            if waiting {   // audio has started minutes late before (ROADMAP); the log shows when it really begins
                waiting = false
                let s = String(format: "%.1f", Date().timeIntervalSince(opened))
                Task { @MainActor in Recorder.log("Mikrofon + Mac-Ton: erstes Audio \(s) s nach dem Start") }
            }
            let frames = Self.interleave(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                                         micChannels: micCh)
            frames.withUnsafeBytes { raw in
                var p = raw.baseAddress!, left = raw.count
                while left > 0 {   // a full pipe takes partial writes; a closed one (EPIPE) just ends the loop
                    let n = write(out, p, left)
                    if n <= 0 { break }
                    p += n; left -= n
                }
            }
        }, "IO-Prozess")
        try check(AudioDeviceStart(aggregate, proc), "Aufnahme-Start")
    }

    func stop() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        aggregate = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
        if fd >= 0 { close(fd) }   // EOF: ffmpeg finishes the file
        fd = -1
    }

    /// Input buffers of the aggregate: the mic's stream(s) first, then the tap's. Each buffer is interleaved with
    /// mNumberChannels channels. Returns [mic, system] float pairs; extra channels on either side are averaged.
    static func interleave(_ abl: UnsafeMutableAudioBufferListPointer, micChannels: Int) -> [Float] {
        var chans: [(UnsafePointer<Float>, stride: Int)] = []
        var frames = Int.max
        for buf in abl {
            guard let data = buf.mData, buf.mNumberChannels > 0 else { continue }
            let n = Int(buf.mNumberChannels)
            let p = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            frames = min(frames, Int(buf.mDataByteSize) / (4 * n))
            for c in 0..<n { chans.append((p + c, n)) }
        }
        guard !chans.isEmpty, frames != Int.max else { return [] }
        let micN = min(micChannels, chans.count)
        let mic = chans[..<micN], sys = chans[micN...]
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            var m: Float = 0, s: Float = 0
            for (p, st) in mic { m += p[f * st] }
            for (p, st) in sys { s += p[f * st] }
            out[2 * f] = m / Float(max(mic.count, 1))
            out[2 * f + 1] = sys.isEmpty ? 0 : s / Float(sys.count)
        }
        return out
    }

    // MARK: Core Audio lookups

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }


    static func defaultInputUID() -> String? {
        var id = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) else { return nil }
        return uid(of: id)
    }

    static func uid(of id: AudioObjectID) -> String? {
        var uid: Unmanaged<CFString>?
        guard get(id, kAudioDevicePropertyDeviceUID, &uid), let s = uid?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func device(uid: String) -> AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var cf = uid as CFString
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func inputChannels(_ id: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 1 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 1 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func ownProcess() -> AudioObjectID? {
        var pid = getpid()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Bundle IDs of processes that are recording from any input right now (for meeting detection).
    static func processesUsingInput() -> [String] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var running: UInt32 = 0
            guard get(id, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { return nil }
            var bundle: Unmanaged<CFString>?
            guard get(id, kAudioProcessPropertyBundleID, &bundle), let b = bundle?.takeRetainedValue() else { return nil }
            return b as String
        }
    }

    @discardableResult
    private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var size = UInt32(MemoryLayout<T>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw SystemAudio.Failure("\(what) fehlgeschlagen (\(status))") }
}
