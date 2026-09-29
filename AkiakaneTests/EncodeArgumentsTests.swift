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

        XCTAssertTrue(args.containsConsecutive(["-map", "0:0"]))
        XCTAssertTrue(args.containsConsecutive(["-map", "0:1"]))
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

        XCTAssertTrue(args.containsConsecutive(["-vf", "bwdif=mode=send_frame:parity=auto:deint=all"]))
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

    func testAC3FromTransportStreamIsCopiedWithoutAACBitstreamFilter() {
        // AVCHD の .MTS / .m2ts は AC-3。aac_adtstoasc を付けると ffmpeg が起動直後に失敗する。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/00000.MTS"), audioCodec: "ac3")
        let args = makeArguments(input: info, output: output, settings: EncodeSettings())

        XCTAssertTrue(args.containsConsecutive(["-c:a", "copy"]))
        XCTAssertFalse(args.contains("-bsf:a"))
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

        XCTAssertFalse(args.containsConsecutive(["-map", "0:1"]))
        XCTAssertFalse(args.contains("-c:a"))
    }

    // MARK: - 音声の扱いを渡したとき

    func testEncodePlanPassesEncoderBitrateAndChannelCount() {
        let info = TestFixtures.mediaInfo(url: input, fieldOrder: "progressive")
        let plan = AudioPlan.encode(AACEncoding(encoder: "aac_at", bitrate: 384, channels: 6))
        let args = makeArguments(input: info, output: output, settings: EncodeSettings(), audio: plan)

        XCTAssertTrue(args.containsConsecutive(["-map", "0:1"]))
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

        XCTAssertFalse(args.containsConsecutive(["-map", "0:1"]))
        XCTAssertFalse(args.contains("-c:a"))
    }
}

// MARK: - 音声の扱いの決定

final class AudioPlanTests: XCTestCase {

    private let tsInput = URL(fileURLWithPath: "/tmp/rec.ts")
    private let output = URL(fileURLWithPath: "/tmp/out.mp4.partial")

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

