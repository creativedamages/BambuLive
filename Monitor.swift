import AppKit
import Darwin
import IOKit.pwr_mgt
import ServiceManagement

final class Monitor: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let status = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
    let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let dashboard = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
    let endpoint = URL(string: "http://127.0.0.1:8080/")!
    var child: Process?
    var timer: Timer?
    var assertion: IOPMAssertionID = 0
    var keepAwake = false
    var restartPending = false
    var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "BambuLive"
        let menu = NSMenu()
        menu.autoenablesItems = false
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(dashboard)
        menu.addItem(withTitle: "Choose Dashboard Folder…", action: #selector(chooseFolder), keyEquivalent: "")
        menu.addItem(withTitle: "Restart Service", action: #selector(restart), keyEquivalent: "")
        menu.addItem(login)
        menu.addItem(withTitle: "Open Service Log", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit BambuLive", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items where entry.action != nil { entry.target = self }
        item.menu = menu
        updateLogin()
        dashboard.isEnabled = false
        if UserDefaults.standard.string(forKey: "dashboardFolder") != nil { start() }
        else { status.title = "Choose your dashboard folder" }
    }

    func alert(_ message: String) {
        let box = NSAlert()
        box.messageText = "BambuLive"
        box.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        box.runModal()
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the working dashboard folder containing server.js and printers.json."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let required = ["server.js", "printers.json"]
        guard required.allSatisfy({ FileManager.default.isReadableFile(atPath: folder.appendingPathComponent($0).path) }) else {
            alert("This folder must contain readable server.js and printers.json files.")
            return
        }
        UserDefaults.standard.set(folder.path, forKey: "dashboardFolder")
        restart()
    }

    func portAvailable() -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(8080).bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func start() {
        guard let path = UserDefaults.standard.string(forKey: "dashboardFolder") else { return }
        guard portAvailable() else {
            status.title = "Port 8080 is occupied"
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("server.js").path),
              FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("printers.json").path),
              let node = Bundle.main.url(forAuxiliaryExecutable: "node") else {
            status.title = "Dashboard folder or Node runtime missing"
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = node
        process.currentDirectoryURL = folder
        process.arguments = ["server.js"]
        process.environment = environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]) { _, replacement in replacement }
        process.standardInput = FileHandle.nullDevice
        guard let log = try? prepareLog() else {
            status.title = "Could not open the service log"
            return
        }
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.finished(finished) }
        }
        do {
            try process.run()
            child = process
            status.title = "Waiting for dashboard on port 8080"
            keepAwake = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "BambuLive is serving the printer dashboard" as CFString,
                &assertion
            ) == kIOReturnSuccess
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkDashboard() }
            checkDashboard()
        } catch {
            status.title = "Could not start the dashboard"
        }
    }

    var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BambuLive/service.log")
    }

    func prepareLog() throws -> FileHandle {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    @objc func openLog() {
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else { alert("The service log will appear after the first start attempt.") }
    }

    func checkDashboard() {
        guard let process = child, process.isRunning, !restartPending, !terminating else { return }
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let healthy = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
            DispatchQueue.main.async {
                guard let self, self.child === process, !self.restartPending, !self.terminating else { return }
                self.dashboard.isEnabled = healthy
                self.status.title = healthy ? "Dashboard running" : "Dashboard unavailable on port 8080"
            }
        }.resume()
    }

    func finished(_ process: Process) {
        guard child === process else { return }
        child = nil
        timer?.invalidate()
        timer = nil
        dashboard.isEnabled = false
        if keepAwake { IOPMAssertionRelease(assertion) }
        keepAwake = false
        if terminating { NSApp.reply(toApplicationShouldTerminate: true) }
        else if restartPending {
            restartPending = false
            start()
        } else { status.title = "Server stopped (exit \(process.terminationStatus))" }
    }

    func stop(_ process: Process) {
        dashboard.isEnabled = false
        status.title = "Stopping dashboard…"
        if process.isRunning { process.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard self?.child === process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    @objc func restart() {
        if let child {
            restartPending = true
            stop(child)
        } else { start() }
    }

    @objc func openDashboard() { NSWorkspace.shared.open(endpoint) }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let child else { return .terminateNow }
        terminating = true
        stop(child)
        return .terminateLater
    }

    func updateLogin() {
        let state = SMAppService.mainApp.status
        login.state = state == .enabled || state == .requiresApproval ? .on : .off
        login.title = state == .requiresApproval ? "Start at Login (Approval Required)" : "Start at Login"
    }

    @objc func toggleLogin() {
        defer { updateLogin() }
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
        } catch {
            alert("Move BambuLive to Applications and check Login Items in System Settings.\n\n\(error.localizedDescription)")
        }
    }
}

let delegate = Monitor()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
