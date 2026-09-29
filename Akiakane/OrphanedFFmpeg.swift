import Darwin
import Foundation
import os

/// 変換中の ffmpeg を記録しておき、アプリが異常終了したとき（強制終了、クラッシュ、Xcode の Stop）に、
/// 次の起動で取り残された ffmpeg を止め、書きかけのファイルを消す。
///
/// ffmpeg は親のアプリが死んでも止まらない（SIGPIPE を無視し、進捗を書けなくても変換を続ける）。
/// libx265 なら何時間も CPU を使い続ける。記録は UserDefaults に置く。書き込みはすぐに cfprefsd へ渡るので、
/// アプリが強制終了されても残る。
///
/// UserDefaults は同じアプリのほかのインスタンスとも共有される（/Applications の Release 版と Xcode から
/// 起動した Debug 版、並列に動くテストなど）。記録はアプリのプロセスごとに別のキーに置き、読んで書き戻す
/// 競合を起こさない。記録を書いたアプリがまだ動いていれば、その ffmpeg は取り残されたものとみなさない。
///
/// 起動時の後始末はメインスレッドの外から呼べる（応答しない NAS 上のファイルを消すときに UI を止めない）。
nonisolated enum OrphanedFFmpeg {

    struct Record: Codable, Equatable {
        let pid: Int32
        /// プロセスの開始時刻（マイクロ秒）。PID は再利用されるので、別のプロセスを止めないよう照合する。
        let startTime: UInt64
        /// カーネルが報告する実行ファイルのパス（シンボリックリンクを解決したもの）。
        let executablePath: String
        /// プロセス名（最大 16 バイト）。`brew upgrade` で実行ファイルが消えるとパスは取れなくなるので、その代わりに使う。
        let processName: String
        let partialPath: String
        /// 記録を書いたアプリのプロセス。
        let ownerPID: Int32
        let ownerStartTime: UInt64

        var defaultsKey: String { OrphanedFFmpeg.keyPrefix + "\(ownerPID)-\(ownerStartTime)" }
    }

    static let keyPrefix = "RunningFFmpeg.v3."

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Akiakane", category: "command")

    /// 起動した直後の ffmpeg を記録する。
    static func record(pid: Int32, partial: URL, defaults: UserDefaults = .standard) {
        let owner = getpid()
        guard let processStart = startTime(of: pid),
              let path = executablePath(of: pid),
              let ownerStart = startTime(of: owner) else { return }
        let record = Record(
            pid: pid, startTime: processStart, executablePath: path, processName: processName(of: pid) ?? "",
            partialPath: partial.path, ownerPID: owner, ownerStartTime: ownerStart
        )
        store(record, in: defaults)
    }

    /// ffmpeg が終わったら、このアプリの記録を消す。
    static func clear(defaults: UserDefaults = .standard) {
        let owner = getpid()
        guard let ownerStart = startTime(of: owner) else { return }
        defaults.removeObject(forKey: keyPrefix + "\(owner)-\(ownerStart)")
    }

    /// 起動時に呼ぶ。記録を書いたアプリがもう動いていなければ、そのアプリは変換の途中で終わっている。
    /// そのとき起動した ffmpeg がまだ動いていれば止め、書きかけのファイルを消す。片付けた記録を返す。
    @discardableResult
    static func cleanUpLeftovers(defaults: UserDefaults = .standard) -> [Record] {
        var cleaned: [Record] = []
        for record in records(in: defaults) where !isAlive(pid: record.ownerPID, startTime: record.ownerStartTime) {
            if isStillRunning(record) {
                // 書きかけの出力は捨てるので、trailer の書き込みなどの後始末を待たずに止める。
                kill(record.pid, SIGKILL)
                logger.notice("前回の変換で取り残された ffmpeg（PID \(record.pid)）を止めた")
            }
            // 消せなかった（NAS がつながっていないなど）ときは記録を残し、次の起動でもう一度試す。
            guard removePartialFile(atPath: record.partialPath) else { continue }
            defaults.removeObject(forKey: record.defaultsKey)
            cleaned.append(record)
        }
        return cleaned
    }

    // MARK: - 記録の読み書き

    static func records(in defaults: UserDefaults) -> [Record] {
        defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(keyPrefix) }
            .compactMap { ($0.value as? Data).flatMap { try? JSONDecoder().decode(Record.self, from: $0) } }
    }

    static func store(_ record: Record, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: record.defaultsKey)
    }

    // MARK: - 書きかけのファイル

    /// 書きかけのファイルを消す。記録が壊れていても完成した出力や入力を消さないよう、
    /// `<名前>.<8文字>.partial` の形の通常ファイルだけを、再帰しない unlink で消す。
    /// 消した、または初めから無ければ true。
    static func removePartialFile(atPath path: String) -> Bool {
        let parts = (path as NSString).lastPathComponent.split(separator: ".")
        guard parts.count >= 3, parts.last == "partial", parts[parts.count - 2].count == 8 else { return true }
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFREG else { return true }
        return unlink(path) == 0 || errno == ENOENT
    }

    // MARK: - プロセスの照合

    /// 記録した ffmpeg が、同じ PID のまま動いているか。開始時刻に加えて、実行ファイルのパス
    /// （取れなければプロセス名）まで一致したときだけ true。
    private static func isStillRunning(_ record: Record) -> Bool {
        guard isAlive(pid: record.pid, startTime: record.startTime) else { return false }
        if let path = executablePath(of: record.pid) { return path == record.executablePath }
        return !record.processName.isEmpty && processName(of: record.pid) == record.processName
    }

    /// 同じ PID のプロセスが、同じ開始時刻のまま動いているか。
    static func isAlive(pid: Int32, startTime expected: UInt64) -> Bool {
        startTime(of: pid) == expected
    }

    static func startTime(of pid: Int32) -> UInt64? {
        bsdInfo(of: pid).map { $0.pbi_start_tvsec * 1_000_000 + $0.pbi_start_tvusec }
    }

    static func processName(of pid: Int32) -> String? {
        guard var info = bsdInfo(of: pid) else { return nil }
        return withUnsafeBytes(of: &info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func bsdInfo(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
