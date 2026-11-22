import AudioToolbox
import Foundation

enum RecorderError: Error { case noInput(OSStatus) }

/// Records 16 kHz mono Int16 PCM, which is what Whisper wants, from the default input or a
/// chosen device. Uses an AudioQueue, which does the resampling itself and can record from
/// any device: AVAudioEngine runs input and output through one unit, and after switching
/// its input to another device than the output it delivers no audio at all.
final class Recorder {
    private final class Sink {
        var pcm = Data()
        let lock = NSLock()
    }
    private let sink = Sink()
    private var queue: AudioQueueRef?

    private(set) var isRecording = false
    /// The device the current or last recording used, for the log and the silence notice.
    private(set) var inputName = "the default input"

    /// `deviceUID`: the microphone chosen in the menu; nil, or not connected, uses the system default.
    func start(deviceUID: String? = nil) throws {
        sink.lock.lock(); sink.pcm = Data(); sink.lock.unlock()
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var q: AudioQueueRef?
        let status = AudioQueueNewInput(&format, { user, q, buffer, _, _, _ in
            let sink = Unmanaged<Sink>.fromOpaque(user!).takeUnretainedValue()
            let b = buffer.pointee
            sink.lock.lock()
            sink.pcm.append(b.mAudioData.assumingMemoryBound(to: UInt8.self), count: Int(b.mAudioDataByteSize))
            sink.lock.unlock()
            AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        }, Unmanaged.passUnretained(sink).toOpaque(), nil, nil, 0, &q)
        guard status == noErr, let q else { throw RecorderError.noInput(status) }

        var device = AudioDevices.defaultInput.flatMap(AudioDevices.name(of:)) ?? "the default input"
        if let deviceUID {
            if let chosen = AudioDevices.inputs().first(where: { $0.uid == deviceUID }) {
                var uid = Unmanaged.passUnretained(chosen.uid as CFString)
                let st = AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
                if st == noErr { device = chosen.name } else { Log.write("could not select \(chosen.name): \(st), using the system default") }
            } else {
                Log.write("chosen microphone \(deviceUID) is not connected, using the system default")
            }
        }
        inputName = device

        // 100 ms buffers, three in flight.
        for _ in 0..<3 {
            var buf: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, 3_200, &buf) == noErr, let buf { AudioQueueEnqueueBuffer(q, buf, 0, nil) }
        }
        let started = AudioQueueStart(q, nil)
        guard started == noErr else { AudioQueueDispose(q, true); throw RecorderError.noInput(started) }
        queue = q
        isRecording = true
        Log.write("recording from \(inputName): 16 kHz mono")
    }

    /// The audio so far as a WAV, while recording continues (for live typing), and its peak in dBFS.
    /// The silence at its end is trimmed, as in `stop()`: Whisper fills a pause at the end of
    /// a clip by repeating the last phrase. `seconds` is the trimmed length, so an unchanged
    /// value means nothing new was said since the last snapshot.
    /// `from`: start that many seconds in (live typing sends only the audio after the
    /// sentences it already locked). Works during a recording and after `stop()`.
    func snapshot(from start: Double = 0, keep: Double = 0.3) -> (wav: Data, seconds: Double, peakDB: Double) {
        sink.lock.lock(); let all = sink.pcm; sink.lock.unlock()
        let skip = min(all.count, Int(start * 16_000) * 2)
        let samples = all.subdata(in: skip..<all.count)
        let trimmed = Recorder.trimTrailingSilence(samples, keep: keep)
        return (Recorder.wav(pcm16: trimmed), Double(trimmed.count) / 32_000, Recorder.peakDB(samples))
    }

    /// Stops and returns a complete WAV file, its duration in seconds, and its loudest
    /// 20 ms stretch in dBFS (about -90 or lower means the microphone delivered silence).
    func stop() -> (wav: Data, seconds: Double, peakDB: Double) {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
        }
        queue = nil
        isRecording = false
        sink.lock.lock(); let samples = sink.pcm; sink.lock.unlock()
        let trimmed = Recorder.trimTrailingSilence(samples)
        let seconds = Double(trimmed.count) / 2.0 / 16_000.0
        if trimmed.count < samples.count {
            Log.write(String(format: "trimmed %.1fs of trailing silence", Double(samples.count - trimmed.count) / 32_000.0))
        }
        return (Recorder.wav(pcm16: trimmed), seconds, Recorder.peakDB(samples))
    }

    static func peakDB(_ pcm: Data) -> Double {
        let window = 320, count = pcm.count / 2
        var peak = 0.0
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var i = 0
            while i + window <= count {
                var sum = 0.0
                for j in i..<(i + window) { let v = Double(Int16(littleEndian: s[j])); sum += v * v }
                peak = max(peak, (sum / Double(window)).squareRoot())
                i += window
            }
        }
        return peak > 0 ? 20 * log10(peak / 32_768) : -120
    }

    /// Drops the quiet tail of a recording (the pause before you press stop), keeping
    /// `keep` seconds after the last sound. Whisper fills long silence at the end with
    /// lines from its subtitle training data ("Closed Captioning by …", "Thanks for
    /// watching"); without the silence it has nothing to fill. The threshold follows the
    /// room: three times the quietest stretch's level, at least about -46 dBFS.
    static func trimTrailingSilence(_ pcm: Data, keep: Double = 0.5) -> Data {
        let window = 320   // 20 ms at 16 kHz
        let count = pcm.count / 2
        guard count > window * 10 else { return pcm }
        var rms: [Double] = []
        rms.reserveCapacity(count / window)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            var i = 0
            while i + window <= count {
                var sum = 0.0
                for j in i..<(i + window) { let v = Double(Int16(littleEndian: s[j])); sum += v * v }
                rms.append((sum / Double(window)).squareRoot())
                i += window
            }
        }
        let floor = rms.sorted()[rms.count / 10]
        let threshold = max(floor * 3, 160)
        guard let last = rms.lastIndex(where: { $0 > threshold }) else { return pcm }
        let end = min(count, (last + 1) * window + Int(keep * 16_000))
        return pcm.prefix(end * 2)
    }

    static func wav(pcm16: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm16.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate)
        u16(channels * bits / 8); u16(bits)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}
