import XCTest
@testable import Akiakane

/// `ADTSLayoutParser` のテスト。ffmpeg を起動せず、ADTS フレームをビット単位で組み立てて食わせる。
final class ADTSLayoutParserTests: XCTestCase {

    // MARK: - 構成の切り替え

    func testUniformStereoHasNoLayoutChange() {
        let report = parse(frames(stereo, count: 10))

        XCTAssertEqual(report.frameCount, 10)
        XCTAssertEqual(report.segments.map(\.channels), [2])
        XCTAssertFalse(report.hasLayoutChange)
        XCTAssertFalse(report.isUnsafeToCopy, "構成が1つならコピーしてよい")
        XCTAssertEqual(report.maxChannels, 2)
    }

    func testStereoToSurroundAndBackIsDetected() {
        // 前後の CM はステレオ、本編は 5.1ch という放送でよくある形。
        let report = parse(frames(stereo, count: 10) + frames(surround51, count: 10) + frames(stereo, count: 10))

        XCTAssertEqual(report.frameCount, 30)
        XCTAssertEqual(report.segments.map(\.channels), [2, 6, 2])
        XCTAssertEqual(report.switchCount, 2)
        XCTAssertEqual(report.distinctLayouts.map(\.channels), [2, 6])
        XCTAssertEqual(report.maxChannels, 6)
        XCTAssertTrue(report.isUnsafeToCopy)
    }

    func testShortGlitchIsNotCountedAsLayoutChange() {
        // 壊れたフレームが 1〜2 個だけ別の構成に見えても、切り替えとはみなさない。
        let report = parse(frames(stereo, count: 10) + frames(surround51, count: 2) + frames(stereo, count: 10))

        XCTAssertEqual(report.segments.map(\.channels), [2])
        XCTAssertFalse(report.hasLayoutChange)
    }

    func testVeryShortStreamStillReportsItsLayout() {
        let report = parse(frames(surround51, count: 2))

        XCTAssertEqual(report.frameCount, 2)
        XCTAssertEqual(report.segments.map(\.channels), [6])
    }

    func testEmptyInputHasNoFrames() {
        let report = parse([])

        XCTAssertEqual(report.frameCount, 0)
        XCTAssertTrue(report.segments.isEmpty)
    }

    // MARK: - デュアルモノ

    func testDualMonoInStereoConfigurationIsDetected() {
        // channel_configuration は 2 なのに、CPE ではなく SCE が並ぶ。
        let dualMono = Frame(channelConfiguration: 2, payload: element(.sce))
        let report = parse(frames(dualMono, count: 5))

        XCTAssertEqual(report.segments.count, 1)
        XCTAssertTrue(report.segments[0].isDualMono)
        XCTAssertEqual(report.segments[0].channels, 2)
        XCTAssertTrue(report.isUnsafeToCopy, "デュアルモノは切り替えがなくても Apple で再生できない")
    }

    func testARIBStyleDualMonoWithoutPCEIsDetected() {
        let dualMono = Frame(channelConfiguration: 0, payload: element(.sce))
        let report = parse(frames(dualMono, count: 5))

        XCTAssertTrue(report.segments[0].isDualMono)
        XCTAssertEqual(report.segments[0].channels, 2)
    }

    func testStereoToDualMonoIsALayoutChange() {
        let dualMono = Frame(channelConfiguration: 2, payload: element(.sce))
        let report = parse(frames(stereo, count: 5) + frames(dualMono, count: 5) + frames(stereo, count: 5))

        XCTAssertEqual(report.segments.map(\.isDualMono), [false, true, false])
        XCTAssertEqual(report.maxChannels, 2)
    }

    // MARK: - 先頭の要素の読み方

