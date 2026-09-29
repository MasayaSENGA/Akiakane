import Foundation

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

        #if DEBUG
        print("[ffprobe] " + ProcessRunner.commandLine(executable: executable, arguments: arguments))
        #endif

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

enum MediaFileScanner {

    /// 対象とする拡張子。要件定義の未決事項のため、ひとまずこの範囲で始める。
    static let supportedExtensions: Set<String> = [
        "ts", "m2ts", "mts", "mpg", "mpeg",
        "mp4", "m4v", "mkv", "mov", "avi", "wmv"
    ]

    /// ドロップされた URL を、実際に解析できるファイルの一覧に展開する。
    /// フォルダは再帰的に走査する。パッケージ（.app など）の中には入らない。
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fileManager = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    if isSupported(child) { files.append(child) }
                }
            } else if isSupported(url) {
                files.append(url)
            }
        }

        // 同じファイルを二重に追加しない。
        var seen = Set<String>()
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
