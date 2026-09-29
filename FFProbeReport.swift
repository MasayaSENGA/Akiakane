import Foundation

/// `ffprobe -print_format json -show_format -show_streams` の出力をそのまま受ける型。
///
/// ここでは加工せず、ffprobe が返す文字列のまま保持する。
/// ffprobe は数値もほとんど文字列で返してくるため、変換は `MediaInfo` 側でまとめて行う。
///
/// あえて decode していないフィールドがある。`profile` は ffprobe のバージョンや
/// コーデックによって文字列と数値が混在することがあり、型を固定すると
/// デコード全体が失敗するため外している。
struct FFProbeReport: Decodable {

    let format: Format?
    let streams: [Stream]?

    struct Format: Decodable {
        let filename: String?
        let nbStreams: Int?
        let formatName: String?
        let formatLongName: String?
        let duration: String?
        let size: String?
        let bitRate: String?
    }

    struct Stream: Decodable {
        let index: Int
        let codecName: String?
        let codecLongName: String?
        let codecType: String?          // "video" / "audio" / "subtitle" / "data" など

        // 映像
        let width: Int?
        let height: Int?
        let codedWidth: Int?
        let codedHeight: Int?
        let sampleAspectRatio: String?  // "1:1", "4:3" など
        let displayAspectRatio: String?
        let pixFmt: String?
        let fieldOrder: String?         // "progressive" / "tt" / "bb" / "tb" / "bt" / "unknown"
        let rFrameRate: String?         // "30000/1001" のような有理数
        let avgFrameRate: String?
        let bitsPerRawSample: String?

        // 音声
        let sampleRate: String?
        let channels: Int?
        let channelLayout: String?

        // 共通
        let duration: String?
        let bitRate: String?
        let tags: [String: String]?
        let disposition: Disposition?
    }

    /// ストリームの用途を表すフラグ。使うものだけを decode し、ほかのキーは無視する。
    struct Disposition: Decodable {
        /// カバーアートなど、動画ではなく静止画として添付されたストリームなら 1。
        let attachedPic: Int?
        /// 動画の見出し用のサムネイル画像の列なら 1。
        let timedThumbnails: Int?
        /// 静止画のトラックなら 1。
        let stillImage: Int?

        init(attachedPic: Int? = nil, timedThumbnails: Int? = nil, stillImage: Int? = nil) {
            self.attachedPic = attachedPic
            self.timedThumbnails = timedThumbnails
            self.stillImage = stillImage
        }

        /// 本編の映像ではなく、静止画として扱うストリームか。
        var isStillImage: Bool {
            attachedPic == 1 || timedThumbnails == 1 || stillImage == 1
        }
    }

    static func decode(from data: Data) throws -> FFProbeReport {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FFProbeReport.self, from: data)
    }
}
