import Foundation

public struct ProcessResult {
    public var status: Int32
    public var out: Data
    public var err: String
    public var timedOut = false
    public var ok: Bool { status == 0 && !timedOut }
}

public enum Shell {
    /// Runs a program to completion, feeding `stdin` and collecting stdout without deadlocking on large output.
    public static func run(_ exe: String, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 60) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        do { try p.run() } catch { return ProcessResult(status: 127, out: Data(), err: "\(exe): \(error.localizedDescription)") }
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        let io = DispatchQueue(label: "tach.shell.io", attributes: .concurrent)
        group.enter(); io.async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); io.async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        io.async {
            if let stdin { try? inp.fileHandleForWriting.write(contentsOf: stdin) }
            try? inp.fileHandleForWriting.close()
        }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return ProcessResult(status: p.terminationStatus, out: outData, err: String(decoding: errData.prefix(4000), as: UTF8.self), timedOut: timedOut)
    }

    /// Splits a command-line fragment into arguments, honouring single and double quotes.
    public static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            } else {
                cur.append(ch)
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Runs `tach-collector` on this Mac and, over SSH, on remote machines.
public struct Collector {
    /// Must match `Version` in collector/cmd/tach-collector/main.go.
    public static let version = "0.1.2"
    static let remotePath = "~/.cache/tach/tach-collector"

    /// Directory holding `tach-collector-<os>-<arch>` binaries.
    public var directory: URL

    public init?(directory: URL? = nil) {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let directory { candidates.append(directory) }
        if let e = ProcessInfo.processInfo.environment["TACH_COLLECTOR_DIR"] { candidates.append(URL(fileURLWithPath: e)) }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("collector")) }
        // development: <repo>/collector/bin next to <repo>/app
        var up = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<4 { candidates.append(up.appendingPathComponent("collector/bin")); up.deleteLastPathComponent() }
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.appendingPathComponent(Self.binaryName(os: "darwin", arch: Self.hostArch)).path) }) else { return nil }
        self.directory = found
    }

    static var hostArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    static func binaryName(os: String, arch: String) -> String { "tach-collector-\(os)-\(arch)" }

    /// Maps `uname -sm` output to a binary name.
    public static func binaryName(uname: String) -> String? {
        let p = uname.lowercased().split(separator: " ").map(String.init)
        guard p.count >= 2 else { return nil }
        let os = p[0] == "darwin" ? "darwin" : p[0] == "linux" ? "linux" : nil
        let arch = ["x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"][p[1]]
        guard let os, let arch else { return nil }
        return binaryName(os: os, arch: arch)
    }

    public func local(_ args: [String], stdin: Data? = nil, timeout: TimeInterval = 300) -> ProcessResult {
        Shell.run(directory.appendingPathComponent(Self.binaryName(os: "darwin", arch: Self.hostArch)).path, args, stdin: stdin, timeout: timeout)
    }

    public static func sshArguments(_ m: MachineConfig) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"] + Shell.split(m.options) + [m.target]
    }

    public func ssh(_ m: MachineConfig, _ command: String, stdin: Data? = nil, timeout: TimeInterval = 300) -> ProcessResult {
        Shell.run("/usr/bin/ssh", Self.sshArguments(m) + [command], stdin: stdin, timeout: timeout)
    }

    public func remote(_ m: MachineConfig, _ args: [String], stdin: Data? = nil, timeout: TimeInterval = 300) -> ProcessResult {
        ssh(m, ([Self.remotePath] + args.map(Shell.quote)).joined(separator: " "), stdin: stdin, timeout: timeout)
    }

    public struct RemoteError: Error, CustomStringConvertible { public var description: String }

    /// Makes sure the remote has this version of the collector, uploading it when needed.
    /// Returns the `uname -sm` of the remote.
    @discardableResult
    public func ensureRemote(_ m: MachineConfig) throws -> String {
        let probe = ssh(m, "uname -sm; [ -x \(Self.remotePath) ] && \(Self.remotePath) version || echo none", timeout: 30)
        guard probe.ok else { throw RemoteError(description: Self.explain(probe)) }
        let lines = String(decoding: probe.out, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let uname = lines.first, let name = Self.binaryName(uname: uname) else { throw RemoteError(description: "Unsupported system: \(lines.first ?? "unknown")") }
        if lines.count > 1, lines[1] == Self.version { return uname }
        let bin = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: bin) else { throw RemoteError(description: "No collector build for \(uname) in this copy of Tach") }
        let up = ssh(m, "mkdir -p ~/.cache/tach && cat > \(Self.remotePath).tmp && chmod 755 \(Self.remotePath).tmp && mv \(Self.remotePath).tmp \(Self.remotePath) && \(Self.remotePath) version", stdin: data, timeout: 120)
        guard up.ok, String(decoding: up.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == Self.version else {
            throw RemoteError(description: "Could not install the collector: " + Self.explain(up))
        }
        return uname
    }

    /// A short, readable reason for a failed ssh call.
    public static func explain(_ r: ProcessResult) -> String {
        if r.timedOut { return "Timed out" }
        let all = r.err
        let e = all.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if all.contains("Permission denied") { return "SSH key not accepted" }
        if all.contains("Host key verification failed") { return "Host key not trusted yet: connect once with ssh" }
        if all.contains("Could not resolve hostname") { return "Host name not found" }
        if all.contains("timed out") { return "Connection timed out" }
        if all.contains("Connection refused") { return "Connection refused" }
        if all.contains("SOCKS error") || all.contains("connection failed") || all.contains("Connection closed by") || all.contains("No route to host") { return "Could not connect" }
        return e.isEmpty ? "ssh exited with status \(r.status)" : e
    }
}
