import Foundation
import UniformTypeIdentifiers

enum FFProbeError: LocalizedError {
    case probeFailed(fileName: String, status: Int32, message: String)
    case decodeFailed(fileName: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .probeFailed(let fileName, let status, let message):
            let detail = message.isEmpty ? "詳細なメッセージはありません。" : message
            return "\(fileName) を解析できませんでした（終了コード \(status)）。\n\(detail)"
        case .decodeFailed(let fileName, let underlying):
            return "\(fileName) の解析結果を読み取れませんでした: \(underlying.localizedDescription)"
        }
    }
}

struct FFProbeRunner {

    /// 実行ファイルを明示したいときに指定する。nil なら FFToolLocator が探す。
    var executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func probe(_ url: URL) async throws -> MediaInfo {
        let executable = try executableURL ?? FFToolLocator.require(.ffprobe)

        let arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]

        let result = try await ProcessRunner.run(executable: executable, arguments: arguments)

        guard result.isSuccess else {
            throw FFProbeError.probeFailed(
                fileName: url.lastPathComponent,
                status: result.terminationStatus,
                message: result.stderrTail()
            )
        }

        do {
            let report = try FFProbeReport.decode(from: result.standardOutput)
            return MediaInfo(url: url, report: report)
        } catch {
            throw FFProbeError.decodeFailed(fileName: url.lastPathComponent, underlying: error)
        }
    }
}

// MARK: - 入力ファイルの収集

/// ドロップされたファイルやフォルダから、変換できるファイルを集める。
/// 大きなフォルダ（NAS の録画フォルダなど）では時間がかかるので、メインスレッドの外から呼べるようにしてある。
nonisolated enum MediaFileScanner {

    /// 対象とする拡張子。要件定義の未決事項のため、ひとまずこの範囲で始める。
    static let supportedExtensions: Set<String> = [
        "ts", "m2ts", "mts", "mpg", "mpeg",
        "mp4", "m4v", "mkv", "mov", "avi", "wmv"
    ]

    /// ドロップされた URL を、実際に解析できるファイルの一覧に展開する。
    ///
    /// フォルダは再帰的に走査する。パッケージのうち、.app や写真ライブラリなどの中には入らない。
    /// ただし AVCHD（ビデオカメラの SD カード）や BDMV（Blu-ray）のフォルダは、macOS がパッケージとして扱うが、
    /// 中の .MTS / .m2ts が変換の対象なので入る。
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .contentTypeKey, .isSymbolicLinkKey]

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )
                while let child = enumerator?.nextObject() as? URL {
                    let values = try? child.resourceValues(forKeys: Set(keys))
                    if values?.isPackage == true, !isVideoCollection(values?.contentType) {
                        enumerator?.skipDescendants()
                        continue
                    }
                    // 拡張子が動画でも、フォルダ（dir.mp4 など）は対象にしない。
                    // 録画フォルダによくある、別の場所の動画へのシンボリックリンクは、リンク先がファイルなら対象にする。
                    guard isSupported(child) else { continue }
                    if values?.isRegularFile == true || (values?.isSymbolicLink == true && isRegularFile(child.resolvingSymlinksInPath())) {
                        files.append(child)
                    }
                }
            } else if isSupported(url) {
                files.append(url)
            }
        }

        // 同じファイルを二重に追加しない。シンボリックリンクとリンク先が両方あれば、先に見つかったほうだけにする。
        var seen = Set<String>()
        return files.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    /// AVCHD / BDMV のように、動画を収めたパッケージか（UTI は public.avchd-collection など）。
    private static func isVideoCollection(_ type: UTType?) -> Bool {
        guard let type, let collection = UTType("public.audiovisual-content-collection") else { return false }
        return type.conforms(to: collection)
    }
}
