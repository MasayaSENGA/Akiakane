import Foundation
@testable import Akiakane

/// テスト用に `MediaInfo` を組み立てるヘルパー。
/// ffprobe を起動せず、`FFProbeReport` を直接構築して `MediaInfo` に渡す。
enum TestFixtures {

    static func stream(
        index: Int,
        codecName: String?,
        codecType: String,
        width: Int? = nil,
        height: Int? = nil,
        sampleAspectRatio: String? = nil,
        pixFmt: String? = nil,
        fieldOrder: String? = nil,
        avgFrameRate: String? = nil,
        sampleRate: String? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        duration: String? = nil,
        bitRate: String? = nil
    ) -> FFProbeReport.Stream {
        FFProbeReport.Stream(
            index: index,
            codecName: codecName,
            codecLongName: nil,
            codecType: codecType,
            width: width,
            height: height,
            codedWidth: nil,
            codedHeight: nil,
            sampleAspectRatio: sampleAspectRatio,
            displayAspectRatio: nil,
            pixFmt: pixFmt,
            fieldOrder: fieldOrder,
            rFrameRate: avgFrameRate,
            avgFrameRate: avgFrameRate,
            bitsPerRawSample: nil,
            sampleRate: sampleRate,
            channels: channels,
            channelLayout: channelLayout,
            duration: duration,
            bitRate: bitRate,
            tags: nil
        )
    }

    /// - Parameters:
    ///   - url: 入力ファイルの URL。拡張子で `.ts` 由来かどうかを判定する処理があるため、
    ///     テストしたい拡張子を明示的に渡す。
    ///   - durationSeconds: nil にすると `hasReliableDuration` が false になる。
    ///   - fieldOrder: ffprobe の `field_order` 値（"progressive" / "tt" / "bb" / nil で unknown）。
    ///   - includeAudio: 音声ストリームを含めるか。
    static func mediaInfo(
        url: URL,
        durationSeconds: Double? = 120,
        fieldOrder: String? = "progressive",
        includeAudio: Bool = true
    ) -> MediaInfo {
        var streams: [FFProbeReport.Stream] = [
            stream(
                index: 0,
                codecName: "hevc",
                codecType: "video",
                width: 1920,
                height: 1080,
                sampleAspectRatio: "1:1",
                pixFmt: "yuv420p",
                fieldOrder: fieldOrder,
                avgFrameRate: "30000/1001"
            )
        ]
        if includeAudio {
            streams.append(
                stream(
                    index: 1,
                    codecName: "aac",
                    codecType: "audio",
                    sampleRate: "48000",
                    channels: 2,
                    channelLayout: "stereo"
                )
            )
        }

        let format = FFProbeReport.Format(
            filename: url.path,
            nbStreams: streams.count,
            formatName: "mpegts",
            formatLongName: "MPEG-TS (MPEG-2 Transport Stream)",
            duration: durationSeconds.map { String($0) },
            size: nil,
            bitRate: nil
        )

        let report = FFProbeReport(format: format, streams: streams)
        return MediaInfo(url: url, report: report)
    }
}
