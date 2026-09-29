import XCTest
@testable import Akiakane

/// `FFmpegRunner.encode` の完了処理のテスト。本物の ffmpeg の代わりに、同じ引数を受け取って
/// 出力（`.partial`）を書く小さなシェルスクリプトを実行ファイルとして渡す。
final class FFmpegRunnerTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FFmpegRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// 最後の引数（出力先の `.partial`）に書き込み、`stderr` を標準エラーに出して `exitCode` で終わる偽の ffmpeg。
    /// `writesOutput` が false なら何も書かない（走査のように出力先が `pipe:1` のとき）。
    private func fakeFFmpeg(stderr: String = "", exitCode: Int32 = 0, writesOutput: Bool = true) throws -> URL {
        let script = folder.appendingPathComponent("fake-ffmpeg")
        let body = """
        #!/bin/sh
        for last; do :; done
        printf '%s\\n' "$last" >> "\(folder.path)/received-outputs.txt"
        \(writesOutput ? "printf 'converted' > \"$last\"" : ":")
        printf '%s' '\(stderr)' >&2
        exit \(exitCode)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// フォルダに残っている書きかけのファイル。
    private func partialFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
    }

    /// 偽の ffmpeg が受け取った出力先（最後の引数）。
    private func receivedOutputs() throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent("received-outputs.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func encode(input: URL, output: URL, executable: URL) async throws {
        let info = TestFixtures.mediaInfo(url: input)
        try await FFmpegRunner(executableURL: executable)
            .encode(input: info, output: output, settings: EncodeSettings(), audio: .copy) { _ in }
    }

    func testSuccessfulRunRenamesPartialToFinalName() async throws {
        let input = folder.appendingPathComponent("rec.ts")
        try Data("original".utf8).write(to: input)
        let output = folder.appendingPathComponent("rec_h265.mp4")

        try await encode(input: input, output: output, executable: fakeFFmpeg())

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "converted")
        XCTAssertEqual(try partialFiles(), [], "書きかけのファイルを残さない")
    }

    func testPartialNameIsUniquePerRun() async throws {
        // 取り残された ffmpeg と同じ書きかけのファイルに、次の変換が書き込まないようにする。
        let input = folder.appendingPathComponent("rec.ts")
        try Data("original".utf8).write(to: input)
        let output = folder.appendingPathComponent("rec_h265.mp4")
        let executable = try fakeFFmpeg()

        try await encode(input: input, output: output, executable: executable)
        try FileManager.default.removeItem(at: output)
        try await encode(input: input, output: output, executable: executable)

        let received = try receivedOutputs().map { URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertEqual(received.count, 2)
        XCTAssertNotEqual(received[0], received[1])
        for name in received {
            XCTAssertTrue(name.hasPrefix("rec_h265.mp4.") && name.hasSuffix(".partial"), name)
        }
    }

    func testOutputThatIsTheInputIsRefusedAndInputIsKept() async throws {
        // 大文字小文字を区別しない APFS では、CLIP.MP4 と CLIP.mp4 は同じファイル。
        let caseSensitive = try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        try XCTSkipIf(caseSensitive == true, "一時フォルダのボリュームが大文字小文字を区別するので、2つは別のファイルになる")
        let input = folder.appendingPathComponent("CLIP.MP4")
        try Data("original".utf8).write(to: input)
        let output = folder.appendingPathComponent("CLIP.mp4")

        do {
            try await encode(input: input, output: output, executable: fakeFFmpeg())
            XCTFail("入力と同じファイルへの出力を止めなかった")
        } catch let error as FFmpegRunnerError {
            guard case .outputIsInput = error else { return XCTFail("別のエラー: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), "original", "入力ファイルは変更しない")
    }

    func testReadErrorWithExitCodeZeroIsReportedAsFailure() async throws {
        // NAS の切断などで入力が読めなくなっても、ffmpeg は途中までの出力を確定させて終了コード 0 で終わる。
        let input = folder.appendingPathComponent("rec.ts")
        try Data("original".utf8).write(to: input)
        let output = folder.appendingPathComponent("rec_h265.mp4")
        let executable = try fakeFFmpeg(stderr: "[in#0/mpegts @ 0x600000] Error during demuxing: Input/output error")

        do {
            try await encode(input: input, output: output, executable: executable)
            XCTFail("読み取りエラーを完了扱いにした")
        } catch let error as FFmpegRunnerError {
            guard case .inputReadFailed = error else { return XCTFail("別のエラー: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "途中までの出力を正式な名前にしない")
        XCTAssertEqual(try partialFiles(), [], "書きかけのファイルを残さない")
    }

    func testReadErrorKeepsExistingOutputWhenOverwriting() async throws {
        // 「上書きする」で既存の出力があるとき、読み取りエラーなら既存の出力を消さない。
        let input = folder.appendingPathComponent("rec.ts")
        try Data("original".utf8).write(to: input)
        let output = folder.appendingPathComponent("rec_h265.mp4")
        try Data("previous".utf8).write(to: output)
        let executable = try fakeFFmpeg(stderr: "[in#0/mpegts @ 0x600000] Error during demuxing: Operation timed out")

        do {
            try await encode(input: input, output: output, executable: executable)
            XCTFail("読み取りエラーを完了扱いにした")
        } catch let error as FFmpegRunnerError {
            guard case .inputReadFailed = error else { return XCTFail("別のエラー: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "previous")
    }

    func testReadErrorDuringAudioScanStopsTheScan() async throws {
        let input = folder.appendingPathComponent("rec.ts")
        try Data("original".utf8).write(to: input)
        let executable = try fakeFFmpeg(stderr: "[in#0/mpegts @ 0x600000] Error during demuxing: Input/output error", writesOutput: false)

        do {
            _ = try await AudioLayoutScanner(executableURL: executable).scan(TestFixtures.mediaInfo(url: input))
            XCTFail("読み取りエラーのまま走査を終えた")
        } catch let error as FFmpegRunnerError {
            guard case .inputReadFailed = error else { return XCTFail("別のエラー: \(error)") }
        }
    }

    // MARK: - 標準エラーの読み方

    func testDemuxingErrorIsDetected() {
        let stderr = """
        [h264 @ 0x1] error while decoding MB 12 34, bytestream -5
        [in#0/mpegts @ 0x2] Error during demuxing: Input/output error
        """
        XCTAssertEqual(inputReadError(inFFmpegStandardError: stderr), "[in#0/mpegts @ 0x2] Error during demuxing: Input/output error")
    }

    func testDecoderErrorsFromReceptionDropsAreNotReadErrors() {
        // 受信エラーのある放送 TS では、デコーダのエラーが出ても最後まで読める。
        let stderr = """
        [h264 @ 0x1] error while decoding MB 12 34, bytestream -5
        [aac @ 0x3] channel element 1.0 is not allocated
        [mpegts @ 0x4] PES packet size mismatch
        """
        XCTAssertNil(inputReadError(inFFmpegStandardError: stderr))
    }

    func testDeviceErrorsAndCorruptFilesAreToldApart() {
        // NAS の切断はつなぎ直せば直るが、壊れたファイルは再試行しても直らないので、案内を分ける。
        let timeout = inputReadFailure(inFFmpegStandardError: "[in#0/mpegts @ 0x1] Error during demuxing: Operation timed out", fileName: "rec.ts")
        guard case .inputReadFailed = timeout else { return XCTFail("\(String(describing: timeout))") }

        let corrupt = inputReadFailure(inFFmpegStandardError: "[in#0/avi @ 0x1] Error during demuxing: Cannot allocate memory", fileName: "clip.avi")
        guard case .inputCorrupted = corrupt else { return XCTFail("\(String(describing: corrupt))") }

        XCTAssertNil(inputReadFailure(inFFmpegStandardError: "[h264 @ 0x1] error while decoding MB 1 2", fileName: "rec.ts"))
    }
}