    func testLeadingFramesOnlyAreDescribedAsSuch() {
        let info = TestFixtures.mediaInfo(url: tsInput, audioChannels: 2)
        let scanned = AudioLayoutReport(frameCount: 1000, segments: [layout(2), layout(6)], leadingSegmentIsUnconfirmed: true)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: scanned, aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 384, channels: 6)))
        XCTAssertTrue(decision.note?.contains("先頭の数フレームだけ") ?? false, decision.note ?? "")
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

    func testAACModeWithoutScanKeepsInputChannelsAndDoublesBitrate() {
        // MP4 などの 5.1ch 入力。チャンネル数は ffprobe の値で明示し、ビットレートを2倍にする。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/movie.mp4"), audioChannels: 6)
        var settings = EncodeSettings()
        settings.audioMode = .aac(bitrate: 160)
        let decision = makeAudioPlan(input: info, settings: settings, layout: nil, aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 320, channels: 6)))
        XCTAssertNil(decision.note)
    }

    func testAACModeKeepsStereoBitrate() {
        let info = TestFixtures.mediaInfo(url: tsInput)
        var settings = EncodeSettings()
        settings.audioMode = .aac(bitrate: 256)
        let decision = makeAudioPlan(input: info, settings: settings, layout: report([layout(2)]), aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 256, channels: 2)))
    }

    func testAudioThatMP4CannotHoldIsConvertedToAAC() {
        // WMV の wmav2 や、古いデジカメの AVI の pcm_u8 / IMA ADPCM は、MP4 にコピーすると ffmpeg が失敗する。
        // MP3 は MP4 に書けても、Apple 製アプリが音声トラックごと無視する。
        for codec in ["wmav2", "pcm_u8", "adpcm_ima_wav", "mp2", "pcm_s16le", "mp3"] {
            let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/clip.avi"), audioCodec: codec)
            let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: nil, aacEncoder: "aac_at")

            XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac_at", bitrate: 192, channels: 2)), codec)
            XCTAssertTrue(decision.note?.contains(codec) ?? false, decision.note ?? "")
        }
    }

    func testAudioThatTheContainerCanHoldIsCopied() {
        let cases: [(String, Container)] = [
            ("aac", .mp4), ("ac3", .mp4), ("eac3", .mp4), ("alac", .mp4), ("mp3", .mov), ("pcm_s16le", .mov),
            ("wmav2", .mkv), ("pcm_u8", .mkv), ("flac", .mkv),
        ]
        for (codec, container) in cases {
            let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/clip.avi"), audioCodec: codec)
            var settings = EncodeSettings()
            settings.container = container
            XCTAssertEqual(makeAudioPlan(input: info, settings: settings, layout: nil, aacEncoder: "aac").plan, .copy, "\(codec) → \(container)")
        }
    }

    func testIncompatibleSurroundAudioKeepsItsChannelsAndDoublesBitrate() {
        // Blu-ray の LPCM 5.1ch を MP4 にする。チャンネル数を明示し、ビットレートを5.1ch 用にする。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/00001.m2ts"), audioCodec: "pcm_bluray", audioChannels: 6)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: nil, aacEncoder: "aac")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 384, channels: 6)))
    }

    func testLPCMIntoMKVOrMOVBecomesLosslessPCM() {
        // Blu-ray / DVD / 放送の LPCM は MKV にコピーできず、MOV にもそのままは入らない。24 bit の PCM にすれば無劣化で入る。
        for codec in ["pcm_bluray", "pcm_dvd", "s302m"] {
            for container in [Container.mkv, .mov] {
                let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/00001.m2ts"), audioCodec: codec, audioChannels: 6)
                var settings = EncodeSettings()
                settings.container = container
                let decision = makeAudioPlan(input: info, settings: settings, layout: nil, aacEncoder: "aac_at")
                XCTAssertEqual(decision.plan, .pcm(codec: "pcm_s24le"), "\(codec) → \(container)")
            }
        }
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/00001.m2ts"), audioCodec: "pcm_bluray")
        var mkv = EncodeSettings()
        mkv.container = .mkv
        let args = makeArguments(input: info, output: output, settings: mkv, audio: makeAudioPlan(input: info, settings: mkv, layout: nil, aacEncoder: "aac").plan)
        XCTAssertTrue(args.containsConsecutive(["-c:a", "pcm_s24le"]))
        XCTAssertFalse(args.contains("-af"))
    }

    func testSevenPointOneUsesBuiltInEncoderAndKeepsEightChannels() {
        // aac_at は 7.1ch の LFE を捨てて 7.0 にするので、8ch だけは内蔵の aac を使う。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/movie.mkv"), audioCodec: "flac", audioChannels: 8)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: nil, aacEncoder: "aac_at")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac", bitrate: 576, channels: 8)))
    }

    func testHighSampleRateIsConvertedTo48kHz() {
        // aac_at は 96 kHz を受け付けず、起動直後に失敗する。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/clip.mov"), audioCodec: "pcm_s24le", audioSampleRate: 96_000)
        let decision = makeAudioPlan(input: info, settings: EncodeSettings(), layout: nil, aacEncoder: "aac_at")

        XCTAssertEqual(decision.plan, .encode(AACEncoding(encoder: "aac_at", bitrate: 192, channels: 2, sampleRate: 48_000)))
        let args = makeArguments(input: info, output: output, settings: EncodeSettings(), audio: decision.plan)
        XCTAssertTrue(args.containsConsecutive(["-ar", "48000"]))
        XCTAssertTrue(decision.note?.contains("48 kHz") ?? false, decision.note ?? "")
    }

    func testAC3CopiedIntoMOVGetsAppleTag() {
        // TS の AC-3 を MOV にコピーすると、ffmpeg はタグを "AC-3" にし、Apple 製アプリで鳴らない。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/00000.MTS"), audioCodec: "ac3")
        var mov = EncodeSettings()
        mov.container = .mov
        XCTAssertTrue(makeArguments(input: info, output: output, settings: mov).containsConsecutive(["-tag:a", "ac-3"]))
        XCTAssertFalse(makeArguments(input: info, output: output, settings: EncodeSettings()).contains("-tag:a"), "MP4 では ffmpeg が ac-3 を付ける")
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

        XCTAssertTrue(args.containsConsecutive(["-map", "0:1", "-c", "copy"]))
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

    func testCopyingHEVCIntoMP4GetsHvc1Tag() {
        // HEVC の素材を詰め替えると、ffmpeg は既定で hev1 を書き、QuickTime で再生できない。
        let info = TestFixtures.mediaInfo(url: URL(fileURLWithPath: "/tmp/movie.mkv"), videoCodec: "hevc")
        var settings = EncodeSettings()
        settings.videoCodec = .copy
        let args = makeArguments(input: info, output: URL(fileURLWithPath: "/tmp/out.mp4.partial"), settings: settings)

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
