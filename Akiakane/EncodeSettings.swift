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
            case .copy: return "コピー（必要なときだけ AAC に変換）"
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

    /// 選んだビットレートはステレオを基準にする。チャンネルあたりの割り当てが痩せないよう、
    /// 3〜6ch（5.1ch など）では2倍、7ch 以上（7.1ch など）では3倍にする（192 kbps → 384 / 576 kbps）。
    static func aacBitrate(base: Int, channels: Int?) -> Int {
        guard let channels, channels > 2 else { return base }
        return channels > 6 ? base * 3 : base * 2
    }

    /// 使うエンコーダ。Apple の aac_at は 7.1ch を扱えない（LFE を捨てて 7.0 にし、`-ac 8` を指定すると
    /// チャンネルの割り当てが崩れる）ので、8ch だけは ffmpeg 内蔵の aac にする。
    static func aacEncoder(preferred: String, channels: Int?) -> String {
        channels == 8 ? "aac" : preferred
    }

    /// aac_at は 48 kHz を超える音声（96 / 192 kHz）を受け付けず、起動直後に失敗する。
    static let maxAACSampleRate = 48_000
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

    /// この形式に、再エンコードせずにコピーできる音声コーデックか。
    ///
    /// MP4 / MOV は、ffmpeg が書けて Apple 製アプリで再生できるものに絞る。wmav2・pcm_u8・adpcm_ima_wav
    /// （古いデジカメの AVI）などは、MP4 に入れようとすると ffmpeg が起動直後に失敗する。
    /// MP3 は MP4 に書けても、Apple 製アプリは音声トラックごと無視する（MOV なら再生できる）。
    /// mp2 や DTS も、書けても Apple 製アプリでは鳴らない。
    /// MKV はほぼ何でも格納できるが、Blu-ray / DVD / 放送の LPCM と QuickTime の IMA4 は ffmpeg が書けない。
    func canCopyAudio(codecName: String) -> Bool {
        switch self {
        case .mkv: return !Self.mkvUnwritableAudio.contains(codecName)
        case .mp4: return Self.mp4CopyableAudio.contains(codecName)
        case .mov: return Self.movCopyableAudio.contains(codecName)
        }
    }

    /// そのままはコピーできないが、無劣化の PCM に変換すれば入る音声のとき、変換先のコーデック。
    /// Blu-ray（pcm_bluray）・DVD（pcm_dvd）・放送（s302m）の LPCM は、24 bit の PCM にすれば何も失わない。
    /// MP4 の PCM は Apple 製アプリで再生できるとは限らないので、MP4 では AAC にする。
    func losslessPCMCodec(for codecName: String) -> String? {
        guard self != .mp4, Self.convertibleLPCM.contains(codecName) else { return nil }
        return "pcm_s24le"
    }

    private static let mp4CopyableAudio: Set<String> = ["aac", "ac3", "eac3", "alac"]
    private static let movCopyableAudio: Set<String> = mp4CopyableAudio.union([
        "mp3", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f32be",
    ])
    private static let convertibleLPCM: Set<String> = ["pcm_bluray", "pcm_dvd", "s302m"]
    private static let mkvUnwritableAudio: Set<String> = convertibleLPCM.union(["adpcm_ima_qt"])
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
/// 出力が入力そのものになる場合（フォルダとコンテナが同じで接尾辞が空）は、
/// 入力を壊さないよう強制的に `_h265` を付ける。同じファイルかどうかは `sameFile` で判定し、
/// 既定では大文字小文字の違い（`CLIP.MP4` と `CLIP.mp4`）やシンボリックリンクも同じファイルとみなす。
func makeOutputPlan(
    for input: URL,
    encode: EncodeSettings,
    output: OutputSettings,
    fileExists: (URL) -> Bool,
    isReserved: (URL) -> Bool = { _ in false },
    sameFile: (URL, URL) -> Bool = refersToSameFile
) -> OutputPlan {
    let folder = output.destinationFolderURL ?? input.deletingLastPathComponent()
    var baseName = input.deletingPathExtension().lastPathComponent + output.suffix
    let ext = encode.container.fileExtension

    func candidate(_ name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension(ext)
    }

    if sameFile(candidate(baseName), input) {
        baseName += "_h265"
    }

    func renamed() -> OutputPlan {
        var counter = 2
        while true {
            let next = candidate("\(baseName) \(counter)")
            if !fileExists(next), !isReserved(next) { return .write(next) }
            counter += 1
        }
    }

    let first = candidate(baseName)
    guard fileExists(first) || isReserved(first) else { return .write(first) }
    // キューのほかの項目の入力や、このバッチで書き出した出力と重なるときは、設定にかかわらず別名にする。
    // 上書きすれば先の結果や元ファイルを消し、スキップすれば別の番組を変換しないまま終わってしまう。
    if isReserved(first) { return renamed() }

    switch output.existingFilePolicy {
    case .overwrite:
        return .write(first)
    case .skip:
        return .skip(existing: first)
    case .rename:
        return renamed()
    }
}

