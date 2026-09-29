import Foundation
import Observation

/// 変換キュー。読み込んだファイルを1本ずつ順に ffmpeg へ渡す。
///
/// ffprobe と同じ理由で並列実行はしない。libx265 はそれ自体がコアを使い切るので、
/// 複数本を同時に走らせても総時間は縮まらず、1本ずつのほうが完了ファイルが早く得られる。
@Observable
final class ConversionQueue {

    enum ItemStatus: Equatable {
        case waiting
        /// 変換の前に、音声のチャンネル構成が途中で変わらないかを調べている。
        case checkingAudio
        case running(EncodeProgress?)
        case finished(URL)
        case skipped(String)
        case failed(String)
        case cancelled

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isSettled: Bool {
            switch self {
            case .finished, .skipped, .failed, .cancelled: return true
            case .waiting, .checkingAudio, .running: return false
            }
        }
    }

    struct Item: Identifiable {
        let info: MediaInfo
        var status: ItemStatus = .waiting
        /// 音声を設定と違う扱いにしたときの説明（構成の切り替えを見つけて AAC に変換した、など）。
        var audioNote: String?

        var id: MediaInfo.ID { info.id }
    }

    enum ToolStatus: Equatable {
        case ready
        case missing([FFTool])
    }

    private(set) var items: [Item] = []
    private(set) var isProbing = false
    private(set) var probingFileName: String?
    private(set) var errorMessages: [String] = []
    private(set) var toolStatus: ToolStatus = .ready

    /// キューが動いている間 true。個々のファイルの状態は `Item.status` を見る。
    private(set) var isRunning = false

    var encodeSettings: EncodeSettings {
        didSet { SettingsStore.save(encodeSettings) }
    }

    var outputSettings: OutputSettings {
        didSet { SettingsStore.save(outputSettings) }
    }

    private let prober = FFProbeRunner()
    private var queueTask: Task<Void, Never>?
    private var currentEncodeTask: Task<Void, Error>?
    private var currentItemID: MediaInfo.ID?
    private var stopRequested = false
    private var sleepActivity: NSObjectProtocol?

    init() {
        encodeSettings = SettingsStore.loadEncodeSettings()
        outputSettings = SettingsStore.loadOutputSettings()
        toolStatus = Self.checkTools()
    }

    // MARK: - 集計

