import Foundation

enum FFTool: String, CaseIterable {
    case ffmpeg
    case ffprobe

    var executableName: String { rawValue }

    var userDefaultsKey: String { "FFToolPath.\(rawValue)" }
}

enum FFToolError: LocalizedError {
    case notFound(FFTool)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool):
            return "\(tool.rawValue) が見つかりません。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound:
            return "ターミナルで brew install ffmpeg を実行するか、設定で実行ファイルのパスを指定してください。"
        }
    }
}

/// ffmpeg / ffprobe の実行ファイルを探す。
///
/// GUI アプリの PATH は極端に短く、シェルの設定も反映されないため
/// `which` は当てにできない。素直に候補ディレクトリを順に見る。
enum FFToolLocator {

    static let searchDirectories = [
        "/opt/homebrew/bin",   // Homebrew (Apple Silicon)
        "/usr/local/bin",      // Homebrew (Intel)
        "/opt/local/bin",      // MacPorts
        "/usr/bin"
    ]

    static func locate(_ tool: FFTool) -> URL? {
        if let custom = customPath(for: tool) { return custom }

        for directory in searchDirectories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(tool.executableName)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func require(_ tool: FFTool) throws -> URL {
        guard let url = locate(tool) else { throw FFToolError.notFound(tool) }
        return url
    }

    // MARK: - ユーザー指定のパス

    static func customPath(for tool: FFTool) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: tool.userDefaultsKey),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func setCustomPath(_ path: String?, for tool: FFTool) {
        if let path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: tool.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: tool.userDefaultsKey)
        }
    }
}
