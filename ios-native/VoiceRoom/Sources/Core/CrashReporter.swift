import Foundation
import Darwin
import UIKit

/// 信号处理器专用的全局 fd：handler 里只允许 write 这个已打开的 fd，
/// 不许碰 Swift 运行时（String/Date/FileManager 都会 malloc，信号上下文里会死锁或二次崩溃
/// —— 上一版抓不到任何信号记录，大概率就是 handler 自己先崩了）。
private var g_signalFD: Int32 = -1

/// 各信号的静态字节标记（全局常量，handler 里只读不分配）
private let g_sigNames: [Int32: [UInt8]] = [
    SIGABRT: Array("SIG:6 SIGABRT\n".utf8),
    SIGILL:  Array("SIG:4 SIGILL\n".utf8),
    SIGTRAP: Array("SIG:5 SIGTRAP\n".utf8),
    SIGBUS:  Array("SIG:10 SIGBUS\n".utf8),
    SIGFPE:  Array("SIG:8 SIGFPE\n".utf8),
    SIGSEGV: Array("SIG:11 SIGSEGV\n".utf8),
]

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

    /// 内存面包屑：磁盘写入在用户设备上实测会静默失败（try? 吞掉错误），
    /// 所以同时存一份在内存里。App 活着的时候（比如手动点诊断按钮）内存一定可读；
    /// 崩溃后内存丢失，则回落读磁盘文件。
    private static var memCrumbs: [String] = []
    private static let memCrumbsMax = 150

    static func crumb(_ s: String) {
        let line = "\(Int(Date().timeIntervalSince1970)) \(s)"
        memCrumbs.append(line)
        if memCrumbs.count > memCrumbsMax {
            memCrumbs.removeFirst(memCrumbs.count - memCrumbsMax)
        }
        let text = line + "\n"
        if let fh = try? FileHandle(forWritingTo: crumbURL) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
        } else {
            do {
                try ("=== crumbs ===\n" + text).write(to: crumbURL, atomically: true, encoding: .utf8)
            } catch {
                // 磁盘写失败不再静默：把错误存进内存面包屑，诊断按钮能看到
                memCrumbs.append("CRUMB-DISK-ERR: \(error.localizedDescription)")
            }
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

        // 信号类崩溃（野指针 / 数组越界 / EXC_BAD_ACCESS）：handler 里只用
        // async-signal-safe 的 write，写一行「信号名」就交还原默认处理。
        g_signalFD = open(crumbURL.path, O_WRONLY | O_CREAT | O_APPEND, 0644)
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                if g_signalFD >= 0, let bytes = g_sigNames[s] {
                    bytes.withUnsafeBufferPointer { buf in
                        if let base = buf.baseAddress {
                            _ = write(g_signalFD, base, buf.count)
                        }
                    }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }

        // 记一次设备信息：判断是否 iOS 新系统行为变化的关键依据
        crumb("device: \(UIDevice.current.model) \(UIDevice.current.systemName) "
            + UIDevice.current.systemVersion
            + " build\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        crumb("app: launch")
    }

    /// 取走上次崩溃的报告（有则返回内容并删除本地文件，避免重复上报）
    static func consumeReport() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        return String(text.prefix(8000))
    }

    /// 只读不删：手动诊断时看一眼有没有崩溃报告文件
    static func peekReport() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.isEmpty else { return nil }
        return String(text.prefix(4000))
    }

    /// 存储自诊断：把「磁盘为什么写不了」的原始事实发回来。
    /// 用户设备实测面包屑从未落盘成功，错误全被 try? 吞掉 —— 这里逐项打印不再吞。
    static func diagnoseStorage() -> String {
        var out = "--- storage diag ---\n"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        out += "dir: \(dir.path)\n"
        out += "dirExists: \(FileManager.default.fileExists(atPath: dir.path))\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            out += "mkdir: ok\n"
        } catch {
            out += "mkdir: ERR \(error)\n"
        }
        let testFile = dir.appendingPathComponent("vr-write-test.txt")
        do {
            try "t".write(to: testFile, atomically: true, encoding: .utf8)
            out += "testWrite: ok\n"
            try? FileManager.default.removeItem(at: testFile)
        } catch {
            out += "testWrite: ERR \(error)\n"
        }
        if FileManager.default.fileExists(atPath: crumbURL.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: crumbURL.path)[.size]) ?? "?"
            out += "crumbFile: exists size=\(size)\n"
        } else {
            out += "crumbFile: MISSING\n"
        }
        out += "memCrumbs: \(memCrumbs.count) lines\n"
        return out
    }

    /// 面包屑尾部：磁盘（上次崩溃会话遗留）在前，内存（本次会话）在后，合并返回。
    /// 崩溃重开后：磁盘有上次会话记录 → 自动上报拿到的正是崩溃现场；
    /// 手动诊断时：内存必有本次会话动作 → 一定有内容可发。
    static func tailCrumbs(_ limit: Int = 40) -> String? {
        var lines: [String] = []
        if let text = try? String(contentsOf: crumbURL, encoding: .utf8) {
            lines += text.split(separator: "\n").map(String.init)
        }
        lines += memCrumbs
        let tail = lines.suffix(limit)
        return tail.isEmpty ? nil : tail.joined(separator: "\n")
    }

    static func clearCrumbs() {
        try? FileManager.default.removeItem(at: crumbURL)
    }
}
