import AppKit
import Foundation

do {
    if CommandLine.arguments.contains("--bridge") {
        try LaunchBridge.run()
        exit(0)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--socket") {
        guard CommandLine.arguments.indices.contains(index + 1) else { throw PluginError.invalid("Missing helper socket path.") }
        try LaunchBridge.connectApp(to: CommandLine.arguments[index + 1])
    }
} catch {
    let message = (error as? PluginError)?.message ?? error.localizedDescription
    FileHandle.standardError.write(Data("Apple Music helper launch failed: \(message)\n".utf8))
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let service = MainActor.assumeIsolated { AppleMusicService() }
var mutations: Task<Void, Never>?
let slots = DispatchSemaphore(value: 32)

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        slots.wait()
        Task { @MainActor in
            defer { slots.signal() }
            guard line.utf8.count <= 4_194_304 else {
                Output.error(0, PluginError.invalid("Request is too large.")); return
            }
            let data = Data(line.utf8)
            do {
                let request = try JSONDecoder().decode(Request.self, from: data)
                if request.command.mutates {
                    let previous = mutations
                    let task = Task { @MainActor in
                        await previous?.value
                        await service.execute(request)
                    }
                    mutations = task
                    await task.value
                } else {
                    await service.execute(request)
                }
            } catch {
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let id = object?["id"] as? Int ?? 0
                Output.error(id, error is PluginError ? error : PluginError.invalid("Invalid request JSON or parameters."))
            }
        }
    }
    Task { @MainActor in
        service.shutdown()
        app.terminate(nil)
    }
}
app.run()
