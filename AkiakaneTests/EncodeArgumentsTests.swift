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
        XCTAssertTrue(args.containsConsecutive(["-f", "mp4"]), "出力は .partial 名なので、コンテナ形式を -f で明示する")
        XCTAssertEqual(args.last, output.path)
    }

    func testContainerFormatIsAlwaysExplicit() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        for (container, expected) in [(Container.mp4, "mp4"), (.mkv, "matroska"), (.mov, "mov")] {
            var settings = EncodeSettings()
            settings.container = container
            let args = makeArguments(input: info, output: output, settings: settings)
            XCTAssertTrue(args.containsConsecutive(["-f", expected]), "\(container) の -f が \(expected) でない")
        }
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

    // MARK: - 音声の扱いを渡したとき

    func testEncodePlanPassesEncoderBitrateAndChannelCount() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let plan = AudioPlan.encode(AACEncoding(encoder: "aac_at", bitrate: 384, channels: 6))
        let args = makeArguments(input: info, output: output, settings: EncodeSettings(), audio: plan)

        XCTAssertTrue(args.containsConsecutive(["-map", "0:a:0"]))
        XCTAssertTrue(args.containsConsecutive(["-c:a", "aac_at", "-b:a", "384k", "-ac", "6"]))
        XCTAssertTrue(args.containsConsecutive(["-af", "aresample=async=1"]), "復号できなかったフレームの分を無音で補い、同期を保つ")
        XCTAssertFalse(args.contains("-bsf:a"), "再エンコードするなら aac_adtstoasc は要らない")
    }

    func testCopyPlanDoesNotResampleAudio() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings(), audio: .copy)

        XCTAssertFalse(args.contains("-af"), "コピーにはフィルタを掛けられない")
    }

    func testEncodePlanWithoutChannelCountLeavesLayoutToFFmpeg() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let plan = AudioPlan.encode(AACEncoding(encoder: "aac", bitrate: 192, channels: nil))
        let args = makeArguments(input: info, output: output, settings: EncodeSettings(), audio: plan)

        XCTAssertTrue(args.containsConsecutive(["-c:a", "aac", "-b:a", "192k"]))
        XCTAssertFalse(args.contains("-ac"))
    }

    func testOmitPlanDropsAudioEvenIfSettingsSayCopy() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings(), audio: .omit)

        XCTAssertFalse(args.containsConsecutive(["-map", "0:a:0"]))
        XCTAssertFalse(args.contains("-c:a"))
    }
}

// MARK: - 音声の扱いの決定

final class AudioPlanTests: XCTestCase {

    private let tsInput = URL(fileURLWithPath: "/tmp/rec.ts")

    private func layout(_ channels: Int?, dualMono: Bool = false) -> AACFrameLayout {
        AACFrameLayout(
            profile: 1,
            samplingFrequencyIndex: 3,
            channelConfiguration: dualMono ? 2 : (channels == 8 ? 7 : channels ?? 0),
            channels: channels,
            isDualMono: dualMono
        )
    }

    private func report(_ segments: [AACFrameLayout]) -> AudioLayoutReport {
        AudioLayoutReport(frameCount: 1000, segments: segments)
    }

    func testCopyWithoutScanStaysCopy() {
        let info = TestFixtures.mediaInfo(url: tsInput)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: nil, aacEncoder: "aac_at")

