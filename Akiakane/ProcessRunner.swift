import Foundation
import os

/// 外部プロセスの実行結果。
struct ProcessResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var stdoutText: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderrText: String { String(decoding: standardError, as: UTF8.self) }
    var isSuccess: Bool { terminationStatus == 0 }

    /// 標準エラーの末尾を、エラー表示用に切り出す。
    func stderrTail(lines: Int = 12) -> String {
        let all = stderrText.split(separator: "\n", omittingEmptySubsequences: true)
        return all.suffix(lines).joined(separator: "\n")
    }
}

enum ProcessRunnerError: LocalizedError {
    case notExecutable(URL)
    case launchFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let url):
            return "実行できるファイルがありません: \(url.path)"
        case .launchFailed(let url, let underlying):
            return "\(url.lastPathComponent) を起動できませんでした: \(underlying.localizedDescription)"
        }
    }
}

/// 標準出力のチャンクを行単位に分割する箱。
/// チャンクの途中で行が切れることがあるため、改行が来るまでバッファに溜める。
/// 読み取りスレッドから呼ばれるため、既定の MainActor 分離から外す。
nonisolated private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        let lines = extractCompleteLines()
        lock.unlock()
        for line in lines { onLine(line) }
    }

    /// プロセス終了時に、末尾の改行なしで残っている分を最後の1行として流す。
    func flushRemainder() {
        lock.lock()
        let remainder = buffer
        buffer.removeAll()
        lock.unlock()
        guard !remainder.isEmpty, let text = String(data: remainder, encoding: .utf8), !text.isEmpty else { return }
        onLine(text)
    }

    private func extractCompleteLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            if let text = String(data: lineData, encoding: .utf8) {
                lines.append(text)
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}

/// 標準出力・標準エラーをスレッドセーフに溜める箱。
/// 読み取りスレッドから呼ばれるため、既定の MainActor 分離から外す。
nonisolated private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendStandardOutput(_ data: Data) {
        lock.lock(); out.append(data); lock.unlock()
    }

    func appendStandardError(_ data: Data) {
        lock.lock(); err.append(data); lock.unlock()
    }

    var standardOutput: Data {
        lock.lock(); defer { lock.unlock() }
        return out
    }

    var standardError: Data {
        lock.lock(); defer { lock.unlock() }
        return err
    }
}

enum ProcessRunner {

