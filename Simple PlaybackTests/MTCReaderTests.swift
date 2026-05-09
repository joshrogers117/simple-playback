import Foundation
import XCTest
import CoreMIDI
@testable import Simple_Playback

/// Reader-level coverage for `MTCReader.handleQuarterFrame` — the 8-piece
/// quarter-frame assembly that turns 0xF1-prefixed MIDI System Common
/// messages into a `TimecodeValue`. Driven via the
/// `ingestQuarterFrameForTesting` seam so no real CoreMIDI source is
/// required (the rest of the reader, the CoreMIDI client / port / source
/// connection, is hardware-bound and validated only at rehearsal — see
/// `docs/manual_verification.md`).
///
/// MTC quarter-frame layout (MIDI 1.0 spec, also see `MTCReader.swift`
/// header comment): each 0xF1 message carries one byte where the high
/// nibble (bits 4..6) is the field index 0..7 and the low nibble (bits
/// 0..3) is 4 data bits. Eight messages assemble one HH:MM:SS:FF value:
///
///   field 0: frames LSB
///   field 1: frames MSB
///   field 2: seconds LSB
///   field 3: seconds MSB
///   field 4: minutes LSB
///   field 5: minutes MSB
///   field 6: hours LSB
///   field 7: hours MSB (low bit) + frame-rate bits (bits 1..2)
///         00 = 24, 01 = 25, 10 = 29.97-NDF, 11 = 30 fps
final class MTCReaderTests: XCTestCase {

    private func quarterFrameByte(field: UInt8, nibble: UInt8) -> UInt8 {
        ((field & 0x07) << 4) | (nibble & 0x0F)
    }

    /// Build the 8 quarter-frame bytes that spell out a given
    /// HH:MM:SS:FF + rate. Returns them in field-index order; the test
    /// drives them in that order to mirror the on-the-wire sequence.
    private func quarterFrameSequence(
        hours: Int, minutes: Int, seconds: Int, frames: Int, rateBits: UInt8
    ) -> [UInt8] {
        let f = UInt8(frames & 0xFF)
        let s = UInt8(seconds & 0xFF)
        let m = UInt8(minutes & 0xFF)
        let h = UInt8(hours & 0xFF)
        // Hours field-7 nibble: bit 0 = hours bit 4 (overflow into 5-bit hours);
        // bits 1..2 = rate bits; bit 3 = unused (zero).
        let hourBit4 = (h >> 4) & 0x01
        let field7Nibble = hourBit4 | ((rateBits & 0x03) << 1)
        return [
            quarterFrameByte(field: 0, nibble: f & 0x0F),
            quarterFrameByte(field: 1, nibble: (f >> 4) & 0x0F),
            quarterFrameByte(field: 2, nibble: s & 0x0F),
            quarterFrameByte(field: 3, nibble: (s >> 4) & 0x0F),
            quarterFrameByte(field: 4, nibble: m & 0x0F),
            quarterFrameByte(field: 5, nibble: (m >> 4) & 0x0F),
            quarterFrameByte(field: 6, nibble: h & 0x0F),
            quarterFrameByte(field: 7, nibble: field7Nibble),
        ]
    }

    // MARK: - Happy path: full 8-frame assembly per rate

    func testAssemblesFullTimecodeAt30FPS() {
        let reader = MTCReader()
        var captured: TimecodeValue?
        reader.onFrame = { tc, _ in captured = tc }

        for byte in quarterFrameSequence(hours: 1, minutes: 23, seconds: 45, frames: 12, rateBits: 0b11) {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }

        XCTAssertEqual(captured?.hours, 1)
        XCTAssertEqual(captured?.minutes, 23)
        XCTAssertEqual(captured?.seconds, 45)
        XCTAssertEqual(captured?.frames, 12)
        XCTAssertEqual(captured?.frameRate, .fps30)
    }

    func testAssemblesAt24FPS() {
        let reader = MTCReader()
        var captured: TimecodeValue?
        reader.onFrame = { tc, _ in captured = tc }
        for byte in quarterFrameSequence(hours: 0, minutes: 0, seconds: 1, frames: 23, rateBits: 0b00) {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }
        XCTAssertEqual(captured?.frameRate, .fps24)
        XCTAssertEqual(captured?.frames, 23)
    }

