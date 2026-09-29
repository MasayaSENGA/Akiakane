import Foundation

// MARK: - 音声構成の判定結果

/// ADTS フレーム1つ分の音声構成。
/// これが途中で変わると、MP4 / MKV の1つの AudioSpecificConfig では表せない。
nonisolated struct AACFrameLayout: Hashable, Sendable {
    /// ADTS の profile（オブジェクトタイプ − 1）。1 が AAC-LC。
    let profile: Int
    let samplingFrequencyIndex: Int
    /// ADTS ヘッダの channel_configuration（3ビット）。0 は PCE で定義された構成か、ARIB 式のデュアルモノ。
    let channelConfiguration: Int
    /// 実際のチャンネル数。判定できなければ nil。
    let channels: Int?
    /// 二か国語放送（デュアルモノ）。主音声と副音声が、別々のモノラルとして入っている。
    let isDualMono: Bool

    /// ARIB 式のデュアルモノ（channel_configuration 0、PCE なし）。
    /// ffmpeg 9 の aac デコーダは、ステレオなどの後にこの形式が来ると1フレームも復号できない。
    var isUndecodableByFFmpeg: Bool { isDualMono && channelConfiguration == 0 }
}

/// 第1音声ストリームを最後まで走査した結果。
nonisolated struct AudioLayoutReport: Equatable, Sendable {
    /// 読み取れた ADTS フレームの数。
    let frameCount: Int
    /// 構成を現れた順に並べたもの。同じ構成が続く間は1つにまとめる。
    /// 先頭のフレームは、続く区間と違っても必ず含める（`ADTSLayoutParser.finish()` を参照）。
    let segments: [AACFrameLayout]

    /// 途中で構成が切り替わるか。
    var hasLayoutChange: Bool { segments.count > 1 }

    var switchCount: Int { max(segments.count - 1, 0) }

    var hasDualMono: Bool { segments.contains(where: \.isDualMono) }

    /// 判定できた中で最大のチャンネル数。
    var maxChannels: Int? { segments.compactMap(\.channels).max() }

    /// そのままコピーすると、再生できない出力になるか。
    /// 構成が切り替わると切り替え以降が、デュアルモノは全体が、Apple のデコーダで再生できない。
    var isUnsafeToCopy: Bool { hasLayoutChange || hasDualMono }

    /// 現れた構成の種類を、重複を除いて現れた順に並べたもの。
    var distinctLayouts: [AACFrameLayout] {
        var seen = Set<AACFrameLayout>()
        return segments.filter { seen.insert($0).inserted }
    }

    /// 変換を続けてよい構成か確かめる。音声を失ったり、5.1ch を落としたりするおそれがあれば止める。
    func checkConvertible(fileName: String) throws {
        if segments.contains(where: \.isUndecodableByFFmpeg) {
            throw AudioLayoutError.undecodableDualMono(fileName: fileName)
        }
        // 構成が変わるなら再エンコードになる。チャンネル数の分からない区間があると、
        // `-ac` に渡す最大チャンネル数を決められず、5.1ch をステレオに落とすおそれがある。
        if isUnsafeToCopy, segments.contains(where: { $0.channels == nil }) {
            throw AudioLayoutError.undeterminedLayout(fileName: fileName)
        }
    }
}

enum AudioLayoutError: LocalizedError, Equatable {
    case undecodableDualMono(fileName: String)
    case undeterminedLayout(fileName: String)

    var errorDescription: String? {
        switch self {
        case .undecodableDualMono(let fileName):
            return "\(fileName) の音声に、ffmpeg で復号できない形式の二か国語（ARIB 式、channel_configuration 0）の区間があります。変換するとこの区間が無音になり、以降の音声もずれるため、変換を止めました。"
        case .undeterminedLayout(let fileName):
            return "\(fileName) の音声は途中でチャンネル構成が変わりますが、一部の区間のチャンネル数を判定できませんでした。5.1ch などを誤ってステレオに落とさないよう、変換を止めました。"
        }
    }

