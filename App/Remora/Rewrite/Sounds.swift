import AppKit

/// The rewrite key's and dictation's subtle sounds (Settings › Shortcuts › Play sounds).
///
/// Remora's own soft cues, synthesized once at first use (no bundled files, no system alert
/// sounds): a rising two-note blip on start, the same notes falling on stop/done, and a muted
/// low double tap on errors. System sounds such as Tink and Basso read as alerts.
@MainActor
enum Sounds {
    enum Cue: CaseIterable {
        case start, done, error, listenStart, listenStop

        /// Notes as (frequency Hz, duration s), played back to back.
        var notes: [(Double, Double)] {
            switch self {
            case .start, .listenStart: [(659.25, 0.055), (987.77, 0.090)]   // E5 → B5
            case .done, .listenStop: [(987.77, 0.055), (659.25, 0.090)]     // B5 → E5
            case .error: [(233.08, 0.070), (0, 0.040), (233.08, 0.090)]     // muted B♭3 double tap
            }
        }

        var volume: Double { self == .error ? 0.22 : 0.16 }
    }

    static func play(_ cue: Cue, enabled: Bool) {
        guard enabled else { return }
        let sound = cache[cue] ?? ToneSynth.sound(notes: cue.notes, volume: cue.volume)
        cache[cue] = sound
        sound?.stop()
        sound?.play()
    }

    /// Dictation starts listening.
    static func dictationStart(enabled: Bool) { play(.listenStart, enabled: enabled) }

    /// Dictation stops listening (not on cancel, which is silent).
    static func dictationStop(enabled: Bool) { play(.listenStop, enabled: enabled) }

    private static var cache: [Cue: NSSound] = [:]
}

/// Builds short, soft sine cues as in-memory 16-bit mono WAV data.
enum ToneSynth {
    static let sampleRate = 44_100.0

    static func sound(notes: [(Double, Double)], volume: Double) -> NSSound? {
        NSSound(data: wav(samples: samples(notes: notes, volume: volume)))
    }

    /// Each note: 4 ms attack, exponential decay, a quiet octave overtone for warmth; a frequency
    /// of 0 is a rest.
    static func samples(notes: [(Double, Double)], volume: Double) -> [Int16] {
        var out: [Int16] = []
        for (freq, duration) in notes {
            let count = Int(duration * sampleRate)
            for i in 0..<count {
                guard freq > 0 else { out.append(0); continue }
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.004)
                let decay = exp(-t / (duration * 0.35))
                let tail = min(1, Double(count - i) / (0.003 * sampleRate))   // click-free end
                let wave = sin(2 * .pi * freq * t) + 0.18 * sin(4 * .pi * freq * t)
                let v = wave / 1.18 * attack * decay * tail * volume
                out.append(Int16(max(-1, min(1, v)) * Double(Int16.max)))
            }
        }
        return out
    }

    static func wav(samples: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
