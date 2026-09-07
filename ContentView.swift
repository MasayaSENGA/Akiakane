import SwiftUI
import UniformTypeIdentifiers

// MARK: - モデル

@Observable
final class MediaLibraryModel {

    enum ToolStatus {
        case ready(URL)
        case missing
    }

    private(set) var items: [MediaInfo] = []
    private(set) var isLoading = false
    private(set) var loadingFileName: String?
    private(set) var errorMessages: [String] = []
    private(set) var toolStatus: ToolStatus

    private let runner = FFProbeRunner()

    init() {
        toolStatus = FFToolLocator.locate(.ffprobe).map { .ready($0) } ?? .missing
    }

    @MainActor
    func recheckTools() {
        toolStatus = FFToolLocator.locate(.ffprobe).map { .ready($0) } ?? .missing
    }

    @MainActor
    func add(urls: [URL]) {
        let files = MediaFileScanner.expand(urls)
        guard !files.isEmpty else {
            errorMessages.append("読み込めるファイルがありませんでした。対応している拡張子は \(MediaFileScanner.supportedExtensions.sorted().joined(separator: ", ")) です。")
            return
        }
        Task { await load(files) }
    }

    @MainActor
    func clear() {
        items.removeAll()
        errorMessages.removeAll()
    }

    @MainActor
    func dismissErrors() {
        errorMessages.removeAll()
    }

