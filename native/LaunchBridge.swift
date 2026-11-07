import AppKit
import Darwin
import Foundation

private var launchBridgeInterrupted: sig_atomic_t = 0

enum LaunchBridge {

    private static func failure(_ operation: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"])
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var result = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: result.sun_path) else {
            throw PluginError.invalid("Helper socket path is too long.")
        }
        result.sun_family = sa_family_t(AF_UNIX)
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &result.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        return result
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var value = try address(path)
        return withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func connectApp(to path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw failure("Create helper connection") }
        defer { Darwin.close(descriptor) }
        guard try withAddress(path, { Darwin.connect(descriptor, $0, $1) }) == 0 else { throw failure("Connect helper") }
        guard dup2(descriptor, STDIN_FILENO) >= 0, dup2(descriptor, STDOUT_FILENO) >= 0 else { throw failure("Attach helper streams") }
        signal(SIGPIPE, SIG_IGN)
    }

    static func run() throws {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in launchBridgeInterrupted = 1 }
        signal(SIGINT) { _ in launchBridgeInterrupted = 1 }
        siginterrupt(SIGTERM, 1)
        siginterrupt(SIGINT, 1)
        var template = Array("/tmp/mygo-am.XXXXXX".utf8CString)
        guard let temporary = mkdtemp(&template) else { throw failure("Create private helper directory") }
        let directory = String(cString: temporary)
        let path = directory + "/rpc"
        defer { unlink(path); rmdir(directory) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw failure("Create helper listener") }
        defer { Darwin.close(listener) }
        guard fcntl(listener, F_SETFD, FD_CLOEXEC) == 0 else { throw failure("Protect helper listener") }
        guard try withAddress(path, { Darwin.bind(listener, $0, $1) }) == 0 else { throw failure("Bind helper listener") }
        guard chmod(path, 0o600) == 0, listen(listener, 1) == 0 else { throw failure("Prepare helper listener") }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var arguments = ["-n", "-g", "-W", Bundle.main.bundleURL.path, "--args", "--socket", path]
        if let index = CommandLine.arguments.firstIndex(of: "--language"), CommandLine.arguments.indices.contains(index + 1) {
            arguments += ["--language", CommandLine.arguments[index + 1]]
        }
        launcher.arguments = arguments
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.standardError
        try launcher.run()
        defer { if launcher.isRunning { launcher.terminate() } }
        let deadline = Date().addingTimeInterval(15)
        var connection: Int32 = -1
        while launchBridgeInterrupted == 0 && Date() < deadline {
            var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 200)
            if ready < 0 && errno != EINTR { throw failure("Wait for helper") }
            if ready > 0 && event.revents & Int16(POLLIN) != 0 {
                connection = accept(listener, nil, nil)
                guard connection >= 0 else { throw failure("Accept helper") }
                break
            }
            if ready > 0 { throw PluginError.invalid("Helper listener closed before the app connected.") }
            if !launcher.isRunning { throw PluginError.invalid("LaunchServices could not start the Apple Music helper.") }
        }
        guard connection >= 0 else { throw PluginError.invalid("Apple Music helper did not connect within 15 seconds.") }
        defer { Darwin.close(connection) }
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(connection, &user, &group) == 0, user == getuid() else { throw PluginError.invalid("Unexpected helper connection owner.") }
        try relay(connection)
    }

    private static func relay(_ connection: Int32) throws {
        var inputOpen = true
        var finishDeadline: Date?
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while launchBridgeInterrupted == 0 {
            if let finishDeadline, Date() >= finishDeadline { return }
            var events = [pollfd(fd: inputOpen ? STDIN_FILENO : -1, events: Int16(POLLIN), revents: 0),
                          pollfd(fd: connection, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&events, nfds_t(events.count), 200)
            if ready < 0 {
                if errno == EINTR { continue }
                throw failure("Read helper streams")
            }
            for index in events.indices where events[index].revents != 0 {
                let count = Darwin.read(events[index].fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("Read helper stream")
                }
                if count == 0 {
                    if index == 1 { return }
                    inputOpen = false
                    shutdown(connection, SHUT_WR)
                    finishDeadline = Date().addingTimeInterval(5)
                    continue
                }
                let destination = index == 0 ? connection : STDOUT_FILENO
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count && launchBridgeInterrupted == 0 {
                        let written = Darwin.write(destination, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            throw failure("Write helper stream")
                        }
                        offset += written
                    }
                }
            }
        }
    }
}
