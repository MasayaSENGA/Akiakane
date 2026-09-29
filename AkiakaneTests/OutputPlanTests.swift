import XCTest
@testable import Akiakane

final class OutputPlanTests: XCTestCase {

    private let input = URL(fileURLWithPath: "/Volumes/Rec/番組 第1話.ts")

    private func plan(
        encode: EncodeSettings = EncodeSettings(),
        output: OutputSettings = OutputSettings(),
        existing: Set<String> = []
    ) -> OutputPlan {
        makeOutputPlan(for: input, encode: encode, output: output) { existing.contains($0.path) }
    }

    func testDefaultWritesNextToInputWithSuffixAndContainerExtension() {
        XCTAssertEqual(plan(), .write(URL(fileURLWithPath: "/Volumes/Rec/番組 第1話_h265.mp4")))
    }

    func testDestinationFolderOverridesInputFolder() {
        var output = OutputSettings()
        output.destinationFolderPath = "/Volumes/Archive"
        XCTAssertEqual(plan(output: output), .write(URL(fileURLWithPath: "/Volumes/Archive/番組 第1話_h265.mp4")))
    }

    func testContainerChangesExtension() {
        var encode = EncodeSettings()
        encode.container = .mkv
        XCTAssertEqual(plan(encode: encode), .write(URL(fileURLWithPath: "/Volumes/Rec/番組 第1話_h265.mkv")))
    }

    func testEmptySuffixNeverOverwritesInputItself() {
        // 入力が .mp4 で、接尾辞なし・同じフォルダ・同じコンテナだと出力が入力と同じパスになる。
        let mp4Input = URL(fileURLWithPath: "/Volumes/Rec/movie.mp4")
        var output = OutputSettings()
        output.suffix = ""
        let result = makeOutputPlan(for: mp4Input, encode: EncodeSettings(), output: output) { _ in false }
        XCTAssertEqual(result, .write(URL(fileURLWithPath: "/Volumes/Rec/movie_h265.mp4")))
    }

    func testEmptySuffixNeverOverwritesInputWithUppercaseExtension() {
        // macOS 既定の APFS は大文字小文字を区別しない。CLIP.MP4 と CLIP.mp4 は同じファイルになる。
        let cameraClip = URL(fileURLWithPath: "/Volumes/Card/DCIM/CLIP.MP4")
        var output = OutputSettings()
        output.suffix = ""
        output.existingFilePolicy = .overwrite
        let result = makeOutputPlan(for: cameraClip, encode: EncodeSettings(), output: output) { _ in true }
        XCTAssertEqual(result, .write(URL(fileURLWithPath: "/Volumes/Card/DCIM/CLIP_h265.mp4")))
    }

    func testOverwriteNeverReplacesAnotherQueuedInputOrThisBatchOutput() {
        // 番組.ts と 番組.mp4（元の H.264）を接尾辞なしで変換すると、番組.ts の出力先が 番組.mp4 になる。
        let ts = URL(fileURLWithPath: "/Volumes/Rec/番組.ts")
        let otherInput = URL(fileURLWithPath: "/Volumes/Rec/番組.mp4")
        var output = OutputSettings()
        output.suffix = ""
        output.existingFilePolicy = .overwrite
        let result = makeOutputPlan(
            for: ts, encode: EncodeSettings(), output: output,
            fileExists: { $0.path == otherInput.path },
            isReserved: { $0.path == otherInput.path }
        )
        XCTAssertEqual(result, .write(URL(fileURLWithPath: "/Volumes/Rec/番組 2.mp4")))
    }

    func testReservedNameIsAvoidedEvenBeforeTheFileExists() {
        // 別のフォルダにある同名の録画を1つの保存先にまとめる。先の変換がまだ書き出し中でも、同じ名前にしない。
        var output = OutputSettings()
        output.destinationFolderPath = "/Volumes/Archive"
        let running = URL(fileURLWithPath: "/Volumes/Archive/番組 第1話_h265.mp4")
        let result = makeOutputPlan(
            for: input, encode: EncodeSettings(), output: output,
            fileExists: { _ in false },
            isReserved: { $0.path == running.path }
        )
        XCTAssertEqual(result, .write(URL(fileURLWithPath: "/Volumes/Archive/番組 第1話_h265 2.mp4")))
    }

