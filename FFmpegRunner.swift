import Foundation

/// `-progress pipe:1` の1ブロック分から作る進捗情報。
struct EncodeProgress: Sendable, Equatable {
    let completed: TimeInterval
    let fraction: Double?
    let speed: Double?
    let estimatedRemaining: TimeInterval?
    let outputSize: Int64?
}

/// ffmpeg の `-progress` 出力（`key=value` 形式）をパースする。
///
/// `out_time_ms` は名前に反してマイクロ秒を返す（ffmpeg の既知の挙動）ため、
/// 混乱を避けて `out_time_us` だけを使い、無ければ `out_time`（HH:MM:SS.mmm）に
/// フォールバックする。副作用を持たない純粋関数にしてあるので、実際の ffmpeg を
/// 起動せず、`-progress` 出力を文字列リテラルとして与えるだけでテストできる。
nonisolated enum FFmpegProgressParser {

    /// `progress=continue` または `progress=end` で終わる1ブロック分の行を渡す。
    static func parseBlock(
        _ lines: [String],
        duration: TimeInterval?,
        hasReliableDuration: Bool
    ) -> EncodeProgress {
        var values: [String: String] = [:]
        for line in lines {
            guard let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separatorIndex])
            let value = String(line[line.index(after: separatorIndex)...])
            values[key] = value
        }

        let completed = completedSeconds(values: values) ?? 0
        let speed = parseSpeed(values["speed"])

        let fraction: Double?
        if hasReliableDuration, let duration, duration > 0 {
            fraction = min(max(completed / duration, 0), 1)
        } else {
            fraction = nil
        }

        let estimatedRemaining: TimeInterval?
        if let duration, let speed, speed > 0 {
            estimatedRemaining = max(duration - completed, 0) / speed
        } else {
            estimatedRemaining = nil
        }

        let outputSize = values["total_size"].flatMap { Int64($0) }

        return EncodeProgress(
            completed: completed,
            fraction: fraction,
            speed: speed,
            estimatedRemaining: estimatedRemaining,
            outputSize: outputSize
        )
    }

    private static func completedSeconds(values: [String: String]) -> TimeInterval? {
        if let microseconds = values["out_time_us"], let value = Double(microseconds) {
            return value / 1_000_000
        }
        if let text = values["out_time"] {
            return parseTimecode(text)
        }
        return nil
    }

    /// "HH:MM:SS.mmm" 形式をパースする。
    private static func parseTimecode(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// "1.23x" のような文字列。開始直後は "N/A" が来る。
    private static func parseSpeed(_ text: String?) -> Double? {
        guard var text, text != "N/A" else { return nil }
        if text.hasSuffix("x") { text.removeLast() }
        return Double(text)
    }
}

/// `-progress` の出力を1行ずつ受け取り、ブロックが完結するたびに `EncodeProgress` を作る。
/// `ProcessRunner.runStreaming` のコールバックは任意のスレッドから呼ばれるため、
/// 内部状態はロックで保護する。
nonisolated final class FFmpegProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLines: [String] = []
    private let duration: TimeInterval?
    private let hasReliableDuration: Bool

    init(duration: TimeInterval?, hasReliableDuration: Bool) {
        self.duration = duration
        self.hasReliableDuration = hasReliableDuration
    }

    func consume(_ line: String) -> EncodeProgress? {
        lock.lock()
        defer { lock.unlock() }

        guard !line.isEmpty else { return nil }
        pendingLines.append(line)

        guard line.hasPrefix("progress=") else { return nil }
        defer { pendingLines.removeAll(keepingCapacity: true) }

        return FFmpegProgressParser.parseBlock(
            pendingLines,
            duration: duration,
            hasReliableDuration: hasReliableDuration
        )
    }
}

enum FFmpegRunnerError: LocalizedError {
    case encodeFailed(fileName: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let fileName, let status, let message):
            let detail = message.isEmpty ? "詳細なメッセージはありません。" : message
            return "\(fileName) の変換に失敗しました（終了コード \(status)）。\n\(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .encodeFailed:
            return "入力ファイルが壊れていないか、必要なコーデックを ffmpeg がサポートしているか確認してください。"
        }
    }
}

struct FFmpegRunner {

    /// 実行ファイルを明示したいときに指定する。nil なら FFToolLocator が探す。
    var executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    /// AAC に変換するときのエンコーダを選ぶ。Apple の AudioToolbox（aac_at）が使えればそちらを優先する。
    /// 同じビットレートなら ffmpeg 内蔵の aac より音質が良い。Homebrew 版には入っているが、
    /// 別のビルドを指定された場合に備えて実際に問い合わせる。結果は実行ファイルごとに覚えておく。
    func preferredAACEncoder() async throws -> String {
        let executable = try executableURL ?? FFToolLocator.require(.ffmpeg)
        if let cached = Self.aacEncoderCache[executable.path] { return cached }

        let arguments = ["-hide_banner", "-h", "encoder=aac_at"]
        #if DEBUG
        print("[ffmpeg] " + ProcessRunner.commandLine(executable: executable, arguments: arguments))
        #endif
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments)

        // 存在しないエンコーダを問い合わせても終了コードは 0 なので、出力の見出しで判定する。
        let encoder = result.stdoutText.contains("Encoder aac_at") ? "aac_at" : "aac"
        Self.aacEncoderCache[executable.path] = encoder
        return encoder
    }

    private static var aacEncoderCache: [String: String] = [:]

    /// 1ファイルを変換する。`Task` をキャンセルすると ffmpeg を停止し、
    /// 書きかけの出力ファイルを削除してから `CancellationError` を投げる。
    /// `audio` は `makeAudioPlan` で決めた音声の扱い。
    func encode(
        input: MediaInfo,
        output: URL,
        settings: EncodeSettings,
        audio: AudioPlan,
        onProgress: @escaping @Sendable (EncodeProgress) -> Void
    ) async throws {
        let executable = try executableURL ?? FFToolLocator.require(.ffmpeg)
        let partialOutput = output.appendingPathExtension("partial")
        let arguments = makeArguments(input: input, output: partialOutput, settings: settings, audio: audio)

        #if DEBUG
        print("[ffmpeg] " + ProcessRunner.commandLine(executable: executable, arguments: arguments))
        #endif

        let accumulator = FFmpegProgressAccumulator(
            duration: input.duration,
            hasReliableDuration: input.hasReliableDuration
        )

        do {
            let result = try await ProcessRunner.runStreaming(
                executable: executable,
                arguments: arguments
            ) { line in
                if let progress = accumulator.consume(line) {
                    onProgress(progress)
                }
            }

            guard result.isSuccess else {
                try? FileManager.default.removeItem(at: partialOutput)
                throw FFmpegRunnerError.encodeFailed(
                    fileName: input.fileName,
                    status: result.terminationStatus,
                    message: result.stderrTail()
                )
            }

            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: partialOutput, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partialOutput)
            throw error
        }
    }
}
