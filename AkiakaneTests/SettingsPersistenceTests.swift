import XCTest
@testable import Akiakane

final class SettingsPersistenceTests: XCTestCase {

    private var savedEncode: Data?
    private var savedOutput: Data?

    override func setUp() {
        super.setUp()
        // テストホストはアプリ本体なので、UserDefaults を触ると実際の設定が変わる。終わったら戻す。
        savedEncode = UserDefaults.standard.data(forKey: "EncodeSettings.v1")
        savedOutput = UserDefaults.standard.data(forKey: "OutputSettings.v1")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedEncode, forKey: "EncodeSettings.v1")
        UserDefaults.standard.set(savedOutput, forKey: "OutputSettings.v1")
        super.tearDown()
    }

    func testEncodeSettingsRoundTrip() throws {
        var settings = EncodeSettings()
        settings.videoCodec = .hevcVideoToolbox
        settings.videoToolboxQuality = 80
        settings.audioMode = .aac(bitrate: 256)
        settings.container = .mkv
        settings.deinterlace = .force

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EncodeSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testOutputSettingsRoundTrip() throws {
        var settings = OutputSettings()
        settings.destinationFolderPath = "/Volumes/Archive"
        settings.suffix = ""
        settings.existingFilePolicy = .skip

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(OutputSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.destinationFolderURL, URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true))
    }

    func testCorruptStoredDataFallsBackToDefaults() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: "EncodeSettings.v1")
        XCTAssertEqual(SettingsStore.loadEncodeSettings(), EncodeSettings())
    }

    /// `@Observable` の `didSet` が実際に発火して保存されることを確認する。
    /// マクロが property observer を潰していると、設定が次回起動に引き継がれない。
    @MainActor
    func testQueueSavesSettingsWhenChanged() {
        UserDefaults.standard.removeObject(forKey: "EncodeSettings.v1")
        let queue = ConversionQueue()
        queue.encodeSettings.crf = 18

        XCTAssertEqual(SettingsStore.loadEncodeSettings().crf, 18)
        XCTAssertEqual(ConversionQueue().encodeSettings.crf, 18, "新しいインスタンスは保存済みの値で始まる")
    }
}
