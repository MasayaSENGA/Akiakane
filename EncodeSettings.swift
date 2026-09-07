import Foundation

enum VideoCodec: Sendable, Equatable {
    case libx265
    case hevcVideoToolbox
    case copy
}

enum DeinterlaceMode: Sendable, Equatable {
    case off
    case auto
    case force
}

enum AudioMode: Sendable, Equatable {
    case copy
    case aac(bitrate: Int)
    case none
}

enum Container: String, Sendable, Equatable {
    case mp4
    case mkv
    case mov

    var fileExtension: String { rawValue }
}

/// 変換設定。今回のステップでは固定値のプリセットを1つ持てばよい。
struct EncodeSettings: Sendable, Equatable {
    var videoCodec: VideoCodec = .libx265
    var crf: Int = 21
    var preset: String = "slow"
    var deinterlace: DeinterlaceMode = .auto
    var audioMode: AudioMode = .copy
    var container: Container = .mp4
}

/// `.ts` / `.m2ts` / `.mts` など、MPEG-TS 由来の入力かどうか。
/// aac_adtstoasc バイトストリームフィルタが必要かどうかの判定に使う。
private let mpegTransportStreamExtensions: Set<String> = ["ts", "m2ts", "mts"]

/// `MediaInfo` と `EncodeSettings` から ffmpeg の引数配列を組み立てる。
/// 副作用を持たない純粋関数にしてあるので、ffmpeg を起動せずにユニットテストできる。
func makeArguments(input: MediaInfo, output: URL, settings: EncodeSettings) -> [String] {
    var arguments: [String] = ["-hide_banner", "-nostdin", "-y"]

    // -fflags は入力オプションなので -i より前に置く。.ts のタイムスタンプ不連続への対処。
    arguments += ["-fflags", "+genpts"]
    arguments += ["-i", input.url.path]

    let hasVideo = input.primaryVideo != nil
    let hasAudio = input.primaryAudio != nil && settings.audioMode != .none

    if hasVideo { arguments += ["-map", "0:v:0"] }
    if hasAudio { arguments += ["-map", "0:a:0"] }

    if hasVideo {
        arguments += videoArguments(settings: settings)
        if let filter = deinterlaceFilter(input: input, settings: settings) {
            arguments += ["-vf", filter]
        }
    }

    if hasAudio {
        arguments += audioArguments(settings: settings)
        if needsAACBitstreamFilter(input: input, settings: settings) {
            arguments += ["-bsf:a", "aac_adtstoasc"]
        }
    }

    if hasVideo, settings.videoCodec != .copy, settings.container == .mp4 || settings.container == .mov {
        // これがないと QuickTime や Apple 系デバイスで HEVC が再生できない。
        arguments += ["-tag:v", "hvc1"]
    }

    if settings.container == .mp4 || settings.container == .mov {
        arguments += ["-movflags", "+faststart"]
    }

    arguments += ["-progress", "pipe:1", "-nostats", "-loglevel", "error"]
    arguments.append(output.path)

    return arguments
}

private func videoArguments(settings: EncodeSettings) -> [String] {
    switch settings.videoCodec {
    case .libx265:
        return ["-c:v", "libx265", "-crf", String(settings.crf), "-preset", settings.preset, "-pix_fmt", "yuv420p"]
    case .hevcVideoToolbox:
        // VideoToolbox の HEVC エンコーダは -crf を持たない。-q:v で品質を指定する。
        return ["-c:v", "hevc_videotoolbox", "-q:v", String(settings.crf), "-pix_fmt", "yuv420p"]
    case .copy:
        return ["-c:v", "copy"]
    }
}

private func deinterlaceFilter(input: MediaInfo, settings: EncodeSettings) -> String? {
    guard settings.videoCodec != .copy else { return nil }

    switch settings.deinterlace {
    case .off:
        return nil
    case .force:
        return "bwdif=mode=send_frame:parity=auto:deint=interlaced"
    case .auto:
        switch input.deinterlaceAdvice {
        case .notNeeded:
            return nil
        case .recommended, .undetermined:
            // field_order が取れない素材（.undetermined）は、インターレースとマークされた
            // フレームだけを処理させる deint=interlaced を使う。
            return "bwdif=mode=send_frame:parity=auto:deint=interlaced"
        }
    }
}

private func audioArguments(settings: EncodeSettings) -> [String] {
    switch settings.audioMode {
    case .copy:
        return ["-c:a", "copy"]
    case .aac(let bitrate):
        return ["-c:a", "aac", "-b:a", "\(bitrate)k"]
    case .none:
        return []
    }
}

/// .ts から MP4 / MOV へ音声をコピーする場合に必要なビットストリームフィルタか。
/// 近年の ffmpeg は自動で付けるが、明示しておく。
private func needsAACBitstreamFilter(input: MediaInfo, settings: EncodeSettings) -> Bool {
    guard settings.audioMode == .copy else { return false }
    guard settings.container == .mp4 || settings.container == .mov else { return false }
    return mpegTransportStreamExtensions.contains(input.url.pathExtension.lowercased())
}
