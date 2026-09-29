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
