import XCTest
@testable import Akiakane

final class EncodeArgumentsTests: XCTestCase {

    private let input = URL(fileURLWithPath: "/tmp/rec.ts")
    private let output = URL(fileURLWithPath: "/tmp/rec_h265.mp4.partial")

    // MARK: - 基本の並び

    func testFflagsComesBeforeInputOption() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings())

        guard let fflagsIndex = args.firstIndex(of: "-fflags"),
              let inputOptionIndex = args.firstIndex(of: "-i") else {
            return XCTFail("-fflags または -i が見つからない")
        }
        XCTAssertLess(fflagsIndex, inputOptionIndex)
        XCTAssertEqual(args[fflagsIndex + 1], "+genpts")
    }

    func testProgressiveMP4CopyAudioFromTS() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings())

        XCTAssertTrue(args.containsConsecutive(["-map", "0:v:0"]))
        XCTAssertTrue(args.containsConsecutive(["-map", "0:a:0"]))
        XCTAssertTrue(args.containsConsecutive(["-c:v", "libx265", "-crf", "21", "-preset", "slow", "-pix_fmt", "yuv420p"]))
        XCTAssertFalse(args.contains("-vf"), "プログレッシブ素材はインターレース解除しない")
        XCTAssertTrue(args.containsConsecutive(["-c:a", "copy"]))
        XCTAssertTrue(args.containsConsecutive(["-bsf:a", "aac_adtstoasc"]), ".ts からのコピーには aac_adtstoasc が必要")
        XCTAssertTrue(args.containsConsecutive(["-tag:v", "hvc1"]))
        XCTAssertTrue(args.containsConsecutive(["-movflags", "+faststart"]))
        XCTAssertTrue(args.containsConsecutive(["-progress", "pipe:1", "-nostats", "-loglevel", "error"]))
        XCTAssertEqual(args.last, output.path)
    }

    // MARK: - インターレース解除

    func testInterlacedMaterialGetsBwdifFilterWhenAuto() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "tt")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings())

        XCTAssertTrue(args.containsConsecutive(["-vf", "bwdif=mode=send_frame:parity=auto:deint=interlaced"]))
    }

    func testUndeterminedFieldOrderAlsoGetsBwdifFilterWhenAuto() {
        // field_order が取れない素材（ffprobe が "unknown" を返す、あるいは値が無い）。
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: nil)
        let args = makeArguments(input: info, output: output, settings: EncodeSettings())

        XCTAssertTrue(args.containsConsecutive(["-vf", "bwdif=mode=send_frame:parity=auto:deint=interlaced"]))
    }

    func testDeinterlaceOffNeverAddsFilterEvenIfInterlaced() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "tt")
        var settings = EncodeSettings()
        settings.deinterlace = .off
        let args = makeArguments(input: info, output: output, settings: settings)

        XCTAssertFalse(args.contains("-vf"))
    }

    func testDeinterlaceForceAddsFilterEvenIfProgressive() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        var settings = EncodeSettings()
        settings.deinterlace = .force
        let args = makeArguments(input: info, output: output, settings: settings)

        XCTAssertTrue(args.containsConsecutive(["-vf", "bwdif=mode=send_frame:parity=auto:deint=interlaced"]))
    }

    // MARK: - コンテナ別の違い

    func testMKVContainerSkipsHvc1TagAndFaststartAndBitstreamFilter() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        var settings = EncodeSettings()
        settings.container = .mkv
        let args = makeArguments(input: info, output: output, settings: settings)

        XCTAssertFalse(args.contains("-tag:v"))
        XCTAssertFalse(args.contains("-movflags"))
        XCTAssertFalse(args.contains("-bsf:a"), "MKV では aac_adtstoasc は不要")
    }

    func testNonTSSourceDoesNotGetBitstreamFilterEvenForMP4() {
        let mp4Input = URL(fileURLWithPath: "/tmp/already_h264.mp4")
        let info = TestFixtures.mediaInfo(url: mp4Input, fieldOrder: "progressive")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings())

        XCTAssertFalse(args.contains("-bsf:a"), ".ts 由来でない入力にはビットストリームフィルタを付けない")
    }

    // MARK: - 音声なし

    func testAudioNoneSkipsAudioMappingAndEncoding() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        var settings = EncodeSettings()
        settings.audioMode = .none
        let args = makeArguments(input: info, output: output, settings: settings)

        XCTAssertFalse(args.containsConsecutive(["-map", "0:a:0"]))
        XCTAssertFalse(args.contains("-c:a"))
    }
}

private extension Array where Element: Equatable {
    /// `pair` の要素が、この配列のどこかに連続して同じ順序で現れるか。
    func containsConsecutive(_ pair: [Element]) -> Bool {
        guard !pair.isEmpty, pair.count <= count else { return false }
        for start in 0...(count - pair.count) {
            if Array(self[start..<(start + pair.count)]) == pair {
                return true
            }
        }
        return false
    }
}

private func XCTAssertLess<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a < b, "\(a) が \(b) より前にありません", file: file, line: line)
}
