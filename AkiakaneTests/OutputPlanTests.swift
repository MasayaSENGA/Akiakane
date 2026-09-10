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
