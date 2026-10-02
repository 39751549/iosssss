import Foundation
import Darwin

/// 崩溃捕获：NSException + 常见致命信号。
///
/// 上次崩溃的现场写到 Application Support/vr-crash-last.log，
/// 下次启动登录成功后自动上报给服务端（crash:report）并删除本地文件。
/// 只求「能拿到异常名 / reason / 堆栈」，不求完整——信号类崩溃只能尽力写一行。
enum CrashReporter {

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vr-crash-last.log")
    }

    /// 面包屑：关键动作执行前落一行。哪怕崩溃是 SIGKILL（watchdog 强杀，任何钩子
    /// 都抓不到），下次启动也能从面包屑看出「死前最后做到哪一步」。
    static var crumbURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vr-crumb.log")
    }

    static func crumb(_ s: String) {
        let line = "\(Int(Date().timeIntervalSince1970)) \(s)\n"
        if let fh = try? FileHandle(forWritingTo: crumbURL) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
        } else {
            try? ("=== crumbs ===\n" + line).write(to: crumbURL, atomically: true, encoding: .utf8)
        }
    }

    static func install() {
        // NSException：CoreAudio / AVFoundation 这类框架「闪退」几乎全是抛异常
        // （例如 'com.apple.coreaudio.avfaudio' required condition is false），
        // 这里能拿到完整的异常名 + reason + 调用栈，定位价值最大。
        NSSetUncaughtExceptionHandler { ex in
            let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
            let text = "=== 岛 crash @ \(Date()) ===\n"
                + "version: \(ver) (\(build))  os: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
                + "[NSException] \(ex.name.rawValue)\n"
                + "reason: \(ex.reason ?? "-")\n"
                + "stack:\n"
                + ex.callStackSymbols.joined(separator: "\n")
            try? text.write(to: CrashReporter.fileURL, atomically: true, encoding: .utf8)
        }

        // 信号类崩溃（野指针 / 数组越界 / EXC_BAD_ACCESS）：handler 里只能用
        // async-signal-safe 的 open/write，这里尽力写一行标识，够区分「是信号崩」即可。
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                let line = "=== 岛 crash ===\n[signal] \(s)\n"
                if let d = line.data(using: .utf8) {
                    let fd = open(CrashReporter.fileURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0644)
                    if fd >= 0 {
                        _ = d.withUnsafeBytes { ptr in write(fd, ptr.baseAddress, ptr.count) }
                        close(fd)
                    }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// 取走上次崩溃的报告（有则返回内容并删除本地文件，避免重复上报）
    static func consumeReport() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        return String(text.prefix(8000))
    }

    /// 面包屑尾部（用于即使没有异常记录、疑似被强杀时，也能看到死前最后动作）
    static func tailCrumbs(_ limit: Int = 40) -> String? {
        guard let text = try? String(contentsOf: crumbURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").suffix(limit)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func clearCrumbs() {
        try? FileManager.default.removeItem(at: crumbURL)
    }
}
