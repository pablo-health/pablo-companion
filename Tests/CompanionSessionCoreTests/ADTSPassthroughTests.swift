import Foundation
import Testing
@testable import CompanionSessionCore

/// Covers ADTS/AAC detection — the branch that decides whether captured audio
/// gets a WAV header stapled on or passes through untouched.
///
/// This is the production capture format since #105 (AudioCaptureKit 1.2.0's
/// streaming AAC), yet every upload fixture in the suite is legacy raw PCM and
/// the happy-path test asserts the bytes come out prefixed `RIFF`. So the arm
/// that actually runs in production had no test at all: if the sync mask were
/// wrong, every AAC recording would be uploaded with a WAV header claiming PCM
/// stapled in front of it — corrupt at transcription, with every test green.
@Suite("ADTS/AAC passthrough")
struct ADTSPassthroughTests {

    // MARK: - Real ADTS frame syncs

    @Test func aRealADTSFrameSyncIsDetected() {
        // MPEG-4 AAC LC, the shape AudioCaptureKit's encoder emits.
        #expect(AudioUploadClient.isADTSSync(Data([0xFF, 0xF1, 0x50, 0x80])))
    }

    @Test func mpeg2ADTSIsAlsoDetected() {
        // 0xF9 — MPEG-2 variant, layer bits still clear.
        #expect(AudioUploadClient.isADTSSync(Data([0xFF, 0xF9, 0x4C, 0x80])))
    }

    @Test func protectionAbsentBitDoesNotMatter() {
        // 0xF0 = CRC present, 0xF1 = absent. Both are valid syncs.
        #expect(AudioUploadClient.isADTSSync(Data([0xFF, 0xF0])))
        #expect(AudioUploadClient.isADTSSync(Data([0xFF, 0xF1])))
    }

    // MARK: - Things that must NOT be mistaken for ADTS

    @Test func layerBitsSetMeanItIsNotADTS() {
        // Byte 2 of an ADTS header is `1111 VLLP`: bits 7-4 syncword, bit 3
        // MPEG version, bits 2-1 layer, bit 0 protection-absent. ADTS requires
        // layer == 00, which is exactly what the 0xF6 mask checks while
        // deliberately ignoring version and protection.
        //
        // So these two have a layer set and must be rejected:
        #expect(!AudioUploadClient.isADTSSync(Data([0xFF, 0xF2]))) // layer 01
        #expect(!AudioUploadClient.isADTSSync(Data([0xFF, 0xF4]))) // layer 10
    }

    @Test func theVersionBitIsIgnoredNotTreatedAsALayerBit() {
        // 0xF8 sets bit 3 — the MPEG-2 version bit, not a layer bit — so it is
        // a valid sync and must pass. Reading bit 3 as "layer" would reject
        // every MPEG-2 AAC frame. This test exists because an earlier version of
        // it asserted the opposite and the implementation was right.
        #expect(AudioUploadClient.isADTSSync(Data([0xFF, 0xF8])))
    }

    @Test func riffIsNotADTS() {
        #expect(!AudioUploadClient.isADTSSync(Data("RIFF".utf8)))
    }

    @Test func rawPCMIsNotMistakenForADTS() {
        // Silence, and a loud sample. Neither may trip the sync.
        #expect(!AudioUploadClient.isADTSSync(Data([0x00, 0x00, 0x00, 0x00])))
        #expect(!AudioUploadClient.isADTSSync(Data([0xFF, 0x7F, 0xFF, 0x7F])))
    }

    @Test func aSingleByteIsNotEnoughToDecide() {
        // Needs two bytes; one 0xFF alone must not be read as a sync.
        #expect(!AudioUploadClient.isADTSSync(Data([0xFF])))
    }

    @Test func emptyDataIsNotADTS() {
        #expect(!AudioUploadClient.isADTSSync(Data()))
    }

    // MARK: - The consequence: what reaches the wire

    @Test func aacBytesAreUploadedUntouched() {
        // The production path. A WAV header in front of AAC would misdescribe
        // the payload as PCM.
        let aac = Data([0xFF, 0xF1, 0x50, 0x80] + Array(repeating: UInt8(0x42), count: 512))

        let out = AudioUploadClient.wavData(aac, sampleRate: 48000, channels: 1)

        #expect(out == aac)
        #expect(!out.prefix(4).elementsEqual(Data("RIFF".utf8)))
    }

    @Test func riffBytesAreUploadedUntouched() {
        let wav = WAVEncoder.wrap(pcm: Data(repeating: 0x01, count: 128), sampleRate: 48000, channels: 1)

        let out = AudioUploadClient.wavData(wav, sampleRate: 48000, channels: 1)

        #expect(out == wav)
    }

    @Test func headerlessPCMStillGetsWrapped() {
        // The legacy path must keep working: raw sidecars carry no header, so
        // the backend needs one prepended.
        let pcm = Data(repeating: 0x01, count: 128)

        let out = AudioUploadClient.wavData(pcm, sampleRate: 48000, channels: 1)

        #expect(out.prefix(4).elementsEqual(Data("RIFF".utf8)))
        #expect(out.count == pcm.count + 44)
    }
}