    func testSkipPolicyStillRenamesWhenOnlyReserved() {
        // 別のフォルダにある同名の別の番組を1つの保存先にまとめる。スキップすると、その番組が変換されないまま終わる。
        var output = OutputSettings()
        output.destinationFolderPath = "/Volumes/Archive"
        output.existingFilePolicy = .skip
        let earlier = URL(fileURLWithPath: "/Volumes/Archive/番組 第1話_h265.mp4")
        let result = makeOutputPlan(
            for: input, encode: EncodeSettings(), output: output,
            fileExists: { $0.path == earlier.path },
            isReserved: { $0.path == earlier.path }
        )
        XCTAssertEqual(result, .write(URL(fileURLWithPath: "/Volumes/Archive/番組 第1話_h265 2.mp4")))
    }

    func testRenamePolicyAppendsCounterUntilFree() {
        var output = OutputSettings()
        output.existingFilePolicy = .rename
        let existing: Set<String> = [
            "/Volumes/Rec/番組 第1話_h265.mp4",
            "/Volumes/Rec/番組 第1話_h265 2.mp4"
        ]
        XCTAssertEqual(plan(output: output, existing: existing),
                       .write(URL(fileURLWithPath: "/Volumes/Rec/番組 第1話_h265 3.mp4")))
    }

    func testOverwritePolicyKeepsOriginalName() {
        var output = OutputSettings()
        output.existingFilePolicy = .overwrite
        let existing: Set<String> = ["/Volumes/Rec/番組 第1話_h265.mp4"]
        XCTAssertEqual(plan(output: output, existing: existing),
                       .write(URL(fileURLWithPath: "/Volumes/Rec/番組 第1話_h265.mp4")))
    }

    func testSkipPolicyReportsExistingFile() {
        var output = OutputSettings()
        output.existingFilePolicy = .skip
        let existing: Set<String> = ["/Volumes/Rec/番組 第1話_h265.mp4"]
        XCTAssertEqual(plan(output: output, existing: existing),
                       .skip(existing: URL(fileURLWithPath: "/Volumes/Rec/番組 第1話_h265.mp4")))
    }
}

// MARK: - 同じファイルかどうか

final class SameFileTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SameFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSameFileThroughSymbolicLinkedFolder() throws {
        let clip = folder.appendingPathComponent("clip.mp4")
        try Data([1]).write(to: clip)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        XCTAssertTrue(refersToSameFile(link.appendingPathComponent("clip.mp4"), clip))
    }

    func testDifferentFilesAreNotTheSame() throws {
        let a = folder.appendingPathComponent("a.mp4")
        let b = folder.appendingPathComponent("b.mp4")
        try Data([1]).write(to: a)
        try Data([2]).write(to: b)

        XCTAssertFalse(refersToSameFile(a, b))
    }

    func testPathsDifferingOnlyInCaseAreTheSameWhenFileIsMissing() {
        XCTAssertTrue(refersToSameFile(folder.appendingPathComponent("CLIP.MP4"), folder.appendingPathComponent("clip.mp4")))
    }

    func testPrivatePrefixDoesNotMatterForMissingFiles() {
        // 一時フォルダは /var/folders/… にあり、実体は /private/var/folders/…。
        let plain = folder.appendingPathComponent("new.mp4")
        let withPrivate = URL(fileURLWithPath: "/private" + folder.resolvingSymlinksInPath().path).appendingPathComponent("NEW.MP4")
        XCTAssertTrue(refersToSameFile(plain, withPrivate))
    }

    func testDifferentNamesAreNotTheSameWithoutTouchingTheDisk() {
        // 既定の接尾辞 _h265 では名前が必ず違うので、ファイルシステムに問い合わせずに別物とする。
        XCTAssertFalse(refersToSameFile(URL(fileURLWithPath: "/Volumes/Rec/番組.ts"), URL(fileURLWithPath: "/Volumes/Rec/番組_h265.mp4")))
    }
}