    func testAssemblesAt25FPS() {
        let reader = MTCReader()
        var captured: TimecodeValue?
        reader.onFrame = { tc, _ in captured = tc }
        for byte in quarterFrameSequence(hours: 10, minutes: 30, seconds: 0, frames: 24, rateBits: 0b01) {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }
        XCTAssertEqual(captured?.frameRate, .fps25)
        XCTAssertEqual(captured?.frames, 24)
        XCTAssertEqual(captured?.hours, 10)
    }

    func testAssemblesAt2997NDF() {
        let reader = MTCReader()
        var captured: TimecodeValue?
        reader.onFrame = { tc, _ in captured = tc }
        for byte in quarterFrameSequence(hours: 23, minutes: 59, seconds: 59, frames: 28, rateBits: 0b10) {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }
        XCTAssertEqual(captured?.frameRate, .fps29_97_ndf)
        XCTAssertEqual(captured?.frames, 28)
        XCTAssertEqual(captured?.hours, 23)
    }

    // MARK: - Partial assembly suppresses emission

    func testIncompleteSequenceDoesNotEmit() {
        let reader = MTCReader()
        var fireCount = 0
        reader.onFrame = { _, _ in fireCount += 1 }

        // Send only fields 0..6 (skip the closing field 7).
        let bytes = quarterFrameSequence(hours: 1, minutes: 2, seconds: 3, frames: 4, rateBits: 0b11)
        for byte in bytes.prefix(7) {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }
        XCTAssertEqual(fireCount, 0,
                       "An incomplete 8-quarter-frame sequence must not emit a TimecodeValue.")
    }

    // MARK: - Sanity check rejection

    func testOutOfRangeHoursDropFrame() {
        let reader = MTCReader()
        var fireCount = 0
        reader.onFrame = { _, _ in fireCount += 1 }

        // Hours = 25 (invalid; must be < 24). Build manually.
        var bytes = quarterFrameSequence(hours: 9, minutes: 0, seconds: 0, frames: 0, rateBits: 0b11)
        // Replace hours LSB so reassembled hours = 25.
        bytes[6] = quarterFrameByte(field: 6, nibble: 9)  // low nibble 9
        bytes[7] = quarterFrameByte(field: 7, nibble: 0b0001 | (0b11 << 1))  // hours bit 4 set => 16 + 9 = 25
        for byte in bytes {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }
        XCTAssertEqual(fireCount, 0,
                       "Hours >= 24 is sanity-rejected so a corrupt MTC source can't poison the follower.")
    }

    func testOutOfRangeFramesDropFrame() {
        let reader = MTCReader()
        var fireCount = 0
        reader.onFrame = { _, _ in fireCount += 1 }

        // Frames = 30 with rate bits set to 24 fps (max valid frame = 23).
        let bytes = quarterFrameSequence(hours: 0, minutes: 0, seconds: 0, frames: 30, rateBits: 0b00)
        for byte in bytes {
            reader.ingestQuarterFrameForTesting(byte: byte)
        }
        XCTAssertEqual(fireCount, 0,
                       "Frames >= rate.integerFPS is sanity-rejected.")
    }

    // MARK: - Resync after a full assembly

    func testNextSequenceAfterEmissionReassemblesCleanly() {
        let reader = MTCReader()
        var captured: [TimecodeValue] = []
        reader.onFrame = { tc, _ in captured.append(tc) }

        let first = quarterFrameSequence(hours: 0, minutes: 0, seconds: 1, frames: 0, rateBits: 0b11)
        let second = quarterFrameSequence(hours: 0, minutes: 0, seconds: 2, frames: 15, rateBits: 0b11)

        for byte in first { reader.ingestQuarterFrameForTesting(byte: byte) }
        for byte in second { reader.ingestQuarterFrameForTesting(byte: byte) }

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].seconds, 1)
        XCTAssertEqual(captured[1].seconds, 2)
        XCTAssertEqual(captured[1].frames, 15)
    }
}
