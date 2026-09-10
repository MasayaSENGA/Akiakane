import Foundation

enum VideoCodec: String, Codable, CaseIterable, Sendable, Equatable {
    case libx265
    case hevcVideoToolbox
    case copy

    var displayName: String {
        switch self {
        case .libx265:           return "H.265（libx265・ソフトウェア）"
        case .hevcVideoToolbox:  return "H.265（VideoToolbox・ハードウェア）"
        case .copy:              return "再エンコードしない（映像をコピー）"
        }
    }
}

enum DeinterlaceMode: String, Codable, CaseIterable, Sendable, Equatable {
    case off
    case auto
    case force

    var displayName: String {
        switch self {
        case .off:   return "しない"
        case .auto:  return "素材から自動判定"
        case .force: return "常に解除する"
        }
    }
}

enum AudioMode: Codable, Sendable, Equatable {
    case copy
    case aac(bitrate: Int)
    case none

    /// UI のピッカーで選ぶ「種類」。ビットレートは別のコントロールで扱う。
    enum Kind: String, CaseIterable {
        case copy, aac, none

        var displayName: String {
            switch self {
            case .copy: return "コピー（再エンコードしない）"
            case .aac:  return "AAC に変換"
            case .none: return "音声を含めない"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .copy: return .copy
        case .aac:  return .aac
        case .none: return .none
        }
    }

    static let aacBitrateChoices = [128, 160, 192, 256, 320]
    static let defaultAACBitrate = 192
}

enum Container: String, Codable, CaseIterable, Sendable, Equatable {
    case mp4
    case mkv
    case mov

    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }

    /// ffmpeg の `-f` に渡すマクサ名。出力は `.partial` 付きの一時名で書くため、
    /// 拡張子からの自動判定に頼れない。明示しないと ffmpeg が起動時に失敗する。
    var ffmpegFormatName: String {
        switch self {
        case .mp4: return "mp4"
        case .mkv: return "matroska"
        case .mov: return "mov"
        }
    }

    /// QuickTime 系のコンテナか。`-tag:v hvc1` と `-movflags +faststart` が意味を持つのはこの2つ。
    var isQuickTimeFamily: Bool { self == .mp4 || self == .mov }
}

/// 変換設定。設定パネルから編集し、UserDefaults に保存する。
struct EncodeSettings: Codable, Sendable, Equatable {
    var videoCodec: VideoCodec = .libx265
    /// libx265 の CRF。小さいほど高画質・大容量。
    var crf: Int = 21
    /// hevc_videotoolbox の `-q:v`。1〜100 で、大きいほど高画質。CRF とは逆向きなので別に持つ。
    var videoToolboxQuality: Int = 65
    var preset: String = "slow"
    var deinterlace: DeinterlaceMode = .auto
    var audioMode: AudioMode = .copy
    var container: Container = .mp4

    /// x265 のプリセット。placebo は実用性がないので外している。
    static let presetChoices = [
        "ultrafast", "superfast", "veryfast", "faster", "fast",
        "medium", "slow", "slower", "veryslow"
    ]
}

// MARK: - 出力先と命名

enum ExistingFilePolicy: String, Codable, CaseIterable, Sendable, Equatable {
    case rename
    case overwrite
    case skip

    var displayName: String {
        switch self {
        case .rename:    return "別名で保存する"
        case .overwrite: return "上書きする"
        case .skip:      return "変換をスキップする"
        }
    }
}

/// 出力ファイルをどこに、どんな名前で書くか。
struct OutputSettings: Codable, Sendable, Equatable {
    /// nil なら入力と同じフォルダに書く。サンドボックスは無効なので、パス文字列で十分。
    var destinationFolderPath: String?
    /// 元のファイル名（拡張子なし）の後ろに付ける文字列。
    var suffix: String = "_h265"
    var existingFilePolicy: ExistingFilePolicy = .rename

    var destinationFolderURL: URL? {
        guard let destinationFolderPath, !destinationFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: destinationFolderPath, isDirectory: true)
    }
}

enum OutputPlan: Equatable {
    /// この URL に書く。
    case write(URL)
    /// 既に同名ファイルがあり、設定がスキップなので変換しない。
    case skip(existing: URL)
}

/// 入力ファイルと設定から出力先を決める。
///
/// 副作用を持たないよう、ファイルの存在確認は引数で渡す。
/// 出力が入力そのものと同じパスになる場合（拡張子・フォルダが同じで接尾辞が空）は、
/// 入力を壊さないよう強制的に `_h265` を付ける。
func makeOutputPlan(
    for input: URL,
    encode: EncodeSettings,
    output: OutputSettings,
    fileExists: (URL) -> Bool
) -> OutputPlan {
    let folder = output.destinationFolderURL ?? input.deletingLastPathComponent()
    var baseName = input.deletingPathExtension().lastPathComponent + output.suffix
    let ext = encode.container.fileExtension

    func candidate(_ name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension(ext)
    }

    if candidate(baseName).standardizedFileURL.path == input.standardizedFileURL.path {
        baseName += "_h265"
    }

    let first = candidate(baseName)
    guard fileExists(first) else { return .write(first) }

    switch output.existingFilePolicy {
    case .overwrite:
        return .write(first)
    case .skip:
        return .skip(existing: first)
    case .rename:
        var counter = 2
        while true {
            let next = candidate("\(baseName) \(counter)")
            if !fileExists(next) { return .write(next) }
            counter += 1
        }
    }
}

// MARK: - 永続化

/// 設定を UserDefaults に JSON で保存する。
/// 読み込みに失敗したら黙って既定値に戻す。設定が読めないだけでアプリが起動しないのは困る。
enum SettingsStore {
    private static let encodeKey = "EncodeSettings.v1"
    private static let outputKey = "OutputSettings.v1"

    static func loadEncodeSettings() -> EncodeSettings {
        load(EncodeSettings.self, key: encodeKey) ?? EncodeSettings()
    }

    static func loadOutputSettings() -> OutputSettings {
        load(OutputSettings.self, key: outputKey) ?? OutputSettings()
    }

    static func save(_ settings: EncodeSettings) {
        save(settings, key: encodeKey)
    }

    static func save(_ settings: OutputSettings) {
        save(settings, key: outputKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - ffmpeg の引数

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

    if hasVideo, settings.videoCodec != .copy, settings.container.isQuickTimeFamily {
        // これがないと QuickTime や Apple 系デバイスで HEVC が再生できない。
        arguments += ["-tag:v", "hvc1"]
    }

    if settings.container.isQuickTimeFamily {
        arguments += ["-movflags", "+faststart"]
    }

    arguments += ["-progress", "pipe:1", "-nostats", "-loglevel", "error"]
    arguments += ["-f", settings.container.ffmpegFormatName]
    arguments.append(output.path)

    return arguments
}

private func videoArguments(settings: EncodeSettings) -> [String] {
    switch settings.videoCodec {
    case .libx265:
        return ["-c:v", "libx265", "-crf", String(settings.crf), "-preset", settings.preset, "-pix_fmt", "yuv420p"]
    case .hevcVideoToolbox:
        // VideoToolbox の HEVC エンコーダは -crf を持たない。-q:v（1〜100、大きいほど高画質）で品質を指定する。
        return ["-c:v", "hevc_videotoolbox", "-q:v", String(settings.videoToolboxQuality), "-pix_fmt", "yuv420p"]
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
    guard settings.container.isQuickTimeFamily else { return false }
    return mpegTransportStreamExtensions.contains(input.url.pathExtension.lowercased())
}
