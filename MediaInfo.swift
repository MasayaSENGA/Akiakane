import Foundation

// MARK: - ffprobe の文字列値を変換するヘルパー

enum FFProbeValue {

    static func double(_ string: String?) -> Double? {
        guard let string, let value = Double(string), value.isFinite else { return nil }
        return value
    }

    static func int(_ string: String?) -> Int? {
        guard let string else { return nil }
        return Int(string)
    }

    static func int64(_ string: String?) -> Int64? {
        guard let string else { return nil }
        return Int64(string)
    }

    /// "30000/1001" のような有理数表記を Double にする。
    /// 分母が 0（.ts で avg_frame_rate が "0/0" になる場合がある）なら nil。
    static func rational(_ string: String?) -> Double? {
        guard let string else { return nil }
        let parts = string.split(separator: "/")
        if parts.count == 2 {
            guard let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0 else { return nil }
            return numerator / denominator
        }
        return Double(string)
    }
}

// MARK: - フィールドオーダー

enum FieldOrder: Sendable {
    case progressive
    case topFieldFirst
    case bottomFieldFirst
    case unknown

    init(ffprobeValue: String?) {
        switch ffprobeValue {
        case "progressive":
            self = .progressive
        case "tt", "tb":
            self = .topFieldFirst
        case "bb", "bt":
            self = .bottomFieldFirst
        default:
            self = .unknown
        }
    }

    var isInterlaced: Bool {
        self == .topFieldFirst || self == .bottomFieldFirst
    }

    var displayName: String {
        switch self {
        case .progressive:      return "プログレッシブ"
        case .topFieldFirst:    return "インターレース（トップフィールドファースト）"
        case .bottomFieldFirst: return "インターレース（ボトムフィールドファースト）"
        case .unknown:          return "判定できません"
        }
    }
}

/// インターレース解除をどうするかの判断材料。
enum DeinterlaceAdvice: Sendable {
    case notNeeded
    case recommended(FieldOrder)
    case undetermined

    var displayName: String {
        switch self {
        case .notNeeded:
            return "解除は不要"
        case .recommended:
            return "bwdif での解除を推奨"
        case .undetermined:
            return "手動での確認が必要"
        }
    }
}

// MARK: - ストリーム

struct VideoStreamInfo: Identifiable, Sendable {
    let id = UUID()
    let index: Int
    let codecName: String
    let codecLongName: String?
    let width: Int
    let height: Int
    let pixelFormat: String?
    let frameRate: Double?
    let fieldOrder: FieldOrder
    let sampleAspectRatio: String?
    let displayAspectRatio: String?
    let bitDepth: Int?
    let bitRate: Int?

    init(stream: FFProbeReport.Stream) {
        index = stream.index
        codecName = stream.codecName ?? "unknown"
        codecLongName = stream.codecLongName
        width = stream.width ?? stream.codedWidth ?? 0
        height = stream.height ?? stream.codedHeight ?? 0
        pixelFormat = stream.pixFmt
        frameRate = FFProbeValue.rational(stream.avgFrameRate)
            ?? FFProbeValue.rational(stream.rFrameRate)
        fieldOrder = FieldOrder(ffprobeValue: stream.fieldOrder)
        sampleAspectRatio = stream.sampleAspectRatio
        displayAspectRatio = stream.displayAspectRatio
        bitDepth = FFProbeValue.int(stream.bitsPerRawSample)
            ?? VideoStreamInfo.bitDepth(fromPixelFormat: stream.pixFmt)
        bitRate = FFProbeValue.int(stream.bitRate)
    }

    var resolutionText: String { "\(width)×\(height)" }

    /// SAR が 1:1 でない、いわゆるアナモルフィック素材か。
    /// 1440×1080 の放送素材はここが 4:3 になる。リサイズ時に潰さないよう注意する。
    var isAnamorphic: Bool {
        guard let sar = sampleAspectRatio else { return false }
        return sar != "1:1" && sar != "0:1"
    }

