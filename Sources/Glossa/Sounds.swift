import AppKit

/// Glossa's sounds, synthesized: short marimba-like notes instead of the system alerts,
/// designed as one family so they can be told apart without looking.
///  - Direction: notes rise when recording starts, fall when it stops.
///  - Timbre: dictation is a soft, round tone; voice commands are brighter (odd harmonics).
///  - Outcome: success is a high bright chord, trouble a low falling interval, a question
///    a rising one, a warning two equal notes.
enum Earcon: String, CaseIterable {
    case startToggle      // press once: two notes up
    case startHold        // press and hold: one short note (you are holding, it just confirms)
    case startCommand     // Shift: three notes up, bright
    case stop             // recording ended, transcribing: two notes down
    case inserted         // text pasted: high soft chord
    case commandPasted    // command pasted: high chord, bright
    case warning          // risky command pasted: two equal notes, middle
    case ask              // the model asked a question: rising interval
    case ignored          // too short to send: one quiet low tick
    case failed           // error: low falling minor third

    var label: String {
        switch self {
        case .startToggle: "start, press once"
        case .startHold: "start, press and hold"
        case .startCommand: "start, voice command"
        case .stop: "stop, transcribing"
        case .inserted: "text inserted"
        case .commandPasted: "command pasted"
        case .warning: "command pasted, check it"
        case .ask: "the model asks a question"
        case .ignored: "too short, ignored"
        case .failed: "something failed"
        }
    }

    fileprivate enum Timbre { case soft, bright }
    /// (start in seconds, frequency in Hz, length in seconds)
    fileprivate typealias Note = (at: Double, hz: Double, len: Double)

    fileprivate var score: (timbre: Timbre, gain: Double, notes: [Note]) {
        let C5 = 523.25, D5 = 587.33, E5 = 659.25, G5 = 783.99, A5 = 880.0, C6 = 1046.5, E6 = 1318.5, G6 = 1568.0
        let C4 = 261.63, Eb4 = 311.13, G4 = 392.0
        switch self {
        case .startToggle:   return (.soft, 1.0, [(0, C5, 0.14), (0.085, G5, 0.22)])
        case .startHold:     return (.soft, 0.9, [(0, G5, 0.16)])
        case .startCommand:  return (.bright, 0.8, [(0, C5, 0.11), (0.07, E5, 0.11), (0.14, G5, 0.24)])
        case .stop:          return (.soft, 0.85, [(0, G5, 0.12), (0.08, C5, 0.22)])
        case .inserted:      return (.soft, 0.75, [(0, C6, 0.32), (0.025, E6, 0.32), (0.05, G6, 0.30)])
        case .commandPasted: return (.bright, 0.6, [(0, C6, 0.28), (0.025, E6, 0.28), (0.05, G6, 0.26)])
        case .warning:       return (.bright, 0.8, [(0, A5, 0.13), (0.16, A5, 0.20)])
        case .ask:           return (.soft, 0.9, [(0, D5, 0.14), (0.11, A5, 0.26)])
        case .ignored:       return (.soft, 0.45, [(0, G4, 0.08)])
        case .failed:        return (.soft, 1.0, [(0, Eb4, 0.18), (0.13, C4, 0.34)])
        }
    }

    /// 44.1 kHz mono 16-bit WAV.
    var wav: Data {
        let rate = 44_100.0
        let s = score
        let total = (s.notes.map { $0.at + $0.len }.max() ?? 0) + 0.05
        var buf = [Double](repeating: 0, count: Int(total * rate))
        // Harmonic weights: soft is nearly a sine with a touch of octave (marimba-ish);
        // bright adds odd harmonics, a softened square.
        let partials: [(Double, Double)] = s.timbre == .soft
            ? [(1, 1.0), (2, 0.18), (4, 0.04)]
            : [(1, 1.0), (3, 0.30), (5, 0.12), (7, 0.05)]
        for n in s.notes {
            let start = Int(n.at * rate), count = Int(n.len * rate)
            let attack = 0.004 * rate
            for i in 0..<count where start + i < buf.count {
                let t = Double(i) / rate
                let env = min(1, Double(i) / attack) * exp(-t / (n.len * 0.28))
                var v = 0.0
                for (k, w) in partials where n.hz * k < 16_000 {
                    // Higher partials die faster, as on a struck bar.
                    v += w * exp(-t * (k - 1) * 6) * sin(2 * .pi * n.hz * k * t)
                }
                buf[start + i] += v * env
            }
        }
        let peak = max(buf.map(abs).max() ?? 1, 1)
        let scale = 0.32 * s.gain / peak * 32_767
        var pcm = Data(capacity: buf.count * 2)
        for x in buf { var v = Int16(max(-32_767, min(32_767, x * scale))).littleEndian; pcm.append(Data(bytes: &v, count: 2)) }
        return Self.header(dataBytes: pcm.count, rate: UInt32(rate)) + pcm
    }

    private static func header(dataBytes: Int, rate: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
        return d
    }
}

/// Plays earcons; each is synthesized once.
final class SoundPlayer {
    private var cache: [Earcon: NSSound] = [:]
    var volume: Float = 1.0

    func play(_ e: Earcon) {
        let sound = cache[e] ?? NSSound(data: e.wav)
        guard let sound else { return }
        cache[e] = sound
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
