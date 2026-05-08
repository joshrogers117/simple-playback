import Foundation

/// Streaming LTC (Linear Timecode) audio decoder.
///
/// LTC is biphase-mark (Manchester) encoded. Each TC frame is 80 bits
/// long; at 30 fps that is 2400 bits/sec, so a "1" interval is shorter
/// than a "0" interval by half. We detect zero-crossings, measure the
/// interval to the next crossing in samples, and classify each interval
/// as the short ("1") or long ("0") half-bit.
///
/// We then look for the SMPTE sync word (`0011_1111_1111_1101`, 16 bits at
/// the end of the 80-bit frame) and decode the preceding 64 bits as the
/// SMPTE LTC payload.
///
/// Frame rate inference: from the duration of the frame in seconds.
final class LTCDecoder {
    /// Audio sample rate the host is feeding us.
    let sampleRate: Double
    /// Optional fixed frame rate; pass `nil` to auto-infer.
    var assumedFrameRate: TimecodeFrameRate?

    /// Called every time a complete TC frame is decoded.
    var onFrame: ((TimecodeValue) -> Void)?

    private var lastSample: Float = 0
    private var sampleIndex: Int = 0
    private var lastEdgeIndex: Int = 0
    /// Buffer of recent half-bit booleans. We keep up to 160 (one frame's
    /// worth of half-bits) — the sync word lives at the end of every frame.
    private var halfBits: [Bool] = []
    /// `true` while we have a current "1" detected (consume the second half).
    private var pendingOneSecondHalf: Bool = false
    /// Heuristic average half-bit width in samples; updated on every edge so
    /// we adapt to small clock drift.
    private var halfBitSamples: Double = 0

    private let syncWord: [Bool] = bitsFromHex(0x3FFD, bits: 16)

    init(sampleRate: Double = 48000) {
        self.sampleRate = sampleRate
    }

    /// Feeds a buffer of mono PCM samples (range nominal -1...1).
    func process(samples: [Float]) {
        for s in samples {
            processSample(s)
        }
    }

    private func processSample(_ s: Float) {
        defer {
            sampleIndex += 1
            lastSample = s
        }
        let isZeroCrossing = (lastSample >= 0 && s < 0) || (lastSample < 0 && s >= 0)
        guard isZeroCrossing else { return }

        let interval = Double(sampleIndex - lastEdgeIndex)
        lastEdgeIndex = sampleIndex

        // First crossing: just record.
        if halfBitSamples == 0 {
            halfBitSamples = interval
            return
        }

        let ratio = interval / halfBitSamples
        // Long interval (~2x of half-bit) → "0" bit.
        // Short interval (~1x of half-bit) → first or second half of a "1" bit.
        // We use 1.5 as the cutoff.
        if ratio > 1.5 {
            // Long — definitely a "0" bit.
            halfBits.append(false)
            halfBits.append(false)
            // Adapt: this interval was actually two half-bits of width.
            halfBitSamples = (halfBitSamples * 0.95) + (interval / 2.0) * 0.05
            pendingOneSecondHalf = false
        } else {
            // Short — half of a "1" bit. Pair them up.
            if pendingOneSecondHalf {
                halfBits.append(true)
                halfBits.append(true)
                pendingOneSecondHalf = false
                halfBitSamples = (halfBitSamples * 0.95) + interval * 0.05
            } else {
                pendingOneSecondHalf = true
            }
        }

        attemptDecode()
        if halfBits.count > 320 {
            halfBits.removeFirst(halfBits.count - 320)
        }
    }

    /// LTC is sent half-bit-by-half-bit; pairs of half-bits represent one bit.
    /// Compress the buffer to bits, then look for the sync word at the end.
    private func attemptDecode() {
        // We accumulate half-bit pairs as bits.
        let pairs = halfBits.count / 2
        guard pairs >= 80 else { return }
        // Compress last 80 pairs to bits.
        let lastPairs = Array(halfBits.suffix(160))
        var bits: [Bool] = []
        bits.reserveCapacity(80)
        var i = 0
        while i + 1 < lastPairs.count {
            // Both halves should agree.
            let a = lastPairs[i]
            let b = lastPairs[i + 1]
            // For a "0" bit, both halves are the same. For a "1" bit they're
            // also recorded as both true here (we collapse them at insert
            // time). So the bit value is `a` (= b).
            _ = b
            bits.append(a)
            i += 2
        }
        // Sync word lives in bits[64..<80] (16 bits).
        guard bits.count == 80 else { return }
        let sync = Array(bits[64..<80])
        guard sync == syncWord else { return }
        // Decode the 64 LTC payload bits.
        if let value = decodeLTCPayload(bits: Array(bits[0..<64])) {
            onFrame?(value)
        }
        // Drop the consumed half-bits.
        halfBits.removeAll()
        pendingOneSecondHalf = false
    }