/// 2つの URL が同じファイルを指すか。
///
/// macOS 既定の APFS は大文字小文字を区別しないので、`CLIP.MP4` と `CLIP.mp4` は同じファイルになる。
/// 両方が実在すればファイルの実体（`fileResourceIdentifier`）で比べ、大文字小文字の違いや
/// シンボリックリンクも見抜く。どちらかが無ければ、パスを大文字小文字を無視して比べる。
/// 迷ったときは同じとみなす。別のファイルを同じとみなしても出力名に接尾辞が付くだけで、入力を失うことはない。
func refersToSameFile(_ a: URL, _ b: URL) -> Bool {
    // 同じディレクトリエントリなら、ファイル名は大文字小文字を除いて一致する。一致しなければ別のファイルとし、
    // ファイルシステムに問い合わせない（SwiftUI の描画中にも呼ばれるので、既定の設定で余計な stat をしない）。
    // 名前の違うハードリンクやシンボリックリンクは別物と判定されるが、削除されるのはリンクだけで、入力は残る。
    guard a.lastPathComponent.compare(b.lastPathComponent, options: .caseInsensitive) == .orderedSame else {
        return false
    }

    // URL はリソース値をキャッシュするので、作り直してから問い合わせる。
    let fresh = { (url: URL) in URL(fileURLWithPath: url.path) }
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey]
    if let valuesA = try? fresh(a).resourceValues(forKeys: keys),
       let valuesB = try? fresh(b).resourceValues(forKeys: keys),
       let idA = valuesA.fileResourceIdentifier,
       let idB = valuesB.fileResourceIdentifier {
        if idA.isEqual(idB) { return true }
        // 同じ共有を二重にマウントした場合や FUSE では、同じファイルが別の識別子で見える。
        // 名前に加えて大きさと更新日時まで同じなら、同じファイルとみなす。
        return valuesA.fileSize == valuesB.fileSize
            && valuesA.contentModificationDate == valuesB.contentModificationDate
    }

    // 親フォルダだけを解決して、最後の要素を付け直す。`resolvingSymlinksInPath` は実在するパスの
    // `/private` しか取り除かないので、パス全体を解決すると、実在するほうとしないほうで形が揃わない。
    let resolved = { (url: URL) in
        url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }
    return resolved(a).compare(resolved(b), options: .caseInsensitive) == .orderedSame
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

// MARK: - 入力の種類

/// `.ts` / `.m2ts` / `.mts` など、MPEG-TS 由来の入力かどうか。
/// aac_adtstoasc バイトストリームフィルタが必要かどうかと、音声の事前走査が必要かどうかの判定に使う。
private let mpegTransportStreamExtensions: Set<String> = ["ts", "m2ts", "mts"]

