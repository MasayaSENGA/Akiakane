import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - メイン画面

struct ContentView: View {

    @Environment(ConversionQueue.self) private var queue
    @State private var selection: MediaInfo.ID?
    @State private var isDropTargeted = false
    @State private var isImporterPresented = false
    @State private var isInspectorPresented = true

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            detail
        }
        .inspector(isPresented: $isInspectorPresented) {
            SettingsInspector(queue: queue)
                .inspectorColumnWidth(min: 300, ideal: 340)
        }
        .toolbar { toolbarContent }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls: urls)
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
            if case .missing(let tools) = queue.toolStatus { toolMissingBanner(tools) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !queue.errorMessages.isEmpty { errorBanner }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { queue.add(urls: urls) }
        }
        .onDeleteCommand {
            guard let selection else { return }
            queue.remove(selection)
            self.selection = nil
        }
    }

    // MARK: ツールバー

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                isImporterPresented = true
            } label: {
                Label("ファイルを追加", systemImage: "plus")
            }
            .help("変換するファイルやフォルダを追加する")
        }

        ToolbarItemGroup {
            if queue.isRunning {
                Button {
                    queue.stopAll()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .help("変換中のファイルを止める。残りは待機のまま残る")
            } else {
                Button {
                    queue.startAll()
                } label: {
                    Label("変換を開始", systemImage: "play.fill")
                }
                .disabled(queue.waitingCount == 0 || queue.toolStatus != .ready)
                .help("待機中のファイルを上から順に変換する")
            }

            Menu {
                Button("完了したものを消去") { queue.removeSettled(); clearSelectionIfMissing() }
                    .disabled(!queue.hasSettledItems)
                Button("すべて消去") { queue.removeAll(); clearSelectionIfMissing() }
                    .disabled(queue.items.isEmpty)
            } label: {
                Label("消去", systemImage: "trash")
            }
            .help("リストからファイルを外す。ファイル自体は消えない")

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("設定", systemImage: "slider.horizontal.3")
            }
            .help("変換設定と出力先の設定パネルを表示する")
        }
    }

    private func clearSelectionIfMissing() {
        if queue.item(for: selection) == nil { selection = nil }
    }

    // MARK: サイドバー

    private var sidebar: some View {
        Group {
            if queue.items.isEmpty {
                emptyState
            } else {
                List(queue.items, selection: $selection) { item in
                    QueueRow(item: item)
                        .contextMenu { contextMenu(for: item) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    queueSummary
                }
            }
        }
        .overlay(alignment: .bottom) {
            if queue.isProbing { probingIndicator }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ConversionQueue.Item) -> some View {
        switch item.status {
        case .waiting:
            Button("このファイルを外す") { queue.cancel(item.id) }
        case .checkingAudio, .running:
            Button("変換をキャンセル") { queue.cancel(item.id) }
        case .finished(let url):
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("もう一度変換する") { queue.requeue(item.id) }
        case .skipped, .failed, .cancelled:
            Button("待機に戻す") { queue.requeue(item.id) }
        }
        Divider()
        Button("元のファイルを Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([item.info.url]) }
        Button("リストから外す") {
            queue.remove(item.id)
            if selection == item.id { selection = nil }
        }
    }

    private var queueSummary: some View {
        HStack(spacing: 12) {
            Text("\(queue.items.count) 件")
            if queue.waitingCount > 0 { Text("待機 \(queue.waitingCount)") }
            if queue.finishedCount > 0 { Text("完了 \(queue.finishedCount)") }
            if queue.failedCount > 0 { Text("失敗 \(queue.failedCount)").foregroundStyle(.red) }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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

    private var probingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(queue.probingFileName ?? "解析しています")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
        .padding(.bottom, 24)
    }

    // MARK: 詳細

    @ViewBuilder
    private var detail: some View {
        if let item = queue.item(for: selection) {
            MediaInfoDetail(item: item, queue: queue)
                .id(item.id)
        } else {
            Text(queue.items.isEmpty ? "読み込んだファイルの情報がここに出ます。" : "左のリストからファイルを選びます。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: バナー

    private func toolMissingBanner(_ tools: [FFTool]) -> some View {
        let names = tools.map(\.rawValue).joined(separator: " と ")
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(names) が見つかりません")
                    .font(.callout.weight(.medium))
                Text("ターミナルで brew install ffmpeg を実行してから「再確認」を押す。別の場所にある場合は、設定（⌘,）でパスを指定する。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("再確認") { queue.recheckTools() }
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
                ForEach(Array(queue.errorMessages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button("閉じる") { queue.dismissErrors() }
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

// MARK: - キューの1行

struct QueueRow: View {

    let item: ConversionQueue.Item

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.status.symbolName)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.info.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if case .running(let progress) = item.status {
                    if let fraction = progress?.fraction {
                        ProgressView(value: fraction)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if item.status == .checkingAudio {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch item.status {
        case .waiting:
            return "\(item.info.durationText) · \(item.info.fileSizeText)"
        case .checkingAudio:
            return item.status.shortText
        case .running(let progress):
            var parts = [item.status.shortText]
            if let speed = progress?.speed { parts.append(String(format: "%.2fx", speed)) }
            if let remaining = progress?.estimatedRemaining { parts.append("残り \(MediaInfo.formatDuration(remaining))") }
            return parts.joined(separator: " · ")
        case .finished(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
                .map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return ["完了", size].compactMap { $0 }.joined(separator: " · ")
        case .skipped, .failed, .cancelled:
            return item.status.shortText
        }
    }

    private var tint: Color {
        switch item.status {
        case .waiting:   return .secondary
        case .checkingAudio: return .accentColor
        case .running:   return .accentColor
        case .finished:  return .green
        case .skipped:   return .secondary
        case .failed:    return .red
        case .cancelled: return .secondary
        }
    }
}

#Preview {
    ContentView()
        .environment(ConversionQueue())
}