        XCTAssertEqual(decision.plan, .copy)
        XCTAssertNil(decision.note)
    }

    func testCopyOfUniformSurroundStaysCopy() {
        // 構成が変わらない 5.1ch は、無劣化のコピーで 5.1ch のまま残す。
        let info = TestFixtures.mediaInfo(url: tsInput, audioChannels: 6)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: report([layout(6)]), aacEncoder: "aac_at")

        XCTAssertEqual(decision.plan, .copy)
    }

    func testCopyWithStereoToSurroundSwitchEncodesAsSurround() {
        // 冒頭がステレオ（ffprobe は 2ch と報告）でも、途中の 5.1ch に合わせて 6ch で変換する。
        let info = TestFixtures.mediaInfo(url: tsInput, audioChannels: 2)
        let scanned = report([layout(2), layout(6), layout(2)])
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: scanned, aacEncoder: "aac_at")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac_at", bitrate: 384, channels: 6)))
        XCTAssertNotNil(decision.note, "設定と違う扱いにしたので、理由を伝える")
        let note = decision.note ?? ""
        XCTAssertTrue(note.contains("ステレオ・5.1ch"), note)
        XCTAssertTrue(note.contains("切り替え 2 回"), note)
        XCTAssertTrue(note.contains("AAC 5.1ch（384 kbps）に変換する"), note)
        XCTAssertTrue(note.contains("ステレオの区間は前方の左右に入り"), note)
    }

    func testMonoToStereoSwitchDoesNotClaimSilentChannels() {
        // モノラルの区間をステレオで変換すると左右に同じ音が入る。無音になるとは書かない。
        let info = TestFixtures.mediaInfo(url: tsInput, audioChannels: 1)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: report([layout(1), layout(2)]), aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 192, channels: 2)))
        XCTAssertFalse(decision.note?.contains("無音") ?? true, decision.note ?? "")
    }

    func testSamplingRateOnlySwitchIsDescribedAsFormatChange() {
        let info = TestFixtures.mediaInfo(url: tsInput)
        let at48k = layout(2)
        let at44k = AACFrameLayout(profile: 1, samplingFrequencyIndex: 4, channelConfiguration: 2, channels: 2, isDualMono: false)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: report([at48k, at44k]), aacEncoder: "aac")

        let note = decision.note ?? ""
        XCTAssertTrue(note.contains("音声の形式"), note)
        XCTAssertFalse(note.contains("ステレオ・ステレオ"), note)
    }

    func testCopyOfDualMonoEncodesAsStereo() {
        let info = TestFixtures.mediaInfo(url: tsInput)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: report([layout(2, dualMono: true)]), aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 192, channels: 2)))
        XCTAssertTrue(decision.note?.contains("主音声が左、副音声が右") ?? false)
    }

    func testAACModeWithSwitchKeepsSurroundAndDoublesBitrate() {
        let info = TestFixtures.mediaInfo(url: tsInput, audioChannels: 2)
        var settings = EncodeSettings()
        settings.audioMode = .aac(bitrate: 192)
        let decision = makeAudioPlan(input: info, settings: settings, layout: report([layout(2), layout(6)]), aacEncoder: "aac_at")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac_at", bitrate: 384, channels: 6)))
        XCTAssertNotNil(decision.note)
    }

    func testAACModeWithoutScanUsesInputChannelsForBitrateOnly() {
        // MP4 などの 5.1ch 入力。構成は1つなので -ac は付けず、ビットレートだけ2倍にする。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/movie.mp4"), audioChannels: 6)
        var settings = EncodeSettings()
        settings.audioMode = .aac(bitrate: 160)
        let decision = makeAudioPlan(input: info, settings: settings, layout: nil, aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 320, channels: nil)))
        XCTAssertNil(decision.note)
    }

    func testAACModeKeepsStereoBitrate() {
        let info = TestFixtures.mediaInfo(url: tsInput)
        var settings = EncodeSettings()
        settings.audioMode = .aac(bitrate: 256)
        let decision = makeAudioPlan(input: info, settings: settings, layout: report([layout(2)]), aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 256, channels: 2)))
    }

    func testNoneAndMissingAudioAreOmitted() {
        var settings = EncodeSettings()
        settings.audioMode = .none
        let info = TestFixtures.mediaInfo(url: tsInput)
        XCTAssertEqual(makeAudioPlan(input: info, settings: settings, layout: nil, aacEncoder: "aac").plan, .omit)

        let silent = TestFixtures.mediaInfo(url: tsInput, includeAudio: false)
        XCTAssertEqual(makeAudioPlan(input: silent, settings: EncodeSettings(), layout: nil, aacEncoder: "aac").plan, .omit)
    }

    // MARK: 走査が必要かどうか

    func testScanIsNeededOnlyForAACInTransportStreams() {
        let settings = EncodeSettings()
        XCTAssertTrue(AudioLayoutScanner.needsScan(input: TestFixtures.mediaInfo(url: tsInput), settings: settings))
        XCTAssertTrue(AudioLayoutScanner.needsScan(input: TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/rec.M2TS")), settings: settings))
        XCTAssertFalse(AudioLayoutScanner.needsScan(input: TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/movie.mp4")), settings: settings))
        XCTAssertFalse(AudioLayoutScanner.needsScan(input: TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/00000.mts"), audioCodec: "ac3"), settings: settings))

        var none = EncodeSettings()
        none.audioMode = .none
        XCTAssertFalse(AudioLayoutScanner.needsScan(input: TestFixtures.mediaInfo(url: tsInput), settings: none))
    }

    func testScanArgumentsCopyFirstAudioStreamWithoutDecoding() {
        let args = AudioLayoutScanner.arguments(for: TestFixtures.mediaInfo(url: tsInput))

        XCTAssertTrue(args.containsConsecutive(["-map", "0:a:0", "-c", "copy"]))
        XCTAssertTrue(args.containsConsecutive(["-f", "data", "pipe:1"]))
        XCTAssertTrue(args.containsConsecutive(["-i", tsInput.path]))
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

// MARK: - VideoToolbox

final class VideoToolboxArgumentsTests: XCTestCase {

    func testVideoToolboxUsesQualityScaleNotCRF() {
        let input = URL(fileURLWithPath: "/tmp/rec.ts")
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        var settings = EncodeSettings()
        settings.videoCodec = .hevcVideoToolbox
        settings.videoToolboxQuality = 70
        let args = makeArguments(input: info, output: URL(fileURLWithPath: "/tmp/out.mp4.partial"), settings: settings)

        guard let codecIndex = args.firstIndex(of: "-c:v") else { return XCTFail("-c:v がない") }
        XCTAssertEqual(args[codecIndex + 1], "hevc_videotoolbox")
        guard let qualityIndex = args.firstIndex(of: "-q:v") else { return XCTFail("-q:v がない") }
        XCTAssertEqual(args[qualityIndex + 1], "70")
        XCTAssertFalse(args.contains("-crf"), "VideoToolbox に -crf は渡さない")
        XCTAssertFalse(args.contains("-preset"), "VideoToolbox に x265 のプリセットは渡さない")
        guard let tagIndex = args.firstIndex(of: "-tag:v") else { return XCTFail("-tag:v がない") }
        XCTAssertEqual(args[tagIndex + 1], "hvc1")
    }

    func testCopyCodecSkipsDeinterlaceAndTag() {
        let input = URL(fileURLWithPath: "/tmp/rec.ts")
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "tt")
        var settings = EncodeSettings()
        settings.videoCodec = .copy
        let args = makeArguments(input: info, output: URL(fileURLWithPath: "/tmp/out.mp4.partial"), settings: settings)

        XCTAssertFalse(args.contains("-vf"), "コピー時はフィルタを掛けられない")
        XCTAssertFalse(args.contains("-tag:v"), "H.264 のままなので hvc1 タグは付けない")
    }
}