    /// SMPTE LTC payload bit layout (per IEC 60461). Each field is a
    /// 4-bit "units" + 4-bit "tens"+flags split. We extract:
    /// - frames (units bits 0-3, tens bits 8-9)
    /// - seconds (units 16-19, tens 24-26)
    /// - minutes (units 32-35, tens 40-42)
    /// - hours (units 48-51, tens 56-57)
    /// - drop-frame flag at bit 10
    private func decodeLTCPayload(bits: [Bool]) -> TimecodeValue? {
        guard bits.count == 64 else { return nil }
        let frameUnits = packBCD(bits, range: 0..<4)
        let frameTens = packBCD(bits, range: 8..<10)
        let secondUnits = packBCD(bits, range: 16..<20)
        let secondTens = packBCD(bits, range: 24..<27)
        let minuteUnits = packBCD(bits, range: 32..<36)
        let minuteTens = packBCD(bits, range: 40..<43)
        let hourUnits = packBCD(bits, range: 48..<52)
        let hourTens = packBCD(bits, range: 56..<58)
        let dropFrame = bits[10]
        let frames = frameTens * 10 + frameUnits
        let seconds = secondTens * 10 + secondUnits
        let minutes = minuteTens * 10 + minuteUnits
        let hours = hourTens * 10 + hourUnits
        // Sanity check.
        guard hours < 24, minutes < 60, seconds < 60 else { return nil }

        let inferredRate = assumedFrameRate ?? inferFrameRate(framesField: frames, dropFrame: dropFrame)
        guard frames < inferredRate.integerFPS else { return nil }
        return TimecodeValue(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            frameRate: inferredRate
        )
    }

    private func inferFrameRate(framesField: Int, dropFrame: Bool) -> TimecodeFrameRate {
        // Heuristic: drop-frame flag → 29.97 DF; non-DF default 30. The
        // operator can override via `assumedFrameRate`.
        return dropFrame ? .fps29_97_df : .fps30
    }

    private func packBCD(_ bits: [Bool], range: Range<Int>) -> Int {
        var v = 0
        for i in range.reversed() {
            v = (v << 1) | (bits[i] ? 1 : 0)
        }
        return v
    }
}

private func bitsFromHex(_ value: UInt16, bits: Int) -> [Bool] {
    var out: [Bool] = []
    for i in stride(from: bits - 1, through: 0, by: -1) {
        out.append((value >> i) & 1 != 0)
    }
    return out
}

/// Generates LTC audio samples. Used by the internal generator (D14) and by
/// LTC decoder tests so we can verify decode against synthesized input.
struct LTCGenerator {
    let sampleRate: Double
    let frameRate: TimecodeFrameRate

    /// Synthesizes one frame of LTC audio (a square wave biphase-mark stream
    /// of 80 bits) starting at `value`. Returns the audio samples.
    func samples(for value: TimecodeValue) -> [Float] {
        let bits = LTCGenerator.encodePayload(value)
        let syncBits: [Bool] = [false, false, true, true, true, true, true, true,
                                true, true, true, true, true, true, false, true]
        let allBits = bits + syncBits
        let totalSamples = Int(sampleRate / frameRate.nominalFPS)
        let samplesPerHalfBit = Double(totalSamples) / Double(allBits.count * 2)
        var out: [Float] = []
        out.reserveCapacity(totalSamples)
        var level: Float = 1
        for bit in allBits {
            let halfWidth = Int(samplesPerHalfBit.rounded())
            // First half: always toggle.
            level = -level
            for _ in 0..<halfWidth { out.append(level) }
            if bit {
                // Mid-bit toggle for "1".
                level = -level
            }
            for _ in 0..<halfWidth { out.append(level) }
        }
        // Trim or pad to exact frame size.
        if out.count > totalSamples {
            out = Array(out.prefix(totalSamples))
        } else {
            while out.count < totalSamples { out.append(level) }
        }
        return out
    }

    /// Encodes a TimecodeValue into the 64 LTC payload bits per IEC 60461.
    static func encodePayload(_ v: TimecodeValue) -> [Bool] {
        var bits = [Bool](repeating: false, count: 64)
        let frameUnits = v.frames % 10
        let frameTens = v.frames / 10
        let secondUnits = v.seconds % 10
        let secondTens = v.seconds / 10
        let minuteUnits = v.minutes % 10
        let minuteTens = v.minutes / 10
        let hourUnits = v.hours % 10
        let hourTens = v.hours / 10
        writeBCD(&bits, value: frameUnits, range: 0..<4)
        writeBCD(&bits, value: frameTens, range: 8..<10)
        bits[10] = v.frameRate.isDropFrame
        writeBCD(&bits, value: secondUnits, range: 16..<20)
        writeBCD(&bits, value: secondTens, range: 24..<27)
        writeBCD(&bits, value: minuteUnits, range: 32..<36)
        writeBCD(&bits, value: minuteTens, range: 40..<43)
        writeBCD(&bits, value: hourUnits, range: 48..<52)
        writeBCD(&bits, value: hourTens, range: 56..<58)
        return bits
    }

    private static func writeBCD(_ bits: inout [Bool], value: Int, range: Range<Int>) {
        var v = value
        for i in range {
            bits[i] = (v & 1) != 0
            v >>= 1
        }
    }
}
