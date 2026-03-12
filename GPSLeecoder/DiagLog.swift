import Foundation

/// 파일 기반 진단 로거 — 백그라운드 디버깅용.
/// 로그가 Documents/diag.log에 기록되어 나중에 확인 가능.
enum DiagLog {
    private static let maxFileSize: UInt64 = 500_000  // 500KB 초과 시 truncate
    private static let lock = NSLock()

    private static var _fileHandle: FileHandle?
    private static var _fileURL: URL?

    static var fileURL: URL? { _fileURL }

    /// 앱 시작 시 호출
    static func initialize() {
        lock.lock()
        defer { lock.unlock() }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("diag.log")
        _fileURL = url

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        // 파일이 너무 크면 최근 절반만 유지
        truncateIfNeeded(url: url)

        _fileHandle = try? FileHandle(forWritingTo: url)
        try? _fileHandle?.seekToEnd()

        let header = "\n===== DiagLog started: \(ISO8601DateFormatter().string(from: Date())) =====\n"
        _fileHandle?.write(Data(header.utf8))
    }

    /// 로그 기록 (print + 파일)
    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let shortFile = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let entry = "[\(timestamp)] [\(shortFile):\(line)] \(message)\n"

        // 콘솔에도 출력
        print(entry, terminator: "")

        lock.lock()
        defer { lock.unlock() }
        _fileHandle?.write(Data(entry.utf8))
        // 매 로그마다 flush — 크래시/kill 시에도 로그 보존
        try? _fileHandle?.synchronize()
    }

    /// 로그 내용 읽기
    static func readAll() -> String {
        guard let url = _fileURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 로그 초기화
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = _fileURL else { return }
        try? _fileHandle?.close()
        try? "".write(to: url, atomically: true, encoding: .utf8)
        _fileHandle = try? FileHandle(forWritingTo: url)
    }

    // MARK: - Private

    private static func truncateIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxFileSize else { return }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let halfIndex = content.index(content.startIndex, offsetBy: content.count / 2)
        // 줄 경계에서 자르기
        if let lineBreak = content[halfIndex...].firstIndex(of: "\n") {
            let trimmed = String(content[content.index(after: lineBreak)...])
            try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
