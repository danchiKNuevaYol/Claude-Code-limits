import Foundation

/// Обновление входа через настоящий Claude Code.
///
/// Токен, который читает плашка, выдаёт и обновляет Claude Code. Когда он истёк,
/// мы не трогаем его сами, а запускаем `claude -p` на одно короткое сообщение:
/// официальный клиент обновляет свой токен, и плашка подхватывает новый
/// при следующем запросе. Стоит это одного крошечного сообщения на Haiku.
enum ClaudeCLI {
    enum RenewResult {
        case ok
        case notInstalled
        case failed(String)
    }

    /// Приложение из Finder не видит PATH из терминала, поэтому ищем сами.
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",          // официальный установщик
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",           // Homebrew, Apple Silicon
            "/usr/local/bin/claude",              // Homebrew, Intel / npm
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func renewLogin(timeout: TimeInterval = 90) async -> RenewResult {
        guard let exe = executable() else { return .notInstalled }

        // Пустая временная папка — чтобы Claude Code не читал никакой проект
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHUD-renew", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = exe
        p.arguments = ["-p", "Reply with just: ok", "--model", "haiku"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(exe.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe

        return await withCheckedContinuation { cont in
            p.terminationHandler = { proc in
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: .ok)
                } else {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(returning: .failed(msg.isEmpty ? "код \(proc.terminationStatus)" : msg))
                }
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(returning: .failed(error.localizedDescription))
                return
            }
            // Не ждём вечно: если завис — прерываем
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }
}