    var waitingCount: Int { items.filter { $0.status == .waiting }.count }
    var finishedCount: Int { items.filter { if case .finished = $0.status { return true } else { return false } }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true } else { return false } }.count }
    var hasSettledItems: Bool { items.contains { $0.status.isSettled } }

    func item(for id: MediaInfo.ID?) -> Item? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// 待機中のファイルがこの設定で書き出される先。設定パネルを触りながら確認できるようにする。
    func plannedOutput(for item: Item) -> OutputPlan {
        makeOutputPlan(for: item.info.url, encode: encodeSettings, output: outputSettings) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    // MARK: - ツールの確認

    @MainActor
    func recheckTools() {
        toolStatus = Self.checkTools()
    }

    private static func checkTools() -> ToolStatus {
        let missing = FFTool.allCases.filter { FFToolLocator.locate($0) == nil }
        return missing.isEmpty ? .ready : .missing(missing)
    }

    // MARK: - ファイルの追加・削除

    @MainActor
    func add(urls: [URL]) {
        let files = MediaFileScanner.expand(urls)
        guard !files.isEmpty else {
            errorMessages.append("読み込めるファイルがありませんでした。対応している拡張子は \(MediaFileScanner.supportedExtensions.sorted().joined(separator: ", ")) です。")
            return
        }
        Task { await probe(files) }
    }

    /// ffprobe は 1 本ずつ順に実行する。数十本まとめてドロップされても
    /// プロセスが一気に増えないようにするため。
    @MainActor
    private func probe(_ files: [URL]) async {
        isProbing = true
        defer {
            isProbing = false
            probingFileName = nil
        }

        for file in files {
            let alreadyLoaded = items.contains {
                $0.info.url.standardizedFileURL == file.standardizedFileURL
            }
            if alreadyLoaded { continue }

            probingFileName = file.lastPathComponent
            do {
                let info = try await prober.probe(file)
                items.append(Item(info: info))
            } catch {
                errorMessages.append(Self.describe(error))
            }
        }
    }

    @MainActor
    func remove(_ id: MediaInfo.ID) {
        if currentItemID == id { currentEncodeTask?.cancel() }
        items.removeAll { $0.id == id }
    }

    /// 変換が終わった（成功・失敗・スキップ・キャンセル）ものをリストから外す。
    @MainActor
    func removeSettled() {
        items.removeAll { $0.status.isSettled }
    }

    /// 変換中のものも止めてリストを空にする。ffmpeg の停止と `.partial` の削除は
    /// `encode(_:)` 側が引き続き行う。項目が消えていれば状態更新は黙って無視される。
    @MainActor
    func removeAll() {
        stopAll()
        items.removeAll()
        errorMessages.removeAll()
    }

    @MainActor
    func dismissErrors() {
        errorMessages.removeAll()
    }

    // MARK: - キューの制御

    /// 待機中のファイルを先頭から順に変換する。
    @MainActor
    func startAll() {
        guard !isRunning else { return }
        guard waitingCount > 0 else { return }

        isRunning = true
        stopRequested = false
        beginSleepPrevention()

        queueTask = Task { @MainActor in
            while !stopRequested, let next = items.first(where: { $0.status == .waiting }) {
                await encode(next)
            }
            endSleepPrevention()
            isRunning = false
            queueTask = nil
        }
    }

    /// 変換中のファイルを止め、残りは待機のまま残す。
    @MainActor
    func stopAll() {
        stopRequested = true
        currentEncodeTask?.cancel()
    }

    /// 停止して、実際に ffmpeg が終わり `.partial` の掃除が済むまで待つ。アプリ終了時に使う。
    @MainActor
    func stopAndWait() async {
        stopAll()
        await queueTask?.value
    }

    /// 変換中なら止める。待機中ならキューから外れた扱いにする。
    @MainActor
    func cancel(_ id: MediaInfo.ID) {
        if currentItemID == id {
            currentEncodeTask?.cancel()
        } else if item(for: id)?.status == .waiting {
            update(id) { $0.status = .cancelled }
        }
    }

    /// 失敗・キャンセル・完了したファイルを、もう一度待機に戻す。
    @MainActor
    func requeue(_ id: MediaInfo.ID) {
        guard let current = item(for: id), current.status.isSettled else { return }
        update(id) {
            $0.status = .waiting
            $0.audioNote = nil
        }
    }

    // MARK: - 変換の実行

    @MainActor
    private func encode(_ item: Item) async {
        let id = item.id
        currentItemID = id
        defer {
            currentItemID = nil
            currentEncodeTask = nil
        }

        let output: URL
        switch plannedOutput(for: item) {
        case .write(let url):
            output = url
        case .skip(let existing):
            update(id) { $0.status = .skipped("同名のファイルがあるためスキップしました: \(existing.lastPathComponent)") }
            return
        }

        if let folder = outputSettings.destinationFolderURL {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                update(id) { $0.status = .failed("出力フォルダを作成できません: \(folder.path)\n\(error.localizedDescription)") }
                return
            }
        }

        let settings = encodeSettings
        let info = item.info
        let needsAudioScan = AudioLayoutScanner.needsScan(input: info, settings: settings)
        update(id) {
            $0.status = needsAudioScan ? .checkingAudio : .running(nil)
            $0.audioNote = nil
        }

        let relay = ProgressRelay { [weak self] progress in
            // 進捗更新の途中でキャンセルや削除が挟まっても、古い状態で上書きしない。
            guard let self, self.item(for: id)?.status.isRunning == true else { return }
            self.update(id) { $0.status = .running(progress) }
        }

        let task = Task<Void, Error> { [weak self] in
            // 走査もこのタスクの中で行う。停止やキャンセルをすると、走査中の ffmpeg も止まる。
            let layout: AudioLayoutReport? = if needsAudioScan {
                try await AudioLayoutScanner().scan(info)
            } else {
                nil
            }
            try layout?.checkConvertible(fileName: info.fileName)

            let runner = FFmpegRunner()
            let aacEncoder = if settings.audioMode == .none {
                "aac"
            } else {
                try await runner.preferredAACEncoder()
            }
            let decision = makeAudioPlan(input: info, settings: settings, layout: layout, aacEncoder: aacEncoder)

            #if DEBUG
            if let note = decision.note { print("[audio] \(info.fileName): \(note)") }
            #endif

            try Task.checkCancellation()
            self?.update(id) {
                $0.status = .running(nil)
                $0.audioNote = decision.note
            }

            try await runner.encode(input: info, output: output, settings: settings, audio: decision.plan) { progress in
                relay.report(progress)
            }
        }
        currentEncodeTask = task

        do {
            try await task.value
            update(id) { $0.status = .finished(output) }
        } catch is CancellationError {
            update(id) { $0.status = .cancelled }
        } catch {
            update(id) { $0.status = .failed(Self.describe(error)) }
        }
    }

    @MainActor
    private func update(_ id: MediaInfo.ID, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    // MARK: - スリープ抑止

    /// 長いバッチの途中で Mac がスリープに入ると変換が止まる。キューが動いている間だけ抑止する。
    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "動画を変換しています"
        )
    }

    private func endSleepPrevention() {
        if let sleepActivity {
            ProcessInfo.processInfo.endActivity(sleepActivity)
        }
        sleepActivity = nil
    }

    // MARK: - エラー表示

    private static func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return error.localizedDescription }
        return [localized.errorDescription, localized.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n")
    }
}

/// 進捗コールバックはプロセスの読み取りスレッドから任意のタイミングで呼ばれる。
/// ここで受けて MainActor に中継してから状態を更新する。
nonisolated private final class ProgressRelay: @unchecked Sendable {
    private let onProgress: @MainActor (EncodeProgress) -> Void

    init(onProgress: @escaping @MainActor (EncodeProgress) -> Void) {
        self.onProgress = onProgress
    }

    func report(_ progress: EncodeProgress) {
        Task { @MainActor in
            onProgress(progress)
        }
    }
}

// MARK: - 表示用

extension ConversionQueue.ItemStatus {

    var shortText: String {
        switch self {
        case .waiting:
            return "待機中"
        case .checkingAudio:
            return "音声を確認中"
        case .running(let progress):
            guard let fraction = progress?.fraction else { return "変換中" }
            return String(format: "変換中 %.0f%%", fraction * 100)
        case .finished:
            return "完了"
        case .skipped:
            return "スキップ"
        case .failed:
            return "失敗"
        case .cancelled:
            return "キャンセル"
        }
    }

    var symbolName: String {
        switch self {
        case .waiting:   return "clock"
        case .checkingAudio: return "waveform"
        case .running:   return "arrow.triangle.2.circlepath"
        case .finished:  return "checkmark.circle.fill"
        case .skipped:   return "forward.end.circle"
        case .failed:    return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        }
    }
}
