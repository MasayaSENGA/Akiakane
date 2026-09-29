import XCTest
@testable import Akiakane

/// `MediaFileScanner.expand` のテスト。一時フォルダに実際のフォルダ構成を作る。
final class MediaFileScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaFileScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }

    func testVideoCollectionsAreScannedButOtherPackagesAreNot() throws {
        // ビデオカメラの SD カード（AVCHD）と Blu-ray（BDMV）。macOS はどちらもパッケージとして扱う。
        try touch("CARD/PRIVATE/AVCHD/BDMV/INDEX.BDM")
        try touch("CARD/PRIVATE/AVCHD/BDMV/MOVIEOBJ.BDM")
        try touch("CARD/PRIVATE/AVCHD/BDMV/STREAM/00000.MTS")
        try touch("BD/BDMV/index.bdmv")
        try touch("BD/BDMV/MovieObject.bdmv")
        try touch("BD/BDMV/STREAM/00001.m2ts")
        // アプリの中の動画は対象にしない。
        try touch("Tool.app/Contents/Info.plist")
        try touch("Tool.app/Contents/Resources/intro.mp4")
        try touch("rec.ts")

        let names = MediaFileScanner.expand([root]).map(\.lastPathComponent)

        XCTAssertEqual(Set(names), ["00000.MTS", "00001.m2ts", "rec.ts"])
    }

    func testSymbolicLinkToAVideoIsIncludedOnce() throws {
        // 録画フォルダに、別の場所の録画へのシンボリックリンクを置く使い方。リンク先と両方あっても1本にする。
        try touch("elsewhere/rec.ts")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("folder/link.ts"),
            withDestinationURL: root.appendingPathComponent("elsewhere/rec.ts")
        )

        let inFolder = MediaFileScanner.expand([root.appendingPathComponent("folder")]).map(\.lastPathComponent)
        XCTAssertEqual(inFolder, ["link.ts"])

        let both = MediaFileScanner.expand([root])
        XCTAssertEqual(both.count, 1, "リンクとリンク先を二重に数えない")
    }

    func testFolderWithVideoExtensionIsNotAFile() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir.mp4"), withIntermediateDirectories: true)
        try touch("dir.mp4/inner.ts")

        let names = MediaFileScanner.expand([root]).map(\.lastPathComponent)

        XCTAssertEqual(names, ["inner.ts"], "拡張子が動画でも、フォルダは対象にしない")
    }
}
