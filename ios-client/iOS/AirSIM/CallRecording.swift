import AVFoundation
import Foundation

enum CallRecordingStore {
    static func directory() throws -> URL {
        var directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("CallRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        return directory
    }
}

/// One feed belongs to one media transport. Detaching fences any later packets.
final class CallRecordingFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var recording: CallPCMRecording?

    func attach(_ recording: CallPCMRecording?) {
        lock.lock()
        self.recording = recording
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let ongoing = recording
        recording = nil
        lock.unlock()
        ongoing?.finish()
    }

    func append(_ pcm: Data, rate: Int, channel: CallPCMRecording.Channel) {
        lock.lock()
        defer { lock.unlock() }
        recording?.append(pcm, rate: rate, channel: channel)
    }
}

/// Writes the local and remote sides as separate channels on one 16 kHz clock.
final class CallPCMRecording: @unchecked Sendable {
    enum Channel: Int, Sendable { case local, remote }

    private static let rate = 16_000
    private static let flushFrames = 3_200
    private static let holdFrames = 8_000
    private let queue = DispatchQueue(label: "AirSIM.call-recording", qos: .utility)
    private let pendingPackets = DispatchSemaphore(value: 128)
    private let started = ProcessInfo.processInfo.systemUptime
    private let staging: URL
    private let destination: URL
    private let onFinish: @Sendable (Result<URL?, Error>) -> Void
    private var file: AVAudioFile?
    private var tracks = [[Int16](), [Int16]()]
    private var ends = [0, 0]
    private var written = 0

    init(directory: URL? = nil, onFinish: @escaping @Sendable (Result<URL?, Error>) -> Void) throws {
        let directory = try directory ?? CallRecordingStore.directory()
        let temporary = directory.appendingPathComponent(".in-progress", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".wav"
        staging = temporary.appendingPathComponent(name)
        destination = directory.appendingPathComponent(name)
        self.onFinish = onFinish
        do {
            file = try AVAudioFile(forWriting: staging, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.rate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ], commonFormat: .pcmFormatInt16, interleaved: false)
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: staging.path)
        } catch {
            file = nil
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func append(_ pcm: Data, rate: Int, channel: Channel) {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), rate == 8_000 || rate == Self.rate,
              pendingPackets.wait(timeout: .now()) == .success else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        queue.async { [self] in
            defer { pendingPackets.signal() }
            guard file != nil else { return }
            do {
                if elapsed >= 4 * 60 * 60 {
                    finishLocked()
                    return
                }
                try ingest(pcm, rate: rate, side: channel.rawValue, elapsed: elapsed)
            } catch {
                discard(error)
            }
        }
    }

    func finish() {
        queue.async { [self] in finishLocked() }
    }

    private func ingest(_ pcm: Data, rate: Int, side: Int, elapsed: TimeInterval) throws {
        let repeatCount = Self.rate / rate
        let frames = pcm.count / 2 * repeatCount
        let estimatedStart = max(0, Int(elapsed * Double(Self.rate)) - frames)
        // Keep contiguous PCM contiguous across uneven network and engine callbacks.
        let start = max(written, estimatedStart - ends[side] <= Self.rate / 10 ? ends[side] : estimatedStart)
        while start - written > Self.holdFrames + Self.flushFrames {
            try flush(Self.flushFrames)
        }
        let offset = start - written
        let missing = offset + frames - tracks[side].count
        if missing > 0 { tracks[side].append(contentsOf: repeatElement(0, count: missing)) }
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for sample in 0..<(pcm.count / 2) {
                let value = Int16(bitPattern: UInt16(bytes[sample * 2]) | UInt16(bytes[sample * 2 + 1]) << 8)
                for duplicate in 0..<repeatCount {
                    tracks[side][offset + sample * repeatCount + duplicate] = value
                }
            }
        }
        ends[side] = start + frames
        while max(ends[0], ends[1]) - written >= Self.holdFrames + Self.flushFrames {
            try flush(Self.flushFrames)
        }
    }

    private func flush(_ frames: Int) throws {
        guard let file, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(frames)), let channels = buffer.int16ChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for side in 0..<2 {
            let available = min(frames, tracks[side].count)
            for index in 0..<frames {
                channels[side][index] = index < available ? tracks[side][index] : 0
            }
            tracks[side].removeFirst(available)
        }
        try file.write(from: buffer)
        written += frames
    }

    private func finishLocked() {
        guard file != nil else { return }
        do {
            while written < max(ends[0], ends[1]) {
                try flush(min(Self.flushFrames, max(ends[0], ends[1]) - written))
            }
            // Release AVAudioFile to finalize the WAV container before publishing it.
            file = nil
            if written > 0 {
                try FileManager.default.moveItem(at: staging, to: destination)
                onFinish(.success(destination))
            } else {
                try FileManager.default.removeItem(at: staging)
                onFinish(.success(nil))
            }
        } catch {
            discard(error)
        }
    }

    private func discard(_ error: Error) {
        file = nil
        try? FileManager.default.removeItem(at: staging)
        onFinish(.failure(error))
    }
}
