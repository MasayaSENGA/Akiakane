import XCTest
@testable import Akiakane

final class FFmpegProgressParserTests: XCTestCase {

    // MARK: - 実際の -progress 出力を模した文字列リテラル

    private let continueBlock = [
        "frame=120",
        "fps=29.97",
        "stream_0_0_q=28.0",
        "bitrate=1234.5kbits/s",
        "total_size=2048000",
        "out_time_us=4004000",
        "out_time_ms=4004000",
        "out_time=00:00:04.004000",
        "dup_frames=0",
        "drop_frames=0",
        "speed=1.23x",
        "progress=continue"
    ]

    func testParsesOutTimeUsSpeedAndSize() {
        let progress = FFmpegProgressParser.parseBlock(continueBlock, duration: 120, hasReliableDuration: true)

        XCTAssertEqual(progress.completed, 4.004, accuracy: 0.0001)
        XCTAssertNotNil(progress.speed)
        XCTAssertEqual(progress.speed!, 1.23, accuracy: 0.0001)
        XCTAssertEqual(progress.outputSize, 2_048_000)
        XCTAssertNotNil(progress.fraction)
        XCTAssertEqual(progress.fraction!, 4.004 / 120, accuracy: 0.0001)
        XCTAssertNotNil(progress.estimatedRemaining)
        XCTAssertEqual(progress.estimatedRemaining!, (120 - 4.004) / 1.23, accuracy: 0.0001)
    }

    func testUnreliableDurationForcesFractionNil() {
        let progress = FFmpegProgressParser.parseBlock(continueBlock, duration: 120, hasReliableDuration: false)
        XCTAssertNil(progress.fraction)
    }

    func testMissingDurationForcesFractionAndRemainingNil() {
        let progress = FFmpegProgressParser.parseBlock(continueBlock, duration: nil, hasReliableDuration: false)
        XCTAssertNil(progress.fraction)
        XCTAssertNil(progress.estimatedRemaining)
    }

    // MARK: - 開始直後（speed が N/A）

    func testSpeedNAAtStartYieldsNilSpeedAndNilRemaining() {
        let block = [
            "frame=1",
            "out_time_us=40000",
            "total_size=1024",
            "speed=N/A",
            "progress=continue"
        ]
        let progress = FFmpegProgressParser.parseBlock(block, duration: 120, hasReliableDuration: true)

        XCTAssertNil(progress.speed)
        XCTAssertNil(progress.estimatedRemaining)
        XCTAssertEqual(progress.completed, 0.04, accuracy: 0.0001)
    }

    // MARK: - out_time_us が無いときのフォールバック

    func testFallsBackToOutTimeWhenOutTimeUsMissing() {
        let block = [
            "frame=1",
            "out_time=00:01:02.500000",
            "speed=2.0x",
            "progress=continue"
        ]
        let progress = FFmpegProgressParser.parseBlock(block, duration: 120, hasReliableDuration: true)

        XCTAssertEqual(progress.completed, 62.5, accuracy: 0.0001)
    }

    // MARK: - 最終ブロック（progress=end）

    func testProgressEndBlockParsesLikeAnyOtherBlock() {
        let block = [
            "out_time_us=120000000",
            "total_size=50000000",
            "speed=1.5x",
            "progress=end"
        ]
        let progress = FFmpegProgressParser.parseBlock(block, duration: 120, hasReliableDuration: true)

        XCTAssertEqual(progress.completed, 120, accuracy: 0.0001)
        XCTAssertEqual(progress.fraction!, 1.0, accuracy: 0.0001)
    }

    // MARK: - fraction は 0...1 にクランプされる

    func testFractionIsClampedEvenIfOutTimeExceedsDuration() {
        let block = [
            "out_time_us=200000000", // 200 秒。duration より長い（見積もり誤差などで起こりうる）。
            "speed=1.0x",
            "progress=continue"
        ]
        let progress = FFmpegProgressParser.parseBlock(block, duration: 120, hasReliableDuration: true)

        XCTAssertEqual(progress.fraction!, 1.0, accuracy: 0.0001)
    }
}