    /// ffprobe は 1 本ずつ順に実行する。数十本まとめてドロップされても
    /// プロセスが一気に増えないようにするため。
    @MainActor
    private func load(_ files: [URL]) async {
        isLoading = true
        defer {
            isLoading = false
            loadingFileName = nil
        }

        for file in files {
            let alreadyLoaded = items.contains {
                $0.url.standardizedFileURL == file.standardizedFileURL
            }
            if alreadyLoaded { continue }

            loadingFileName = file.lastPathComponent
            do {
                // probe 自体は別スレッドで動き、ここに戻ってきた時点で main に戻る。
                let info = try await runner.probe(file)
                items.append(info)
            } catch {
                errorMessages.append(Self.describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return error.localizedDescription }
        return [localized.errorDescription, localized.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

// MARK: - メイン画面

struct ContentView: View {

    @State private var model = MediaLibraryModel()
    @State private var selection: MediaInfo.ID?
    @State private var isDropTargeted = false
    @State private var isImporterPresented = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button("ファイルを追加") { isImporterPresented = true }
                Button("すべて消去") { model.clear(); selection = nil }
                    .disabled(model.items.isEmpty)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if case .missing = model.toolStatus { toolMissingBanner }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.errorMessages.isEmpty { errorBanner }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.add(urls: urls) }
        }
    }

    // MARK: サイドバー

    private var sidebar: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else {
                List(model.items, selection: $selection) { info in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(info.durationText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.isLoading { loadingIndicator }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("動画ファイルをドロップします")
                .font(.headline)
            Text("フォルダをドロップすると、中の対応ファイルをまとめて読み込みます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.loadingFileName ?? "解析しています")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    // MARK: 詳細

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let info = model.items.first(where: { $0.id == id }) {
            MediaInfoDetail(info: info)
        } else {
            Text(model.items.isEmpty ? "読み込んだファイルの情報がここに出ます。" : "左のリストからファイルを選びます。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: バナー

    private var toolMissingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("ffprobe が見つかりません")
                    .font(.callout.weight(.medium))
                Text("ターミナルで brew install ffmpeg を実行してから、再確認を押します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("再確認") { model.recheckTools() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.errorMessages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button("閉じる") { model.dismissErrors() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .folder]
        for ext in ["ts", "m2ts", "mts", "mkv"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()
}

// MARK: - 詳細表示

struct MediaInfoDetail: View {

    let info: MediaInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.fileName)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(info.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                InfoSection(title: "ファイル", entries: [
                    InfoEntry("コンテナ", info.containerName),
                    InfoEntry("長さ", info.durationText),
                    InfoEntry("サイズ", info.fileSizeText),
                    InfoEntry("全体ビットレート", info.bitRateText)
                ])

                if !info.hasReliableDuration {
                    Callout(
                        symbol: "exclamationmark.triangle",
                        tint: .orange,
                        text: "長さを取得できませんでした。このファイルは変換時に進捗率を計算できません。"
                    )
                }

                ForEach(Array(info.videoStreams.enumerated()), id: \.element.id) { index, video in
                    InfoSection(
                        title: info.videoStreams.count > 1 ? "映像 \(index + 1)（stream \(video.index)）" : "映像（stream \(video.index)）",
                        entries: videoEntries(video)
                    )
                }

                deinterlaceCallout

                ForEach(Array(info.audioStreams.enumerated()), id: \.element.id) { index, audio in
                    InfoSection(
                        title: info.audioStreams.count > 1 ? "音声 \(index + 1)（stream \(audio.index)）" : "音声（stream \(audio.index)）",
                        entries: audioEntries(audio)
                    )
                }

                if info.subtitleStreamCount > 0 || info.otherStreamCount > 0 {
                    InfoSection(title: "その他のストリーム", entries: [
                        InfoEntry("字幕", "\(info.subtitleStreamCount) 本"),
                        InfoEntry("データ・不明", "\(info.otherStreamCount) 本")
                    ])
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var deinterlaceCallout: some View {
        switch info.deinterlaceAdvice {
        case .notNeeded:
            Callout(symbol: "checkmark.circle", tint: .secondary,
                    text: "プログレッシブ素材です。インターレース解除は不要です。")
        case .recommended(let order):
            Callout(symbol: "square.stack.3d.down.right", tint: .blue,
                    text: "\(order.displayName)です。H.265 はインターレースを扱えないため、bwdif での解除が必要になります。")
        case .undetermined:
            Callout(symbol: "exclamationmark.triangle", tint: .orange,
                    text: "field_order を取得できませんでした。この素材はインターレース解除をプリセット任せにできません。")
        }
    }

    private func videoEntries(_ video: VideoStreamInfo) -> [InfoEntry] {
        var entries: [InfoEntry] = [
            InfoEntry("コーデック", video.codecLongName ?? video.codecName),
            InfoEntry("解像度", video.resolutionText)
        ]
        if let frameRate = video.frameRate {
            entries.append(InfoEntry("フレームレート", String(format: "%.3f fps", frameRate)))
        }
        entries.append(InfoEntry("フィールドオーダー", video.fieldOrder.displayName))
        if let pixelFormat = video.pixelFormat {
            entries.append(InfoEntry("ピクセルフォーマット", pixelFormat))
        }
        if let bitDepth = video.bitDepth {
            entries.append(InfoEntry("ビット深度", "\(bitDepth) bit"))
        }
        if let sar = video.sampleAspectRatio {
            entries.append(InfoEntry("SAR", video.isAnamorphic ? "\(sar)（アナモルフィック）" : sar))
        }
        if let dar = video.displayAspectRatio {
            entries.append(InfoEntry("DAR", dar))
        }
        if let bitRate = video.bitRate {
            entries.append(InfoEntry("ビットレート", String(format: "%.1f Mbps", Double(bitRate) / 1_000_000)))
        }
        return entries
    }

    private func audioEntries(_ audio: AudioStreamInfo) -> [InfoEntry] {
        var entries: [InfoEntry] = [
            InfoEntry("コーデック", audio.codecName),
            InfoEntry("チャンネル", audio.channelText)
        ]
        if let sampleRate = audio.sampleRate {
            entries.append(InfoEntry("サンプルレート", "\(sampleRate) Hz"))
        }
        if let bitRate = audio.bitRate {
            entries.append(InfoEntry("ビットレート", "\(bitRate / 1000) kbps"))
        }
        if let language = audio.language {
            entries.append(InfoEntry("言語", language))
        }
        return entries
    }
}

// MARK: - 部品

struct InfoEntry: Identifiable {
    let label: String
    let value: String
    var id: String { label }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

struct InfoSection: View {
    let title: String
    let entries: [InfoEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 4) {
                ForEach(entries) { entry in
                    GridRow {
                        Text(entry.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(entry.value)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }
}

struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    ContentView()
}