    var recoverySuggestion: String? {
        "音声が不要なら、設定の「音声」を「音声を含めない」にすると変換できます。"
    }
}

// MARK: - ADTS の解析

/// ffmpeg が書き出した ADTS のバイト列を流し読みして、フレームごとの音声構成を調べる。
///
/// 音声はデコードせず、各フレームのヘッダ（channel_configuration）と、先頭の構文要素だけを見る。
/// ステレオのはずのフレームに SCE（モノラル）が2つ並んでいればデュアルモノと分かる。
/// 壊れたフレームで切り替えを誤検出しないよう、次のフレームの先頭も ADTS ヘッダであることを確かめ、
/// 同じ構成が `confirmationFrames` 回続いたときだけ切り替えとして認める。
///
/// パイプの読み取りスレッドから呼ばれるため、既定の MainActor 分離から外し、状態はロックで守る。
nonisolated final class ADTSLayoutParser: @unchecked Sendable {

    static let confirmationFrames = 3

    private let lock = NSLock()
    private var buffer: [UInt8] = []
    /// `buffer` のここまでは処理済み。毎回詰め直すと遅いので、ある程度たまってから捨てる。
    private var position = 0
    private var frameCount = 0
    private var segments: [AACFrameLayout] = []
    private var candidate: AACFrameLayout?
    private var candidateRun = 0
    private var firstLayout: AACFrameLayout?
    /// 直前の PCE で定義されたチャンネル数。ffmpeg などは PCE を最初のフレームにしか書かず、
    /// 後続の channel_configuration 0 のフレームはその構成を引き継ぐ（デコーダと同じ扱い）。
    private var programConfigChannels: Int?

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: chunk)
        parseAvailableFrames(isFinal: false)
    }

    /// 標準出力が閉じたあとに呼ぶ。末尾の、次のヘッダで確かめられないフレームも数える。
    func finish() -> AudioLayoutReport {
        lock.lock()
        defer { lock.unlock() }
        parseAvailableFrames(isFinal: true)

        var result = segments
        // 確定に必要なフレーム数に満たない、ごく短い音声。
        if result.isEmpty, let candidate {
            result.append(candidate)
        }
        // コピーするとき、aac_adtstoasc は最初のフレームのヘッダから AudioSpecificConfig を作る。
        // 先頭の1〜2フレームだけ構成が違う（切り替えの直前から録画が始まった、など）と、
        // 確定前に捨てた構成で全編が書かれて再生できなくなる。先頭のフレームは必ず区間として残す。
        if let firstLayout, firstLayout != result.first {
            result.insert(firstLayout, at: 0)
        }
        return AudioLayoutReport(frameCount: frameCount, segments: result)
    }

    // MARK: フレームの切り出し

    private static let minimumHeaderLength = 7

    nonisolated private struct Header {
        let profile: Int
        let samplingFrequencyIndex: Int
        let channelConfiguration: Int
        let headerLength: Int
        let frameLength: Int
        let hasCRC: Bool
        let rawDataBlockCount: Int
    }

    private func parseAvailableFrames(isFinal: Bool) {
        let count = buffer.count
        buffer.withUnsafeBufferPointer { bytes in
            while position + Self.minimumHeaderLength <= count {
                guard let header = Self.header(in: bytes, at: position) else {
                    // 同期が外れている。1バイトずつずらして次のヘッダを探す。
                    position += 1
                    continue
                }
                let next = position + header.frameLength
                if next + Self.minimumHeaderLength <= count {
                    // 次のフレームの先頭もヘッダでなければ、偶然 0xFFF に見えただけとみなす。
                    guard Self.header(in: bytes, at: next) != nil else {
                        position += 1
                        continue
                    }
                } else if !(isFinal && next <= count) {
                    break  // 続きのデータを待つ。
                }
                record(layout(of: header, in: bytes, at: position))
                frameCount += 1
                position = next
            }
        }
        if position >= 1 << 20 || position >= buffer.count {
            buffer.removeFirst(min(position, buffer.count))
            position = 0
        }
    }

    /// `i` から始まる7バイトが、ADTS ヘッダとして妥当なら読み取る。
    private static func header(in b: UnsafeBufferPointer<UInt8>, at i: Int) -> Header? {
        guard i + minimumHeaderLength <= b.count else { return nil }
        // syncword（12ビットすべて 1）と layer（2ビット、常に 0）。
        guard b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
        let profile = Int(b[i + 2] >> 6)
        let samplingFrequencyIndex = Int((b[i + 2] >> 2) & 0x0F)
        // profile 3 は予約、サンプリング周波数の番号は 0〜12 だけが定義されている。
        guard profile != 3, samplingFrequencyIndex < 13 else { return nil }
        let hasCRC = b[i + 1] & 0x01 == 0
        let headerLength = hasCRC ? 9 : 7
        let frameLength = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | (Int(b[i + 5]) >> 5)
        guard frameLength > headerLength else { return nil }
        return Header(
            profile: profile,
            samplingFrequencyIndex: samplingFrequencyIndex,
            channelConfiguration: Int(((b[i + 2] & 0x01) << 2) | (b[i + 3] >> 6)),
            headerLength: headerLength,
            frameLength: frameLength,
            hasCRC: hasCRC,
            rawDataBlockCount: Int(b[i + 6] & 0x03) + 1
        )
    }

    private func record(_ layout: AACFrameLayout) {
        if firstLayout == nil { firstLayout = layout }
        if layout == segments.last {
            candidate = nil
            candidateRun = 0
            return
        }
        if layout == candidate {
            candidateRun += 1
        } else {
            candidate = layout
            candidateRun = 1
        }
        if candidateRun >= Self.confirmationFrames {
            segments.append(layout)
            candidate = nil
            candidateRun = 0
        }
    }

    // MARK: 構成の判定

    nonisolated private enum FirstElement: Equatable {
        case singleChannel          // SCE
        case channelPair            // CPE
        case programConfig(Int?)    // PCE。中で定義されたチャンネル数
        case other
    }

    private func layout(of header: Header, in b: UnsafeBufferPointer<UInt8>, at i: Int) -> AACFrameLayout {
        // CRC 付きで raw_data_block が複数あるフレームは、要素の位置を知るのに追加の解析が要る。
        // 放送では使われないので、ヘッダの channel_configuration だけで判定する。
        let element = header.hasCRC && header.rawDataBlockCount > 1
            ? nil
            : Self.firstElement(in: b, from: i + header.headerLength, to: i + header.frameLength)

        let channels: Int?
        var isDualMono = false
        switch header.channelConfiguration {
        case 0:
            switch element {
            case .programConfig(let count):
                programConfigChannels = count
                channels = count
            case .singleChannel where programConfigChannels == nil:
                // PCE を見ていないのに SCE で始まるのは、ARIB 式のデュアルモノ（SCE が2つ並ぶ）。
                channels = 2
                isDualMono = true
            default:
                // PCE を持たないフレームは、直前の PCE の構成を引き継ぐ。PCE を見ていなければ判定できない。
                channels = programConfigChannels
            }
        case 2:
            // 本来 CPE が来るところに SCE が並んでいれば、デュアルモノ。
            programConfigChannels = nil
            channels = 2
            isDualMono = element == .singleChannel
        case 7:
            programConfigChannels = nil
            channels = 8
        default:
            programConfigChannels = nil
            channels = header.channelConfiguration
        }

        return AACFrameLayout(
            profile: header.profile,
            samplingFrequencyIndex: header.samplingFrequencyIndex,
            channelConfiguration: header.channelConfiguration,
            channels: channels,
            isDualMono: isDualMono
        )
    }

    /// raw_data_block の先頭から、長さが明示される FIL / DSE を読み飛ばし、最初の音声要素を返す。
    private static func firstElement(in b: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> FirstElement? {
        var reader = BitReader(bytes: b, bit: start * 8, endBit: end * 8)
        for _ in 0..<16 {
            guard let id = reader.read(3) else { return nil }
            switch id {
            case 0:
                return .singleChannel
            case 1:
                return .channelPair
            case 5:
                return .programConfig(programConfigChannels(&reader))
            case 4:  // DSE
                guard reader.read(4) != nil,
                      let byteAlign = reader.read(1),
                      var count = reader.read(8) else { return nil }
                if count == 255 {
                    guard let escape = reader.read(8) else { return nil }
                    count += escape
                }
                if byteAlign == 1 { reader.alignToByte() }
                guard reader.skip(count * 8) else { return nil }
            case 6:  // FIL
                guard var count = reader.read(4) else { return nil }
                if count == 15 {
                    guard let escape = reader.read(8) else { return nil }
                    count += escape - 1
                }
                guard reader.skip(count * 8) else { return nil }
            default:
                return .other  // CCE / LFE / END
            }
        }
        return nil
    }

    /// program_config_element から出力チャンネル数を数える（ISO/IEC 14496-3 の 4.4.1.1）。
    private static func programConfigChannels(_ reader: inout BitReader) -> Int? {
        guard reader.skip(4 + 2 + 4),  // element_instance_tag, object_type, sampling_frequency_index
              let front = reader.read(4),
              let side = reader.read(4),
              let back = reader.read(4),
              let lfe = reader.read(2),
              reader.skip(3 + 4),      // num_assoc_data_elements, num_valid_cc_elements
              let mono = reader.read(1), mono == 0 || reader.skip(4),
              let stereo = reader.read(1), stereo == 0 || reader.skip(4),
              let matrix = reader.read(1), matrix == 0 || reader.skip(3)
        else { return nil }

        var channels = lfe
        for _ in 0..<(front + side + back) {
            guard let isChannelPair = reader.read(1), reader.skip(4) else { return nil }
            channels += isChannelPair == 1 ? 2 : 1
        }
        return channels > 0 ? channels : nil
    }

    nonisolated private struct BitReader {
        let bytes: UnsafeBufferPointer<UInt8>
        var bit: Int
        let endBit: Int

        mutating func read(_ count: Int) -> Int? {
            guard bit + count <= endBit else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((bytes[bit >> 3] >> (7 - UInt8(bit & 7))) & 1)
                bit += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool {
            guard bit + count <= endBit else { return false }
            bit += count
            return true
        }

        mutating func alignToByte() {
            bit = (bit + 7) & ~7
        }
    }
}

// MARK: - 走査の実行

enum AudioLayoutScanError: LocalizedError {
    case scanFailed(fileName: String, status: Int32, message: String)
    case unknownAudioFormat(fileName: String)
    case noFrames(fileName: String)

    var errorDescription: String? {
        switch self {
        case .scanFailed(let fileName, let status, let message):
            let detail = message.isEmpty ? "詳細なメッセージはありません。" : message
            return "\(fileName) の音声の構成を調べられませんでした（終了コード \(status)）。\n\(detail)"
        case .unknownAudioFormat(let fileName):
            return "\(fileName) の音声の形式を ffmpeg が判定できませんでした。冒頭から ARIB 式の二か国語音声（channel_configuration 0）になっている可能性があります。"
        case .noFrames(let fileName):
            return "\(fileName) の音声から AAC のフレームを読み取れませんでした。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .scanFailed, .noFrames:
            return "入力ファイルが壊れていないか、読み取れる場所にあるか確認してください。NAS などの一時的な読み取りエラーなら、「待機に戻す」で再試行できます。音声が不要なら、設定の「音声」を「音声を含めない」にすると変換できます。"
        case .unknownAudioFormat:
            return "音声が不要なら、設定の「音声」を「音声を含めない」にすると変換できます。"
        }
    }
}

/// 変換の前に、第1音声ストリームのチャンネル構成が途中で変わらないかを調べる。
///
/// 放送 TS は録画の途中で構成が変わる（CM はステレオ、本編は 5.1ch など）が、
/// ffprobe のストリーム情報は冒頭の構成しか示さない。そこで ffmpeg に音声をデコードせずに
/// 取り出させ、全フレームのヘッダを読む。読むのはファイル全体だが CPU はほとんど使わず、
/// 所要時間はディスクの読み出し速度で決まる。
struct AudioLayoutScanner {

    /// 実行ファイルを明示したいときに指定する。nil なら FFToolLocator が探す。
    var executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    /// この入力とこの設定で、変換の前に走査が必要か。
    /// 途中で構成を変えられるのは MPEG-TS の AAC（ADTS）だけで、MP4 などは構成が1つに決まっている。
    static func needsScan(input: MediaInfo, settings: EncodeSettings) -> Bool {
        guard settings.audioMode != .none, input.isMPEGTransportStream else { return false }
        return input.primaryAudio?.codecName == "aac"
    }

    /// 変換と同じ第1音声ストリーム（`-map 0:a:0`）を、加工せずに標準出力へ流す引数。
    /// `-f adts` は extradata からヘッダを書き直すことがあり、切り替えを隠すおそれがあるので、
    /// パケットをそのまま書き出す `-f data` を使う。
    static func arguments(for input: MediaInfo) -> [String] {
        [
            "-hide_banner", "-nostdin", "-loglevel", "error",
            "-i", input.url.path,
            "-map", "0:a:0", "-c", "copy",
            "-f", "data", "pipe:1"
        ]
    }

    func scan(_ input: MediaInfo) async throws -> AudioLayoutReport {
        let executable = try executableURL ?? FFToolLocator.require(.ffmpeg)
        let arguments = Self.arguments(for: input)

        #if DEBUG
        print("[ffmpeg] " + ProcessRunner.commandLine(executable: executable, arguments: arguments))
        #endif

        let parser = ADTSLayoutParser()
        let result = try await ProcessRunner.runStreamingData(
            executable: executable,
            arguments: arguments,
            onStandardOutput: { parser.append($0) }
        )

        // タイムスタンプの乱れ（non monotonically increasing dts）はエラーとして出るが、
        // データは欠けていない。標準エラーの有無ではなく、終了コードとフレーム数で判定する。
        guard result.isSuccess else {
            // ffprobe がサンプリング周波数を取れない音声は、-f data の書き出し準備で失敗する。
            if result.stderrText.contains("sample rate not set") {
                throw AudioLayoutScanError.unknownAudioFormat(fileName: input.fileName)
            }
            throw AudioLayoutScanError.scanFailed(
                fileName: input.fileName,
                status: result.terminationStatus,
                message: result.stderrTail()
            )
        }
        let report = parser.finish()
        guard report.frameCount > 0 else {
            throw AudioLayoutScanError.noFrames(fileName: input.fileName)
        }

        #if DEBUG
        print("[audio] \(input.fileName): \(report.frameCount) フレーム、構成 \(report.segments.map(\.displayName).joined(separator: " → "))")
        #endif

        return report
    }
}

// MARK: - 表示用

extension AACFrameLayout {

    var displayName: String {
        if isDualMono { return "二か国語" }
        guard let channels else { return "不明な構成" }
        // PCE で定義された 6ch は 6.0 などのこともあり、5.1ch とは限らない。
        if channelConfiguration == 0, channels > 2 { return "\(channels)ch" }
        return Self.channelCountName(channels)
    }

    static func channelCountName(_ channels: Int) -> String {
        switch channels {
        case 1: return "モノラル"
        case 2: return "ステレオ"
        case 6: return "5.1ch"
        case 8: return "7.1ch"
        default: return "\(channels)ch"
        }
    }
}
