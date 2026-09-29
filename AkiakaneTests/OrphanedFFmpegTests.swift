import XCTest
@testable import Akiakane

/// `OrphanedFFmpeg` のテスト。ffmpeg の代わりに `/bin/sleep` を起動し、取り残されたプロセスとして扱う。
final class OrphanedFFmpegTests: XCTestCase {

    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var launched: [Process] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanedFFmpegTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "AkiakaneTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        for process in launched where process.isRunning { process.terminate() }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch(_ executable: URL = URL(fileURLWithPath: "/bin/sleep")) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        launched.append(process)
        return process
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
    }

    /// ffmpeg の記録を作る。`ownerIsAlive` が false なら、記録を書いたアプリはもう終わっている扱いにする。
    private func record(
        for process: Process, partial: URL, startTime: UInt64? = nil, ownerIsAlive: Bool, ownerTag: Int32 = 1
    ) throws -> OrphanedFFmpeg.Record {
        let pid = process.processIdentifier
        return OrphanedFFmpeg.Record(
            pid: pid,
            startTime: try startTime ?? XCTUnwrap(OrphanedFFmpeg.startTime(of: pid)),
            executablePath: try XCTUnwrap(OrphanedFFmpeg.executablePath(of: pid)),
            processName: try XCTUnwrap(OrphanedFFmpeg.processName(of: pid)),
            partialPath: partial.path,
            // 終わったアプリの代わりに、開始時刻が合わない launchd（PID 1）を持ち主にする。
            ownerPID: ownerIsAlive ? getpid() : ownerTag,
            ownerStartTime: ownerIsAlive ? try XCTUnwrap(OrphanedFFmpeg.startTime(of: getpid())) : 1
        )
    }

    private func partialFile(_ name: String = "rec_h265.mp4.1a2b3c4d.partial") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("half".utf8).write(to: url)
        return url
    }

    func testLeftoverProcessIsStoppedAndPartialFileRemoved() throws {
        let partial = try partialFile()
        let orphan = try launch()
        OrphanedFFmpeg.store(try record(for: orphan, partial: partial, ownerIsAlive: false), in: defaults)

        let cleaned = OrphanedFFmpeg.cleanUpLeftovers(defaults: defaults)

        XCTAssertEqual(cleaned.map(\.pid), [orphan.processIdentifier])
        waitForExit(orphan)
        XCTAssertFalse(orphan.isRunning, "取り残されたプロセスを止める")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "書きかけのファイルを消す")
        XCTAssertTrue(OrphanedFFmpeg.records(in: defaults).isEmpty)
    }

    func testFFmpegOfAnotherRunningInstanceIsLeftAlone() throws {
        // /Applications の Release 版が変換中に、Xcode から Debug 版を起動した場合など。記録を書いたアプリが動いている。
        let partial = try partialFile()
        let running = try launch()
        OrphanedFFmpeg.store(try record(for: running, partial: partial, ownerIsAlive: true), in: defaults)

        XCTAssertTrue(OrphanedFFmpeg.cleanUpLeftovers(defaults: defaults).isEmpty)

        usleep(200_000)
        XCTAssertTrue(running.isRunning, "ほかのインスタンスの変換を止めない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(OrphanedFFmpeg.records(in: defaults).count, 1, "記録はそのインスタンスのために残す")
    }

    func testDifferentProcessWithTheSamePIDIsNotStopped() throws {
        // PID は再利用される。開始時刻が記録と違えば別のプロセスなので、止めない。
        let unrelated = try launch()
        OrphanedFFmpeg.store(try record(for: unrelated, partial: try partialFile(), startTime: 1, ownerIsAlive: false), in: defaults)

        OrphanedFFmpeg.cleanUpLeftovers(defaults: defaults)

        usleep(200_000)
        XCTAssertTrue(unrelated.isRunning, "関係のないプロセスを止めない")
    }

    func testProcessIsFoundByNameWhenItsExecutableWasDeleted() throws {
        // 異常終了のあとで brew upgrade が古い ffmpeg を消すと、実行ファイルのパスが取れなくなる。
        let copy = folder.appendingPathComponent("fakeff")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: copy)
        let orphan = try launch(copy)
        let saved = try record(for: orphan, partial: try partialFile(), ownerIsAlive: false)
        try FileManager.default.removeItem(at: copy)
        OrphanedFFmpeg.store(saved, in: defaults)

        OrphanedFFmpeg.cleanUpLeftovers(defaults: defaults)

        waitForExit(orphan)
        XCTAssertFalse(orphan.isRunning)
    }

    func testOnlyPartialFilesAreEverDeleted() throws {
        // 記録が壊れていても、完成した出力やフォルダは消さない。
        let finished = folder.appendingPathComponent("rec_h265.mp4")
        try Data("done".utf8).write(to: finished)
        let directory = folder.appendingPathComponent("rec_h265.mp4.1a2b3c4d.partial")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertTrue(OrphanedFFmpeg.removePartialFile(atPath: finished.path))
        XCTAssertTrue(OrphanedFFmpeg.removePartialFile(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path), "完成した出力を消さない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), "フォルダを消さない")

        let partial = try partialFile("clip_h265.mp4.9f8e7d6c.partial")
        XCTAssertTrue(OrphanedFFmpeg.removePartialFile(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRecordAndClearOnlyTouchThisInstance() throws {
        let running = try launch()
        let other = try launch()
        let othersRecord = try record(for: other, partial: try partialFile(), ownerIsAlive: false, ownerTag: 1)
        OrphanedFFmpeg.store(othersRecord, in: defaults)

        OrphanedFFmpeg.record(pid: running.processIdentifier, partial: folder.appendingPathComponent("x.1a2b3c4d.partial"), defaults: defaults)
        XCTAssertEqual(OrphanedFFmpeg.records(in: defaults).count, 2, "インスタンスごとに別のキーに書く")

        OrphanedFFmpeg.clear(defaults: defaults)
        XCTAssertEqual(OrphanedFFmpeg.records(in: defaults), [othersRecord])
    }

    func testNothingHappensWithoutARecord() {
        XCTAssertTrue(OrphanedFFmpeg.cleanUpLeftovers(defaults: defaults).isEmpty)
    }
}
