import Cocoa
import FinderSync

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var statusItem: NSStatusItem?
    private var dirSource: DispatchSourceFileSystemObject?
    private var watchedFd: Int32 = -1
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanLegacyDebugLogs()
        enableExtension()
        setupStatusBar()
        ensureDefaultTemplates()
        setupCommandWatcher()
        FileOperations.log("[HostApp] Running (Unsandboxed Manager).")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusBarItem()
        return true
    }
    
    func applicationWillBecomeActive(_ notification: Notification) {
        showStatusBarItem()
    }
    
    private func enableExtension() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-e", "use", "-i", "com.bruce.QuickMenu.QuickMenuSyncExtension"]
        try? p.run()
    }
    
    private func disableExtensionAndCleanup() {
        // 1. 将扩展在 macOS PlugInKit 中标记为 ignore
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-e", "ignore", "-i", "com.bruce.QuickMenu.QuickMenuSyncExtension"]
        try? p.run()
        p.waitUntilExit()
        
        // 2. 彻底结束残留的扩展进程
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", "QuickMenuSyncEx"]
        try? killProcess.run()
        killProcess.waitUntilExit()
    }
    
    private func cleanLegacyDebugLogs() {
        let homeLog = FileOperations.realHomeURL.appendingPathComponent("quickmenu_debug.log")
        try? FileManager.default.removeItem(at: homeLog)
        let containerLog = ("~/Library/Containers/com.bruce.QuickMenu.QuickMenuSyncExtension/Data/quickmenu_debug.log" as NSString).expandingTildeInPath
        try? FileManager.default.removeItem(atPath: containerLog)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        dirSource?.cancel()
        disableExtensionAndCleanup()
    }
    
    // MARK: - Command Watcher (Kernel DispatchSource)
    private func setupCommandWatcher() {
        let containerDir = ("~/Library/Containers/com.bruce.QuickMenu.QuickMenuSyncExtension/Data" as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: containerDir) {
            try? fm.createDirectory(atPath: containerDir, withIntermediateDirectories: true)
        }
        
        let fd = open(containerDir, O_EVTONLY)
        guard fd >= 0 else {
            FileOperations.log("[HostApp] Failed to open container dir: \(containerDir)")
            return
        }
        self.watchedFd = fd
        
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.checkAndExecuteCommands(containerDir: containerDir)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.dirSource = source
        
        checkAndExecuteCommands(containerDir: containerDir)
    }
    
    private func checkAndExecuteCommands(containerDir: String) {
        let cmdFile = containerDir + "/command.json"
        let fm = FileManager.default
        guard fm.fileExists(atPath: cmdFile) else { return }
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cmdFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else {
            FileOperations.log("[HostApp] command.json exists but unreadable/incomplete, will retry")
            return
        }
        
        try? fm.removeItem(atPath: cmdFile)
        
        FileOperations.log("[HostApp] Executing command: \(command), params: \(json)")
        executeCommand(command: command, params: json)
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            var params: [String: Any] = [:]
            for item in components.queryItems ?? [] {
                params[item.name] = item.value
            }
            if let cmd = params["cmd"] as? String ?? params["command"] as? String {
                executeCommand(command: cmd, params: params)
            }
        }
    }
    
    private func executeCommand(command: String, params: [String: Any]) {
        switch command {
        case "createFile":
            if let folderPath = params["folder"] as? String,
               let defaultName = params["defaultName"] as? String,
               let templateName = params["templateName"] as? String {
                let folderURL = URL(fileURLWithPath: folderPath)
                FileOperations.createFile(defaultName: defaultName, templateName: templateName, in: folderURL)
            }
            
        case "cutFiles":
            if let paths = params["paths"] as? [String] {
                FileOperations.cutFiles(urls: paths.map { URL(fileURLWithPath: $0) })
            }
            
        case "moveFiles":
            if let folderPath = params["folder"] as? String {
                FileOperations.moveCutFiles(to: URL(fileURLWithPath: folderPath))
            }
            
        case "moveFilesToDir":
            if let paths = params["paths"] as? [String],
               let targetDir = params["targetDir"] as? String {
                FileOperations.moveFiles(urls: paths.map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: targetDir))
            }
            
        case "copyFilesToDir":
            if let paths = params["paths"] as? [String],
               let targetDir = params["targetDir"] as? String {
                FileOperations.copyFiles(urls: paths.map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: targetDir))
            }
            
        case "chooseAndMove":
            if let paths = params["paths"] as? [String] {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                chooseDirectoryAndExecute(title: "移动文件到...", prompt: "请选择要移动到的目标文件夹：") { dest in
                    FileOperations.moveFiles(urls: urls, to: dest)
                }
            }
            
        case "chooseAndCopy":
            if let paths = params["paths"] as? [String] {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                chooseDirectoryAndExecute(title: "复制文件到...", prompt: "请选择要复制到的目标文件夹：") { dest in
                    FileOperations.copyFiles(urls: urls, to: dest)
                }
            }
            
        case "compress":
            if let paths = params["paths"] as? [String],
               let folderPath = params["folder"] as? String {
                FileOperations.compressToZip(urls: paths.map { URL(fileURLWithPath: $0) }, in: URL(fileURLWithPath: folderPath))
            }
            
        case "customCompress":
            if let paths = params["paths"] as? [String],
               let folderPath = params["folder"] as? String {
                let urls = paths.map { URL(fileURLWithPath: $0) }
                let folderURL = URL(fileURLWithPath: folderPath)
                showCustomCompressDialog(paths: urls, currentFolder: folderURL)
            }
            
        case "decompress":
            if let archivePath = params["archive"] as? String,
               let folderPath = params["folder"] as? String {
                let archiveURL = URL(fileURLWithPath: archivePath)
                let folderURL = URL(fileURLWithPath: folderPath)
                let mode = params["mode"] as? String ?? "currentFolder"
                let deleteArchive = params["deleteArchive"] as? Bool ?? false
                handleDecompress(archiveURL: archiveURL, currentFolder: folderURL, mode: mode, deleteArchive: deleteArchive)
            }
            
        case "openApp":
            if let app = params["app"] as? String,
               let targetPath = params["target"] as? String {
                let targetURL = URL(fileURLWithPath: targetPath)
                switch app {
                case "wave": FileOperations.openInWave(url: targetURL)
                case "vscode": FileOperations.openInVSCode(url: targetURL)
                case "pycharm": FileOperations.openInPyCharm(url: targetURL)
                case "terminal": FileOperations.openInTerminal(url: targetURL)
                default: break
                }
            }
            
        case "openTemplatesFolder":
            let dir = FileOperations.userTemplatesDirectory
            NSWorkspace.shared.open(dir)
            
        default:
            break
        }
    }
    
    // MARK: - Custom Compress Native Dialog
    private func showCustomCompressDialog(paths: [URL], currentFolder: URL) {
        NSApp.activate(ignoringOtherApps: true)
        
        let alert = NSAlert()
        alert.messageText = "🗜️ 自定义压缩"
        alert.informativeText = "设置压缩文件名、格式及可选密码："
        alert.addButton(withTitle: "立即压缩")
        alert.addButton(withTitle: "取消")
        
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 110))
        
        let defaultBaseName: String = {
            if paths.count == 1 {
                return paths[0].deletingPathExtension().lastPathComponent
            } else {
                return "归档"
            }
        }()
        
        // 1. Name
        let nameLabel = NSTextField(labelWithString: "压缩包名称：")
        nameLabel.frame = NSRect(x: 0, y: 80, width: 90, height: 22)
        nameLabel.alignment = .right
        containerView.addSubview(nameLabel)
        
        let nameField = NSTextField(frame: NSRect(x: 95, y: 80, width: 225, height: 22))
        nameField.stringValue = defaultBaseName
        containerView.addSubview(nameField)
        
        // 2. Format
        let formatLabel = NSTextField(labelWithString: "压缩格式：")
        formatLabel.frame = NSRect(x: 0, y: 45, width: 90, height: 22)
        formatLabel.alignment = .right
        containerView.addSubview(formatLabel)
        
        let formatPopup = NSPopUpButton(frame: NSRect(x: 95, y: 45, width: 225, height: 24), pullsDown: false)
        formatPopup.addItems(withTitles: [".zip (标准常用格式)", ".tar.gz (Linux/开发常用)"])
        containerView.addSubview(formatPopup)
        
        // 3. Password
        let pwdLabel = NSTextField(labelWithString: "密码 (可选)：")
        pwdLabel.frame = NSRect(x: 0, y: 10, width: 90, height: 22)
        pwdLabel.alignment = .right
        containerView.addSubview(pwdLabel)
        
        let pwdField = NSSecureTextField(frame: NSRect(x: 95, y: 10, width: 225, height: 22))
        pwdField.placeholderString = "留空则不设密码"
        containerView.addSubview(pwdField)
        
        alert.accessoryView = containerView
        alert.window.initialFirstResponder = nameField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let chosenName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalBaseName = chosenName.isEmpty ? defaultBaseName : chosenName
            let isZip = (formatPopup.indexOfSelectedItem == 0)
            let password = pwdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            FileOperations.performCustomCompress(
                sourceURLs: paths,
                baseName: finalBaseName,
                isZip: isZip,
                password: password.isEmpty ? nil : password,
                targetFolder: currentFolder
            )
        }
    }
    
    // MARK: - Encrypted Decompress Handler
    private func handleDecompress(archiveURL: URL, currentFolder: URL, mode: String, deleteArchive: Bool) {
        FileOperations.decompressArchive(archiveURL: archiveURL, currentFolder: currentFolder, mode: mode, deleteArchive: deleteArchive) { [weak self] needsPassword in
            if needsPassword {
                DispatchQueue.main.async {
                    self?.promptPasswordAndDecompress(archiveURL: archiveURL, currentFolder: currentFolder, mode: mode, deleteArchive: deleteArchive, retry: false)
                }
            }
        }
    }
    
    private func promptPasswordAndDecompress(archiveURL: URL, currentFolder: URL, mode: String, deleteArchive: Bool, retry: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = retry ? "❌ 密码不正确，请重新输入" : "🔐 解密压缩包"
        alert.informativeText = "该压缩包受密码保护，请输入解压密码："
        alert.addButton(withTitle: "解密并解压")
        alert.addButton(withTitle: "取消")
        
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 35))
        let pwdField = NSSecureTextField(frame: NSRect(x: 0, y: 5, width: 300, height: 22))
        pwdField.placeholderString = "输入解压密码"
        containerView.addSubview(pwdField)
        
        alert.accessoryView = containerView
        alert.window.initialFirstResponder = pwdField
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let password = pwdField.stringValue
            FileOperations.decompressZipWithPassword(archiveURL: archiveURL, currentFolder: currentFolder, mode: mode, deleteArchive: deleteArchive, password: password) { [weak self] success, wrongPassword in
                if !success && wrongPassword {
                    DispatchQueue.main.async {
                        self?.promptPasswordAndDecompress(archiveURL: archiveURL, currentFolder: currentFolder, mode: mode, deleteArchive: deleteArchive, retry: true)
                    }
                }
            }
        }
    }
    
    // MARK: - Choose Directory Modal Dialog
    private func chooseDirectoryAndExecute(title: String, prompt: String, onChosen: @escaping (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = prompt
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        
        let response = panel.runModal()
        if response == .OK, let targetURL = panel.url {
            onChosen(targetURL)
        }
    }
    
    // MARK: - Status Bar Menu
    func setupStatusBar() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.title = "⚡️"
            button.toolTip = "QuickMenu - 访达右键增强"
        }
        
        let menu = NSMenu()
        
        let hideItem = NSMenuItem(title: "关闭菜单栏显示", action: #selector(hideStatusBarItem), keyEquivalent: "h")
        hideItem.target = self
        menu.addItem(hideItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出主程序", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    @objc private func hideStatusBarItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    func showStatusBarItem() {
        if statusItem == nil {
            setupStatusBar()
        }
    }
    
    @objc private func quitApp() {
        disableExtensionAndCleanup()
        NSApp.terminate(nil)
    }
    
    private func ensureDefaultTemplates() {
        let destDir = FileOperations.userTemplatesDirectory
        let fm = FileManager.default
        
        let templateFiles = [
            "新建 文本文档.txt",
            "新建 Markdown.md",
            "新建 Word 文档.docx",
            "新建 Excel 工作表.xlsx",
            "新建 PPT 演示.pptx"
        ]
        
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Templates") else {
            return
        }
        
        for file in templateFiles {
            let src = resourceURL.appendingPathComponent(file)
            let dst = destDir.appendingPathComponent(file)
            if !fm.fileExists(atPath: dst.path) && fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }
}