extension MediaInfo {
    var isMPEGTransportStream: Bool {
        mpegTransportStreamExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - 音声の扱い

/// 音声を実際にどう書き出すか。設定（`AudioMode`）と、変換前に調べた音声の構成から決める。
enum AudioPlan: Equatable, Sendable {
    /// 音声を含めない。
    case omit
    /// 再エンコードせずにコピーする。
    case copy
    /// AAC に再エンコードする。
    case encode(AACEncoding)
    /// 無劣化の PCM に変換する（コピーできない LPCM を MOV / MKV に入れるとき）。
    case pcm(codec: String)
}

struct AACEncoding: Equatable, Sendable {
    /// ffmpeg のエンコーダ名。`aac_at`（Apple の AudioToolbox）か `aac`（ffmpeg 内蔵）。
    var encoder: String
    /// kbps。
    var bitrate: Int
    /// 出力のチャンネル数。nil なら ffmpeg に任せる（最初のフレームの構成になる）。
    var channels: Int?
    /// 出力のサンプリング周波数。nil なら元のまま。
    var sampleRate: Int? = nil

    var displayName: String {
        let details = ["\(bitrate) kbps", sampleRate.map { "\($0 / 1000) kHz" }].compactMap { $0 }.joined(separator: "、")
        guard let channels else { return "AAC（\(details)）" }
        return "AAC \(AACFrameLayout.channelCountName(channels))（\(details)）"
    }
}

/// 音声の扱いと、それを利用者に伝えるための説明。
struct AudioDecision: Equatable, Sendable {
    let plan: AudioPlan
    /// 設定から素直に決まる扱いと違うときの説明。伝えることがなければ nil。
    let note: String?
}

/// 設定と音声の構成から、音声をどう書き出すかを決める。
///
/// `layout` は変換前に ADTS ヘッダを走査した結果（`AudioLayoutScanner`）で、MPEG-TS の AAC 以外では nil。
/// 放送 TS は録画の途中でチャンネル構成が変わる（CM はステレオ、本編は 5.1ch など）。
/// MP4 / MKV の AAC は構成を1つしか持てないので、コピーすると切り替え以降が再生できなくなる。
/// その場合だけ AAC に変換し、全体での最大チャンネル数を `-ac` で指定して 5.1ch を 5.1ch のまま保つ。
/// `-ac` を付けないと ffmpeg は最初のフレームの構成でエンコーダを作るため、
/// 冒頭がステレオの録画では本編の 5.1ch を黙ってステレオに落とす。
func makeAudioPlan(
    input: MediaInfo,
    settings: EncodeSettings,
    layout: AudioLayoutReport?,
    aacEncoder: String
) -> AudioDecision {
    guard let audio = input.primaryAudio else { return AudioDecision(plan: .omit, note: nil) }

    // 出力のチャンネル数は必ず明示する。走査の結果があれば全体での最大チャンネル数、なければ ffprobe が見た数。
    // `-ac` がないと、ffmpeg は最初のフレームの構成でエンコーダを作り（冒頭がステレオの録画では 5.1ch が落ちる）、
    // aac_at はレイアウトの交渉で 7.1ch を 7.0 に、2.1ch をステレオに落とす。
    let channels: Int? = layout.flatMap { layout in
        [layout.maxChannels, audio.channels].compactMap { $0 }.max()
    } ?? audio.channels

    func encoding(base: Int) -> AACEncoding {
        AACEncoding(
            encoder: AudioMode.aacEncoder(preferred: aacEncoder, channels: channels),
            bitrate: AudioMode.aacBitrate(base: base, channels: channels),
            channels: channels,
            sampleRate: audio.sampleRate.flatMap { $0 > AudioMode.maxAACSampleRate ? AudioMode.maxAACSampleRate : nil }
        )
    }

    switch settings.audioMode {
    case .none:
        return AudioDecision(plan: .omit, note: nil)

    case .copy:
        guard settings.container.canCopyAudio(codecName: audio.codecName) else {
            // 出力の形式に入らない音声は、コピーすると ffmpeg が失敗するか、Apple 製アプリで鳴らない。
            // そのファイルだけ、LPCM なら無劣化の PCM に、それ以外は AAC に変換する。
            if let pcm = settings.container.losslessPCMCodec(for: audio.codecName) {
                return AudioDecision(
                    plan: .pcm(codec: pcm),
                    note: "音声（\(audio.codecName)）は \(settings.container.displayName) にそのまま入れられないため、無劣化の PCM（\(pcm)）に変換する。"
                )
            }
            let fallback = encoding(base: AudioMode.defaultAACBitrate)
            return AudioDecision(
                plan: .encode(fallback),
                note: "音声（\(audio.codecName)）は \(settings.container.displayName) にそのまま入れられないため、\(fallback.displayName)に変換する。"
            )
        }
        guard let layout, layout.isUnsafeToCopy else { return AudioDecision(plan: .copy, note: nil) }
        let fallback = encoding(base: AudioMode.defaultAACBitrate)
        return AudioDecision(plan: .encode(fallback), note: copyFallbackNote(layout: layout, encoding: fallback))

    case .aac(let bitrate):
        let encoding = encoding(base: bitrate)
        var note: String?
        if let layout, layout.hasLayoutChange {
            note = layoutChangeDescription(layout)
                + "全体を\(encoding.displayName)で変換する。"
                + paddingNote(layout: layout, encoding: encoding)
        }
        return AudioDecision(plan: .encode(encoding), note: note)
    }
}

private func copyFallbackNote(layout: AudioLayoutReport, encoding: AACEncoding) -> String {
    guard layout.hasLayoutChange else {
        return "二か国語（デュアルモノ）の音声はコピーすると Apple 製のアプリで再生できないため、\(encoding.displayName)に変換する。主音声が左、副音声が右に入る。"
    }
    // 先頭の数フレームだけが違う（切り替えの直前から録画が始まった、先頭のフレームが壊れている、など）。
    if layout.leadingSegmentIsUnconfirmed, layout.segments.count == 2 {
        return "音声の先頭の数フレームだけ構成が違う。コピーすると全編が再生できなくなるため、\(encoding.displayName)に変換する。"
    }
    var note = layoutChangeDescription(layout)
        + "コピーすると切り替え以降が再生できなくなるため、\(encoding.displayName)に変換する。"
        + paddingNote(layout: layout, encoding: encoding)
    if layout.hasDualMono {
        note += "二か国語の区間は、主音声が左、副音声が右に入る。"
    }
    return note
}

private func layoutChangeDescription(_ layout: AudioLayoutReport) -> String {
    let layouts = layout.distinctLayouts
    let names = layouts.map(\.displayName)
    // チャンネル数が同じでサンプリング周波数などだけが変わるときは、名前では区別できない。
    guard Set(names).count == layouts.count else {
        return "音声の形式（サンプリング周波数など）が途中で変わる（切り替え \(layout.switchCount) 回）。"
    }
    return "音声のチャンネル構成が途中で変わる（\(names.joined(separator: "・"))、切り替え \(layout.switchCount) 回）。"
}

/// ステレオの区間を 5.1ch で変換すると、前方の左右に入り、残りのチャンネルは無音になる。
/// モノラルの区間をステレオで変換すると左右に同じ音が入るので、無音になるとは書かない。
private func paddingNote(layout: AudioLayoutReport, encoding: AACEncoding) -> String {
    guard let target = encoding.channels, target > 2,
          layout.segments.contains(where: { segment in
              guard let channels = segment.channels else { return false }
              return channels == 2 && channels < target
          }) else { return "" }
    return "ステレオの区間は前方の左右に入り、残りのチャンネルは無音になる。"
}

// MARK: - ffmpeg の引数

/// `MediaInfo` と `EncodeSettings` から ffmpeg の引数配列を組み立てる。
/// 副作用を持たない純粋関数にしてあるので、ffmpeg を起動せずにユニットテストできる。
///
/// `audio` は `makeAudioPlan` で決めた音声の扱い。省略すると、変換前の走査をしなかったものとして
/// 設定どおりに扱う（エンコーダは ffmpeg 内蔵の aac）。
func makeArguments(input: MediaInfo, output: URL, settings: EncodeSettings, audio: AudioPlan? = nil) -> [String] {
    let audio = audio ?? makeAudioPlan(input: input, settings: settings, layout: nil, aacEncoder: "aac").plan

    var arguments: [String] = ["-hide_banner", "-nostdin", "-y"]

    // -fflags は入力オプションなので -i より前に置く。.ts のタイムスタンプ不連続への対処。
    arguments += ["-fflags", "+genpts"]
    arguments += ["-i", input.url.path]

    let hasVideo = input.primaryVideo != nil
    let hasAudio = input.primaryAudio != nil && audio != .omit

    // ffprobe で解析したのと同じストリームを、ストリームの番号で指定する。`0:v:0` は映像の中での順番なので、
    // 静止画のストリームが本編より前にあると、解析したものとは別のストリームを変換してしまう。
    if let video = input.primaryVideo { arguments += ["-map", "0:\(video.index)"] }
    if hasAudio, let audio = input.primaryAudio { arguments += ["-map", "0:\(audio.index)"] }

    if hasVideo {
        arguments += videoArguments(settings: settings)
        if let filter = deinterlaceFilter(input: input, settings: settings) {
            arguments += ["-vf", filter]
        }
    }

    if hasAudio {
        arguments += audioArguments(audio)
        if needsAACBitstreamFilter(input: input, settings: settings, audio: audio) {
            arguments += ["-bsf:a", "aac_adtstoasc"]
        }
        // TS の AC-3 を MOV にコピーすると、ffmpeg はタグを "AC-3" にし、Apple 製アプリで鳴らない。
        // MP4 と同じ "ac-3" にすれば再生できる（E-AC-3 はそのままで再生できる）。
        if audio == .copy, settings.container == .mov, input.primaryAudio?.codecName == "ac3" {
            arguments += ["-tag:a", "ac-3"]
        }
    }

    if hasVideo, settings.container.isQuickTimeFamily,
       settings.videoCodec != .copy || input.primaryVideo?.codecName == "hevc" {
        // これがないと QuickTime や Apple 系デバイスで HEVC が再生できない。
        // HEVC の素材を映像コピーで詰め替える場合も、ffmpeg は既定で hev1 を書くので明示する。
        // H.264 のコピーに付けると失敗するので、HEVC のときだけにする。
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
        // deint=interlaced はインターレースとマークされたフレームしか処理しない。
        // マークのないインターレース素材こそ「常に解除する」を選ぶ場面なので、全フレームを処理させる。
        return "bwdif=mode=send_frame:parity=auto:deint=all"
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

private func audioArguments(_ audio: AudioPlan) -> [String] {
    switch audio {
    case .copy:
        return ["-c:a", "copy"]
    case .encode(let encoding):
        // 受信エラーなどで復号できなかったフレームは捨てられ、MP4 には長い duration の穴として残る。
        // AVFoundation はこの穴を詰めて鳴らすので、その分だけ音声が映像より先に進む。
        // タイムスタンプに合わせて無音を補い、同期を保つ。
        var arguments = ["-af", "aresample=async=1"]
        arguments += ["-c:a", encoding.encoder, "-b:a", "\(encoding.bitrate)k"]
        // aac_at は "5.1" というレイアウト名を受け付けない（"5.1(side)" なら通る）ので、
        // 名前ではなくチャンネル数で指定し、レイアウトの選択は ffmpeg に任せる。
        if let channels = encoding.channels {
            arguments += ["-ac", String(channels)]
        }
        if let sampleRate = encoding.sampleRate {
            arguments += ["-ar", String(sampleRate)]
        }
        return arguments
    case .pcm(let codec):
        return ["-c:a", codec]
    case .omit:
        return []
    }
}

/// .ts の AAC を MP4 / MOV へコピーする場合に必要なビットストリームフィルタか。
/// 近年の ffmpeg は自動で付けるが、明示しておく。AAC 以外（AVCHD の AC-3 など）に付けると、
/// ffmpeg が起動直後に失敗する。
private func needsAACBitstreamFilter(input: MediaInfo, settings: EncodeSettings, audio: AudioPlan) -> Bool {
    guard audio == .copy else { return false }
    guard settings.container.isQuickTimeFamily else { return false }
    return input.isMPEGTransportStream && input.primaryAudio?.codecName == "aac"
}