    func testFillElementBeforeFirstAudioElementIsSkipped() {
        var withFill = BitWriter()
        withFill.write(6, bits: 3)          // FIL
        withFill.write(2, bits: 4)          // 2 バイトの詰め物
        withFill.write(0xAAAA, bits: 16)
        withFill.write(0, bits: 3)          // SCE
        let dualMono = Frame(channelConfiguration: 2, payload: withFill.bytes(padTo: 8))

        var fillThenPair = BitWriter()
        fillThenPair.write(6, bits: 3)
        fillThenPair.write(1, bits: 4)
        fillThenPair.write(0x55, bits: 8)
        fillThenPair.write(1, bits: 3)      // CPE
        let normalStereo = Frame(channelConfiguration: 2, payload: fillThenPair.bytes(padTo: 8))

        XCTAssertTrue(parse(frames(dualMono, count: 3)).segments[0].isDualMono, "FIL を飛ばした先の SCE を見る")
        XCTAssertFalse(parse(frames(normalStereo, count: 3)).segments[0].isDualMono, "FIL を飛ばした先の CPE を見る")
    }

    // 以下の要素の読み飛ばしのテストは、どれも「正しく読めば CPE（デュアルモノではない）、
    // 1バイトでも読み違えれば 0 埋めの部分を SCE と読んでデュアルモノになる」ように組んである。

    func testDataStreamElementByteAlignmentIsHonored() {
        var writer = BitWriter()
        writer.write(6, bits: 3)            // FIL（詰め物なし）。これで DSE の開始がバイト境界からずれる
        writer.write(0, bits: 4)
        writer.write(4, bits: 3)            // DSE
        writer.write(0, bits: 4)            // element_instance_tag
        writer.write(1, bits: 1)            // data_byte_align_flag
        writer.write(1, bits: 8)            // 1 バイト
        writer.alignToByte()                // ここで 1 ビット詰める
        writer.write(0x00, bits: 8)
        writer.write(1, bits: 3)            // CPE
        let stereo = Frame(channelConfiguration: 2, payload: writer.bytes(padTo: 8))

        XCTAssertFalse(parse(frames(stereo, count: 3)).segments[0].isDualMono, "整列を無視すると 1 ビット手前を読んで SCE になる")
    }

    func testFillElementEscapeCountIsHonored() {
        var writer = BitWriter()
        writer.write(6, bits: 3)            // FIL
        writer.write(15, bits: 4)           // 15 はエスケープ
        writer.write(3, bits: 8)            // 15 + 3 − 1 = 17 バイト
        for _ in 0..<17 { writer.write(0, bits: 8) }
        writer.write(1, bits: 3)            // CPE
        let stereo = Frame(channelConfiguration: 2, payload: writer.bytes(padTo: 24))

        XCTAssertFalse(parse(frames(stereo, count: 3)).segments[0].isDualMono)
    }

    func testDataStreamElementEscapeCountIsHonored() {
        var writer = BitWriter()
        writer.write(4, bits: 3)            // DSE
        writer.write(0, bits: 4)
        writer.write(0, bits: 1)            // 整列しない
        writer.write(255, bits: 8)          // 255 はエスケープ
        writer.write(2, bits: 8)            // 255 + 2 = 257 バイト
        for _ in 0..<257 { writer.write(0, bits: 8) }
        writer.write(1, bits: 3)            // CPE
        let stereo = Frame(channelConfiguration: 2, payload: writer.bytes(padTo: 264))

        XCTAssertFalse(parse(frames(stereo, count: 3)).segments[0].isDualMono)
    }

    func testProgramConfigElementChannelsAreCounted() {
        let report = parse(frames(pce51(withMixdown: false), count: 3))

        XCTAssertEqual(report.segments.first?.channels, 6)
        XCTAssertFalse(report.segments.first?.isDualMono ?? true)
    }

    func testProgramConfigMixdownFieldsAreSkipped() {
        let report = parse(frames(pce51(withMixdown: true), count: 3))

        XCTAssertEqual(report.segments.first?.channels, 6, "mixdown の各フィールドを読み飛ばさないと、要素の数え方がずれる")
    }