    private static func bitDepth(fromPixelFormat pixelFormat: String?) -> Int? {
        guard let pixelFormat else { return nil }
        if pixelFormat.contains("p16") { return 16 }
        if pixelFormat.contains("p12") { return 12 }
        if pixelFormat.contains("p10") { return 10 }
        if pixelFormat.hasPrefix("yuv") || pixelFormat.hasPrefix("gbr") { return 8 }
        return nil
    }
}

struct AudioStreamInfo: Identifiable, Sendable {
    let id = UUID()
    let index: Int
    let codecName: String
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let bitRate: Int?
    let language: String?

    init(stream: FFProbeReport.Stream) {
        index = stream.index
        codecName = stream.codecName ?? "unknown"
        channels = stream.channels
        channelLayout = stream.channelLayout
        sampleRate = FFProbeValue.int(stream.sampleRate)
        bitRate = FFProbeValue.int(stream.bitRate)
        language = stream.tags?["language"] ?? stream.tags?["LANGUAGE"]
    }

    var channelText: String {
        if let channelLayout { return channelLayout }
        if let channels { return "\(channels)ch" }
        return "不明"
    }
}

// MARK: - ファイル全体のメタデータ

struct MediaInfo: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let containerName: String
    let duration: TimeInterval?
    let fileSize: Int64?
    let bitRate: Int?
    let videoStreams: [VideoStreamInfo]
    let audioStreams: [AudioStreamInfo]
    let subtitleStreamCount: Int
    let otherStreamCount: Int

    init(url: URL, report: FFProbeReport) {
        self.url = url

        let streams = report.streams ?? []
        var videos: [VideoStreamInfo] = []
        var audios: [AudioStreamInfo] = []
        var subtitles = 0
        var others = 0

        for stream in streams {
            switch stream.codecType {
            case "video":
                // 静止画（サムネイル・アルバムアート）は映像ストリームとして数えない。ffprobe は disposition で示す。
                // コーデック名で判定すると、Motion-JPEG の動画（古いデジカメの .avi / .mov）まで静止画扱いになり、
                // 映像のない出力を作ってしまう。
                if stream.disposition?.isStillImage == true {
                    others += 1
                } else {
                    videos.append(VideoStreamInfo(stream: stream))
                }
            case "audio":
                audios.append(AudioStreamInfo(stream: stream))
            case "subtitle":
                subtitles += 1
            default:
                others += 1
            }
        }

        self.videoStreams = videos
        self.audioStreams = audios
        self.subtitleStreamCount = subtitles
        self.otherStreamCount = others

        self.containerName = report.format?.formatLongName
            ?? report.format?.formatName
            ?? "不明"

        // .ts は format.duration が入っていないことも、値が不正確なこともある。
        // 取れなければ各ストリームの duration の最大値で代用する。
        self.duration = FFProbeValue.double(report.format?.duration)
            ?? streams.compactMap { FFProbeValue.double($0.duration) }.max()

        self.fileSize = FFProbeValue.int64(report.format?.size)
        self.bitRate = FFProbeValue.int(report.format?.bitRate)
    }

    var fileName: String { url.lastPathComponent }
    var primaryVideo: VideoStreamInfo? { videoStreams.first }
    var primaryAudio: AudioStreamInfo? { audioStreams.first }

    /// 進捗率の分母として duration を使えるか。
    /// ここが nil のファイルは、変換時に進捗率を出せない。
    var hasReliableDuration: Bool {
        guard let duration else { return false }
        return duration > 0
    }

    var deinterlaceAdvice: DeinterlaceAdvice {
        guard let video = primaryVideo else { return .notNeeded }
        switch video.fieldOrder {
        case .progressive:
            return .notNeeded
        case .topFieldFirst, .bottomFieldFirst:
            return .recommended(video.fieldOrder)
        case .unknown:
            return .undetermined
        }
    }
}

// MARK: - 表示用のフォーマット

extension MediaInfo {

    var durationText: String {
        guard let duration else { return "不明" }
        return MediaInfo.formatDuration(duration)
    }

    var fileSizeText: String {
        guard let fileSize else { return "不明" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var bitRateText: String {
        guard let bitRate else { return "不明" }
        return String(format: "%.1f Mbps", Double(bitRate) / 1_000_000)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
