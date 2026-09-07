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

/// 標準出力・標準エラーをスレッドセーフに溜める箱。
private final class OutputCollector: @unchecked Sendable {
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

    /// デバッグ用に、実行するコマンドを 1 行の文字列にする。
    /// ターミナルへそのまま貼って再現できるよう、空白を含む引数はクォートする。
    static func commandLine(executable: URL, arguments: [String]) -> String {
        let quoted = arguments.map { arg -> String in
            arg.contains(" ") ? "\"\(arg)\"" : arg
        }
        return ([executable.path] + quoted).joined(separator: " ")
    }
}