    // MARK: - PCE の引き継ぎ

    func testProgramConfigInFirstFrameOnlyIsCarriedOver() {
        // ffmpeg は PCE を最初のフレームにしか書かない。後続のフレームは先頭が SCE（センター）になる。
        let report = parse(frames(pce51(withMixdown: false), count: 1) + frames(pceContinuation, count: 10))

        XCTAssertEqual(report.segments.map(\.channels), [6])
        XCTAssertFalse(report.hasDualMono, "PCE の構成を引き継ぐ。デュアルモノと取り違えない")
        XCTAssertFalse(report.isUnsafeToCopy, "構成が1つならコピーしてよい")
    }

    func testStereoToProgramConfigSurroundKeepsSixChannels() {
        let report = parse(frames(stereo, count: 10) + frames(pce51(withMixdown: false), count: 1) + frames(pceContinuation, count: 10))

        XCTAssertEqual(report.segments.map(\.channels), [2, 6])
        XCTAssertEqual(report.maxChannels, 6)
        XCTAssertFalse(report.hasDualMono)
    }

    func testProgramConfigIsForgottenAfterOtherConfiguration() {
        // PCE の 5.1ch → ステレオ → ARIB 式のデュアルモノ。ステレオを挟めば PCE の構成は引き継がない。
        let report = parse(
            frames(pce51(withMixdown: false), count: 1) + frames(pceContinuation, count: 5)
                + frames(stereo, count: 5) + frames(aribDualMono, count: 5)
        )

        XCTAssertEqual(report.segments.map(\.channels), [6, 2, 2])
        XCTAssertEqual(report.segments.map(\.isDualMono), [false, false, true])
    }

    // MARK: - 先頭のフレーム

    func testDifferentLayoutInFirstFramesIsKept() {
        // aac_adtstoasc は最初のフレームから構成を作るので、先頭の2フレームだけ違っても、コピーすると全編が壊れる。
        let report = parse(frames(stereo, count: 2) + frames(surround51, count: 10))

        XCTAssertEqual(report.segments.map(\.channels), [2, 6])
        XCTAssertTrue(report.leadingSegmentIsUnconfirmed)
        XCTAssertTrue(report.isUnsafeToCopy)
        XCTAssertEqual(report.maxChannels, 6)
    }

    func testCorruptFirstFrameDoesNotStopTheConversion() throws {
        // 先頭のフレームが壊れて ARIB 式のデュアルモノに見えても、それだけでは変換を止めない。
        let report = parse(frames(aribDualMono, count: 1) + frames(stereo, count: 10))

        XCTAssertTrue(report.leadingSegmentIsUnconfirmed)
        XCTAssertTrue(report.isUnsafeToCopy, "コピーすると先頭のフレームの構成で全編が書かれる")
        XCTAssertNoThrow(try report.checkConvertible(fileName: "rec.ts"))
    }

    func testDifferentLayoutInFirstFramesIsKeptInReverse() {
        let report = parse(frames(surround51, count: 2) + frames(stereo, count: 10))

        XCTAssertEqual(report.segments.map(\.channels), [6, 2])
        XCTAssertEqual(report.maxChannels, 6, "先頭の 5.1ch も最大チャンネル数に数える")
    }

    // MARK: - 変換を止める構成

    func testARIBDualMonoCannotBeConverted() {
        let report = parse(frames(stereo, count: 5) + frames(aribDualMono, count: 5))

        XCTAssertThrowsError(try report.checkConvertible(fileName: "rec.ts")) { error in
            XCTAssertEqual(error as? AudioLayoutError, .undecodableDualMono(fileName: "rec.ts"))
        }
    }

