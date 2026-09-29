import XCTest
@testable import Akiakane

/// `ProcessRunner` のストリーミング版のテスト。macOS 標準のコマンドだけを使う。
final class ProcessRunnerTests: XCTestCase {

    func testCancellingStreamingRunThrowsCancellationError() async throws {
        // 以前は GCD のクロージャの中で Task.isCancelled を見ていたため、キャンセルしても
        // 非ゼロの終了コードが返り、変換が「失敗」として扱われていた。
        let task = Task {
            try await ProcessRunner.runStreaming(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            ) { _ in }
        }
        try await Task.sleep(for: .milliseconds(200))

        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("キャンセルしたのに結果が返った")
        } catch is CancellationError {
            // 期待どおり
        } catch {
            XCTFail("CancellationError 以外のエラー: \(error)")
        }
        XCTAssertLessThan(clock.now - start, .seconds(2), "プロセスを止めてから戻る")
    }

    func testStreamingDeliversEveryLineIncludingTheLastWithoutNewline() async throws {
        let collected = LineBox()
        let result = try await ProcessRunner.runStreaming(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["a\\nbb\\nlast"]
        ) { line in
            collected.append(line)
        }

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(collected.lines, ["a", "bb", "last"])
    }

    func testLoggedCommandLineReproducesArgumentsInZsh() async throws {
        // ログのコマンドをターミナルに貼って再現できること。実際に zsh に解釈させて、引数が元どおりに戻るかを見る。
        let arguments = [
            "-i", "/Volumes/Rec/[字][デ]ニュース 7時.ts", "a b", "$HOME", "it's", "!bang", "\"quoted\"", "*.ts",
            "~user", "=ls", "tab\there", "line\nbreak", "", "bwdif=mode=send_frame:parity=auto", "-map", "0:1", "+genpts",
        ]
        let quoted = arguments.map(ProcessRunner.shellQuoted).joined(separator: " ")
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", "printf '%s\\0' " + quoted]
        )

        XCTAssertTrue(result.isSuccess, result.stderrText)
        let parsed = result.stdoutText.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(parsed, arguments)
    }

    func testLongCommandIsKeptInFullInTheLogFile() throws {
        // 統合ログは約 1KB で切り詰めるので、全文はファイルにも残す。
        let marker = UUID().uuidString
        let longPath = "/Volumes/TVRecord/" + String(repeating: "とても長い番組名", count: 60) + "\(marker).ts"
        ProcessRunner.logCommand(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"), arguments: ["-i", longPath])

        let url = try XCTUnwrap(CommandLogFile.url)
        let log = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(log.split(separator: "\n").last { $0.contains(marker) })
        XCTAssertGreaterThan(line.utf8.count, 1024)
        XCTAssertEqual(String(line), ProcessRunner.commandLine(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"), arguments: ["-i", longPath]))
    }

    func testPlainArgumentsAreNotQuoted() {
        XCTAssertEqual(
            ProcessRunner.commandLine(executable: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), arguments: ["-c:v", "libx265", "-crf", "21"]),
            "/opt/homebrew/bin/ffmpeg -c:v libx265 -crf 21"
        )
    }

    func testStreamingDataDeliversRawBytes() async throws {
        let collected = LineBox()
        let result = try await ProcessRunner.runStreamingData(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["\\377\\361"],
            onStandardOutput: { collected.append(bytes: $0) },
            onEndOfStandardOutput: { collected.append("EOF") }
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(collected.bytes, Data([0xFF, 0xF1]))
        XCTAssertEqual(collected.lines, ["EOF"])
    }
}

/// パイプの読み取りスレッドから書き込まれるので、ロックで守る。
nonisolated private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLines: [String] = []
    private var storedBytes = Data()

    func append(_ line: String) {
        lock.lock(); storedLines.append(line); lock.unlock()
    }

    func append(bytes: Data) {
        lock.lock(); storedBytes.append(bytes); lock.unlock()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines
    }

    var bytes: Data {
        lock.lock(); defer { lock.unlock() }
        return storedBytes
    }
}
