import XCTest
@testable import Akiakane

/// ffprobe の JSON から `MediaInfo` を作るところのテスト。JSON は ffprobe 9 の出力を短くしたもの。
final class MediaInfoTests: XCTestCase {

    private func mediaInfo(_ json: String, url: String = "/tmp/in.mov") throws -> MediaInfo {
        let report = try FFProbeReport.decode(from: Data(json.utf8))
        return MediaInfo(url: URL(fileURLWithPath: url), report: report)
    }

    func testMotionJPEGVideoIsTreatedAsVideo() throws {
        // 古いデジカメの .avi / .mov。映像が Motion-JPEG でも、attached_pic でなければ動画。
        let info = try mediaInfo("""
        {"streams": [
          {"index": 0, "codec_name": "mjpeg", "codec_type": "video", "width": 640, "height": 480,
           "disposition": {"default": 1, "dub": 0, "attached_pic": 0}},
          {"index": 1, "codec_name": "pcm_s16le", "codec_type": "audio", "channels": 1,
           "disposition": {"default": 1, "attached_pic": 0}}
        ], "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "duration": "10.0"}}
        """)

        XCTAssertEqual(info.primaryVideo?.codecName, "mjpeg")
        XCTAssertEqual(info.otherStreamCount, 0)

        let args = makeArguments(input: info, output: URL(fileURLWithPath: "/tmp/out.mp4.partial"), settings: EncodeSettings())
        XCTAssertTrue(args.contains("-c:v"), "映像を落とした出力にしない")
    }

    func testCoverArtBeforeTheVideoIsSkippedAndMappedByIndex() throws {
        let info = try mediaInfo("""
        {"streams": [
          {"index": 0, "codec_name": "mjpeg", "codec_type": "video", "width": 300, "height": 300,
           "disposition": {"attached_pic": 1}},
          {"index": 1, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080,
           "disposition": {"attached_pic": 0}},
          {"index": 2, "codec_name": "aac", "codec_type": "audio", "channels": 2}
        ], "format": {"duration": "60.0"}}
        """, url: "/tmp/in.mp4")

        XCTAssertEqual(info.videoStreams.map(\.index), [1])
        XCTAssertEqual(info.otherStreamCount, 1)

        let args = makeArguments(input: info, output: URL(fileURLWithPath: "/tmp/out.mp4.partial"), settings: EncodeSettings())
        let maps = args.indices.filter { args[$0] == "-map" }.map { args[$0 + 1] }
        XCTAssertEqual(maps, ["0:1", "0:2"], "解析したストリームを番号で指定する。0:v:0 だとカバーアートを変換してしまう")
    }

    func testThumbnailTracksAreNotTakenAsTheMainVideo() throws {
        let info = try mediaInfo("""
        {"streams": [
          {"index": 0, "codec_name": "mjpeg", "codec_type": "video", "width": 160, "height": 90,
           "disposition": {"attached_pic": 0, "timed_thumbnails": 1}},
          {"index": 1, "codec_name": "png", "codec_type": "video", "width": 160, "height": 90,
           "disposition": {"still_image": 1}},
          {"index": 2, "codec_name": "h264", "codec_type": "video", "width": 1920, "height": 1080,
           "disposition": {"attached_pic": 0, "timed_thumbnails": 0, "still_image": 0}}
        ]}
        """, url: "/tmp/in.mp4")

        XCTAssertEqual(info.primaryVideo?.index, 2)
        XCTAssertEqual(info.otherStreamCount, 2)
    }

    func testStreamsWithoutDispositionAreStillDecoded() throws {
        let info = try mediaInfo("""
        {"streams": [{"index": 0, "codec_name": "mpeg2video", "codec_type": "video", "width": 1440, "height": 1080}]}
        """, url: "/tmp/in.ts")

        XCTAssertEqual(info.primaryVideo?.index, 0)
    }
}