    func testLayoutChangeWithUnknownChannelsCannotBeConverted() {
        // channel_configuration 0 で PCE を見ていない CPE は、チャンネル数が分からない。
        let unknown = Frame(channelConfiguration: 0, payload: element(.cpe))
        let report = parse(frames(stereo, count: 5) + frames(unknown, count: 5))

        XCTAssertThrowsError(try report.checkConvertible(fileName: "rec.ts")) { error in
            XCTAssertEqual(error as? AudioLayoutError, .undeterminedLayout(fileName: "rec.ts"))
        }
    }

    func testUniformUnknownLayoutAndNormalSwitchCanBeConverted() {
        let unknown = Frame(channelConfiguration: 0, payload: element(.cpe))
        XCTAssertNoThrow(try parse(frames(unknown, count: 5)).checkConvertible(fileName: "rec.ts"), "構成が1つならコピーできる")
        XCTAssertNoThrow(try parse(frames(stereo, count: 5) + frames(surround51, count: 5)).checkConvertible(fileName: "rec.ts"))
    }

    // MARK: - 同期とチャンク境界

    func testGarbageBeforeAndBetweenFramesIsSkipped() {
        let garbage: [UInt8] = [0x00, 0x12, 0xFF, 0x00, 0x47, 0x40]
        let bytes = garbage + frames(stereo, count: 5) + garbage + frames(stereo, count: 5)
        let report = parse(bytes)

        // ゴミの直前のフレームは、次のフレームの先頭で確かめられないので数えない。
        XCTAssertEqual(report.frameCount, 9)
        XCTAssertEqual(report.segments.map(\.channels), [2])
    }

    func testFakeSyncWordIsNotTakenAsAFrame() {
        // ADTS ヘッダに見える 7 バイトの後に、次のヘッダが続かない。
        let fake: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC] + [UInt8](repeating: 0x33, count: 40)
        let report = parse(frames(stereo, count: 5) + fake + frames(stereo, count: 5))

        XCTAssertEqual(report.frameCount, 10)
    }

    func testFeedingByteByByteGivesTheSameResult() {
        let bytes = frames(stereo, count: 6) + frames(surround51, count: 6) + frames(stereo, count: 6)
        let whole = parse(bytes)

        let parser = ADTSLayoutParser()
        for byte in bytes { parser.append(Data([byte])) }
        let pieces = parser.finish()

        XCTAssertEqual(pieces, whole)
        XCTAssertEqual(pieces.segments.map(\.channels), [2, 6, 2])
    }

    func testHeaderWithCRCIsParsed() {
        // CRC（2 バイト、ここでは 0）を飛ばさずに要素を読むと、CRC の 0 を SCE と読んでデュアルモノになる。
        let withCRC = Frame(channelConfiguration: 2, payload: element(.cpe), hasCRC: true)
        let report = parse(frames(withCRC, count: 4))

        XCTAssertEqual(report.frameCount, 4)
        XCTAssertEqual(report.segments.map(\.channels), [2])
        XCTAssertFalse(report.hasDualMono)
    }

    // MARK: - テスト用のフレーム

    private let stereo = Frame(channelConfiguration: 2, payload: element(.cpe))
    private let surround51 = Frame(channelConfiguration: 6, payload: element(.sce))
    private let aribDualMono = Frame(channelConfiguration: 0, payload: element(.sce))
    /// PCE を持たない、PCE 方式の 5.1ch の2フレーム目以降（先頭はセンターの SCE）。
    private let pceContinuation = Frame(channelConfiguration: 0, payload: element(.sce))

    /// PCE で 5.1ch を定義するフレーム: 前方に C（SCE）と L/R（CPE）、後方に Ls/Rs（CPE）、LFE が1つ。
    private func pce51(withMixdown: Bool) -> Frame {
        var writer = BitWriter()
        writer.write(5, bits: 3)            // PCE
        writer.write(0, bits: 4)            // element_instance_tag
        writer.write(1, bits: 2)            // object_type（LC）
        writer.write(3, bits: 4)            // sampling_frequency_index（48 kHz）
        writer.write(2, bits: 4)            // num_front_channel_elements
        writer.write(0, bits: 4)            // num_side_channel_elements
        writer.write(1, bits: 4)            // num_back_channel_elements
        writer.write(1, bits: 2)            // num_lfe_channel_elements
        writer.write(0, bits: 3)            // num_assoc_data_elements
        writer.write(0, bits: 4)            // num_valid_cc_elements
        if withMixdown {
            writer.write(1, bits: 1); writer.write(0b1111, bits: 4)          // mono_mixdown
            writer.write(1, bits: 1); writer.write(0b1111, bits: 4)          // stereo_mixdown
            writer.write(1, bits: 1); writer.write(0b11, bits: 2); writer.write(1, bits: 1)  // matrix_mixdown
        } else {
            writer.write(0, bits: 1)
            writer.write(0, bits: 1)
            writer.write(0, bits: 1)
        }
        writer.write(0, bits: 1); writer.write(0, bits: 4)   // 前方: SCE
        writer.write(1, bits: 1); writer.write(0, bits: 4)   // 前方: CPE
        writer.write(1, bits: 1); writer.write(1, bits: 4)   // 後方: CPE
        writer.write(0, bits: 4)                             // LFE
        return Frame(channelConfiguration: 0, payload: writer.bytes(padTo: 16))
    }

    private func parse(_ bytes: [UInt8]) -> AudioLayoutReport {
        let parser = ADTSLayoutParser()
        parser.append(Data(bytes))
        return parser.finish()
    }

    private func frames(_ frame: Frame, count: Int) -> [UInt8] {
        Array((0..<count).map { _ in frame.bytes }.joined())
    }
}

