import Foundation

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
        onStandardOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let lineSplitter = LineSplitter(onLine: onStandardOutputLine)
        return try await runStreamingData(
            executable: executable,
            arguments: arguments,
            onStandardOutput: { lineSplitter.append($0) },
            onEndOfStandardOutput: { lineSplitter.flushRemainder() }
        )
    }

    /// プロセスを起動し、標準出力をバイト列のまま、読めた分ずつコールバックしながら実行する。
    ///
    /// 音声のビットストリームのような大きなバイナリを、全部メモリに溜めずに流し読みするために使う。
    /// キャンセルと標準エラーの扱いは `runStreaming(executable:arguments:onStandardOutputLine:)` と同じ。
    /// `onEndOfStandardOutput` は標準出力が閉じたときに1回だけ呼ばれる。
    static func runStreamingData(
        executable: URL,
        arguments: [String],
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onEndOfStandardOutput: @escaping @Sendable () -> Void = {}
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessRunnerError.notExecutable(executable)
        }
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

    /// デバッグ用に、実行するコマンドを 1 行の文字列にする。
    /// ターミナルへそのまま貼って再現できるよう、空白を含む引数はクォートする。
    static func commandLine(executable: URL, arguments: [String]) -> String {
        let quoted = arguments.map { arg -> String in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }
        return ([executable.path] + quoted).joined(separator: " ")
    }
}
