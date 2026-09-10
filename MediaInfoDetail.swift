import SwiftUI
import AppKit

// MARK: - 詳細表示

struct MediaInfoDetail: View {

    let item: ConversionQueue.Item
    var queue: ConversionQueue

    private var info: MediaInfo { item.info }

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

                ConversionSection(item: item, queue: queue)

                Divider()

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
                    text: "field_order を取得できませんでした。「自動判定」では、インターレースとマークされたフレームだけを解除します。")
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

// MARK: - 変換の状態

struct ConversionSection: View {

    let item: ConversionQueue.Item
    var queue: ConversionQueue

    private var info: MediaInfo { item.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("変換")
                .font(.subheadline.weight(.semibold))

            switch item.status {
            case .waiting:
                plannedOutputRow
                HStack {
                    Button(queue.isRunning ? "キューを変換中" : "キューの変換を開始") { queue.startAll() }
                        .disabled(queue.isRunning)
                    Button("このファイルを外す") { queue.cancel(item.id) }
                }

            case .running(let progress):
                progressView(progress)
                Button("このファイルの変換をキャンセル") { queue.cancel(item.id) }

            case .finished(let url):
                Callout(symbol: "checkmark.circle.fill", tint: .green,
                        text: "変換が完了しました: \(url.path)")
                HStack {
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("もう一度変換する") { queue.requeue(item.id) }
                }

            case .skipped(let message):
                Callout(symbol: "forward.end.circle", tint: .secondary, text: message)
                Button("待機に戻す") { queue.requeue(item.id) }

            case .failed(let message):
                Callout(symbol: "xmark.octagon.fill", tint: .red, text: message)
                Button("待機に戻す") { queue.requeue(item.id) }

            case .cancelled:
                Callout(symbol: "minus.circle", tint: .secondary,
                        text: "キャンセルしました。このファイルは変換されていません。")
                Button("待機に戻す") { queue.requeue(item.id) }
            }
        }
    }

    @ViewBuilder
    private var plannedOutputRow: some View {
        switch queue.plannedOutput(for: item) {
        case .write(let url):
            LabeledContent("出力先") {
                Text(url.path)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case .skip(let existing):
            Callout(symbol: "forward.end.circle", tint: .orange,
                    text: "同名のファイルがあるため、このままだとスキップされます: \(existing.lastPathComponent)")
        }
    }

    @ViewBuilder
    private func progressView(_ progress: EncodeProgress?) -> some View {
        if let fraction = progress?.fraction {
            ProgressView(value: fraction)
        } else {
            ProgressView()
        }

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text("変換済み").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                Text(elapsedText(progress))
            }
            GridRow {
                Text("速度").foregroundStyle(.secondary)
                Text(speedText(progress))
            }
            GridRow {
                Text("推定残り時間").foregroundStyle(.secondary)
                Text(remainingText(progress))
            }
            GridRow {
                Text("出力サイズ").foregroundStyle(.secondary)
                Text(outputSizeText(progress))
            }
        }
        .font(.callout)
    }

    private func elapsedText(_ progress: EncodeProgress?) -> String {
        let completed = MediaInfo.formatDuration(progress?.completed ?? 0)
        return "\(completed) / \(info.durationText)"
    }

    private func speedText(_ progress: EncodeProgress?) -> String {
        guard let speed = progress?.speed else { return "計測中" }
        return String(format: "%.2fx", speed)
    }

    private func remainingText(_ progress: EncodeProgress?) -> String {
        guard let remaining = progress?.estimatedRemaining else { return "不明" }
        return MediaInfo.formatDuration(remaining)
    }

    private func outputSizeText(_ progress: EncodeProgress?) -> String {
        guard let size = progress?.outputSize else { return "不明" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