// MARK: - ADTS フレームの組み立て

private enum SyntacticElement: Int {
    case sce = 0
    case cpe = 1
}

/// 先頭が指定の要素で、残りは 0 埋めの raw_data_block。
private func element(_ element: SyntacticElement) -> [UInt8] {
    var writer = BitWriter()
    writer.write(element.rawValue, bits: 3)
    return writer.bytes(padTo: 8)
}

private struct Frame {
    var profile = 1                 // AAC-LC
    var samplingFrequencyIndex = 3  // 48 kHz
    var channelConfiguration: Int
    var payload: [UInt8]
    var hasCRC = false

    var bytes: [UInt8] {
        let headerLength = hasCRC ? 9 : 7
        let frameLength = headerLength + payload.count
        var writer = BitWriter()
        writer.write(0xFFF, bits: 12)                   // syncword
        writer.write(0, bits: 1)                        // ID（MPEG-4）
        writer.write(0, bits: 2)                        // layer
        writer.write(hasCRC ? 0 : 1, bits: 1)           // protection_absent
        writer.write(profile, bits: 2)
        writer.write(samplingFrequencyIndex, bits: 4)
        writer.write(0, bits: 1)                        // private_bit
        writer.write(channelConfiguration, bits: 3)
        writer.write(0, bits: 4)                        // original/copy, home, copyright の2ビット
        writer.write(frameLength, bits: 13)
        writer.write(0x7FF, bits: 11)                   // adts_buffer_fullness
        writer.write(0, bits: 2)                        // number_of_raw_data_blocks_in_frame
        if hasCRC { writer.write(0, bits: 16) }
        return writer.bytes(padTo: headerLength) + payload
    }
}

private struct BitWriter {
    private var storage: [UInt8] = []
    private var bitCount = 0

    mutating func write(_ value: Int, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { storage.append(0) }
            if (value >> shift) & 1 == 1 {
                storage[storage.count - 1] |= UInt8(0x80 >> (bitCount % 8))
            }
            bitCount += 1
        }
    }

    mutating func alignToByte() {
        while bitCount % 8 != 0 { write(0, bits: 1) }
    }

    /// 書いた分を 0 埋めして `length` バイトにする。
    func bytes(padTo length: Int) -> [UInt8] {
        storage + [UInt8](repeating: 0, count: max(length - storage.count, 0))
    }
}