    /// プロセスを起動し、終了して出力を読み切るまで待って結果を返す。
    ///
    /// パイプは 64KB 程度でいっぱいになるため、待っている間も読み続けないと
    /// 出力の多いプロセスがブロックして永久に終わらなくなる。
    /// stdout / stderr / プロセス終了の 3 つを DispatchGroup で待ち合わせている。
    static func run(executable: URL, arguments: [String]) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessRunnerError.notExecutable(executable)
        }
        logCommand(executable: executable, arguments: arguments)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector()
        let group = DispatchGroup()

        group.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                collector.appendStandardOutput(chunk)
            }
        }

        group.enter()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                collector.appendStandardError(chunk)
            }
        }

        group.enter()
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            // 起動に失敗した場合は待ち合わせを組む前に抜ける。
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw ProcessRunnerError.launchFailed(executable, underlying: error)
        }

        return await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume(
                    returning: ProcessResult(
                        terminationStatus: process.terminationStatus,
                        standardOutput: collector.standardOutput,
                        standardError: collector.standardError
                    )
                )
            }
        }
    }

    /// プロセスを起動し、標準出力を1行ずつコールバックしながら実行する。
    ///
    /// `Task` がキャンセルされると `process.terminate()` を呼び、プロセスの終了を
    /// 待ってから `CancellationError` を投げる。標準エラーは `run(executable:arguments:)`
    /// と同様に全体を溜めて `ProcessResult` で返す（`standardOutput` は空のまま）。
    static func runStreaming(
        executable: URL,
        arguments: [String],
        onLaunch: (Int32) -> Void = { _ in },
        onStandardOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let lineSplitter = LineSplitter(onLine: onStandardOutputLine)
        return try await runStreamingData(
            executable: executable,
            arguments: arguments,
            onLaunch: onLaunch,
            onStandardOutput: { lineSplitter.append($0) },
            onEndOfStandardOutput: { lineSplitter.flushRemainder() }
        )
    }

    /// プロセスを起動し、標準出力をバイト列のまま、読めた分ずつコールバックしながら実行する。
    ///
    /// 音声のビットストリームのような大きなバイナリを、全部メモリに溜めずに流し読みするために使う。
    /// キャンセルと標準エラーの扱いは `runStreaming(executable:arguments:onStandardOutputLine:)` と同じ。
    /// `onEndOfStandardOutput` は標準出力が閉じたときに1回だけ呼ばれる。
    /// `onLaunch` は起動した直後に、プロセス ID を渡して呼ばれる。
    static func runStreamingData(
        executable: URL,
        arguments: [String],
        onLaunch: (Int32) -> Void = { _ in },
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onEndOfStandardOutput: @escaping @Sendable () -> Void = {}
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessRunnerError.notExecutable(executable)
        }
        logCommand(executable: executable, arguments: arguments)
        // 既にキャンセルされていれば、プロセスを起動しない。
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector()
        let group = DispatchGroup()

        group.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                onEndOfStandardOutput()
                group.leave()
            } else {
                onStandardOutput(chunk)
            }
        }

        group.enter()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                collector.appendStandardError(chunk)
            }
        }

        group.enter()
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw ProcessRunnerError.launchFailed(executable, underlying: error)
        }
        onLaunch(process.processIdentifier)

        let result = await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    group.notify(queue: .global(qos: .userInitiated)) {
                        continuation.resume(
                            returning: ProcessResult(
                                terminationStatus: process.terminationStatus,
                                standardOutput: Data(),
                                standardError: collector.standardError
                            )
                        )
                    }
                }
            },
            onCancel: {
                process.terminate()
            }
        )

        // notify のクロージャは Swift のタスクの外（GCD のキュー）で動くため、そこで
        // Task.isCancelled を見ても常に false になる。プロセスの終了を待ったあと、
        // タスクに戻ってから確認する。ffmpeg は SIGTERM を受けると終了コード 255 で終わるので、
        // ここで確認しないとキャンセルが「失敗」として扱われる。
        try Task.checkCancellation()
        return result
    }

    /// 実行したコマンドを残すロガー。Release 版でも Console.app や `log show` で見られる。
    nonisolated static let commandLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Akiakane", category: "command")

    /// 実行するコマンドの全文をログに残す。GUI で組んだ設定がどのコマンドになったかを確かめ、
    /// ターミナルで再現できるようにするため、プロセスを起動する前に必ず呼ぶ。
    /// 統合ログは1件あたり約 1KB で切り詰めるので、全文は `CommandLogFile` にも書く。
    static func logCommand(executable: URL, arguments: [String]) {
        let line = commandLine(executable: executable, arguments: arguments)
        commandLogger.notice("\(line, privacy: .public)")
        CommandLogFile.append(line)
    }

    /// 実行するコマンドを 1 行の文字列にする。zsh / bash にそのまま貼って再現できるよう、必要な引数をクォートする。
    static func commandLine(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// シェルで特別な意味を持つ文字を含む引数を、シングルクォートで囲む。
    ///
    /// 放送録画のファイル名によくある `[字]` は zsh のグロブになり、`$` や `` ` `` は展開される。
    /// シングルクォートの中では何も展開されないので、引数に含まれる `'` だけを `'\''` に置き換える。
    /// 日本語などの ASCII 以外の文字も、念のためクォートする。
    nonisolated static func shellQuoted(_ argument: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-".unicodeScalars)
        // `=` で始まる語は zsh が実行ファイルのパスに展開する（EQUALS オプション）。
        if !argument.isEmpty, !argument.hasPrefix("="), argument.unicodeScalars.allSatisfy(safe.contains) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 実行したコマンドの全文を `~/Library/Logs/Akiakane/commands.log` に追記する。
///
/// 統合ログは1件あたり約 1KB で切り詰めるので、長い番組名や深い NAS のパスでは、出力先などの末尾が消えた。
/// ファイルなら全文が残り、コマンドの行をそのままターミナルに貼れる。Console.app の「ログレポート」からも見られる。
/// 同じアプリのほかのインスタンスと同時に書いても行が混ざらないよう、O_APPEND で1回の write で書く。
nonisolated enum CommandLogFile {

    static let url: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/Akiakane/commands.log")

    /// これを超えたら `commands.log.1` に移して、新しく書き始める。
    private static let maxSize = 10 * 1024 * 1024
    private static let lock = NSLock()

    static func append(_ commandLine: String) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
            let previous = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: url, to: previous)
        }

        // 時刻は別の行にする。コマンドの行だけを選んで貼れるように。
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let entry = Data("[\(stamp)]\n\(commandLine)\n".utf8)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        entry.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
    }
}
