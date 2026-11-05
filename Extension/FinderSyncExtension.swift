import Cocoa
import FinderSync

@objc(QuickMenuSyncExtension)
public class QuickMenuSyncExtension: FIFinderSync {
    
    private var cachedTargetFolder: URL?
    private var cachedSelectedURLs: [URL] = []
    
    override public init() {
        super.init()
        FileOperations.log("QuickMenuSyncExtension initialized")
        
        var monitored = Set<URL>()
        let fm = FileManager.default
        let home = FileOperations.realHomeURL
        
        // 1. 全盘根路径与挂载卷（确保任何层级的空白处均能命中监控）
        monitored.insert(URL(fileURLWithPath: "/"))
        monitored.insert(URL(fileURLWithPath: "/Volumes"))
        monitored.insert(URL(fileURLWithPath: "/Users"))
        monitored.insert(URL(fileURLWithPath: "/Applications"))
        
        // 2. 用户主目录与各关键子目录（桌面、文稿、下载等显式加入，解决 macOS 对桌面容器判定的间歇性丢失）
        monitored.insert(home)
        let standardUserDirs = [
            "Desktop",
            "Downloads",
            "Documents",
            "Pictures",
            "Music",
            "Movies"
        ]
        for dirName in standardUserDirs {
            let u = home.appendingPathComponent(dirName)
            monitored.insert(u)
        }
        
        // 3. iCloud Drive 同步的桌面与文稿（若启用）
        let iCloudDesktop = (("~/Library/Mobile Documents/com~apple~CloudDocs/Desktop" as NSString).expandingTildeInPath)
        if fm.fileExists(atPath: iCloudDesktop) {
            monitored.insert(URL(fileURLWithPath: iCloudDesktop))
        }
        let iCloudDocs = (("~/Library/Mobile Documents/com~apple~CloudDocs/Documents" as NSString).expandingTildeInPath)
        if fm.fileExists(atPath: iCloudDocs) {
            monitored.insert(URL(fileURLWithPath: iCloudDocs))
        }
        
        FIFinderSyncController.default().directoryURLs = monitored
        
        // Asynchronously prewarm all icons, app checks, and templates in background
        DispatchQueue.global(qos: .userInitiated).async {
            FileOperations.prewarmCache()
        }
    }
    
    // MARK: - Directory Observation Handlers (确保访达容器状态始终处于活跃跟踪，避免空白处右击丢单)
    override public func beginObservingDirectory(at url: URL) {
        self.cachedTargetFolder = url
    }
    
    override public func endObservingDirectory(at url: URL) {
    }
    
    // MARK: - Menu Provider
    override public func menu(for menuKind: FIMenuKind) -> NSMenu {
        let startTime = CFAbsoluteTimeGetCurrent()
        let menu = NSMenu(title: "QuickMenu")
        menu.autoenablesItems = false
        
        let isItemsContext = (menuKind == .contextualMenuForItems)
        let selectedURLs = isItemsContext ? (FIFinderSyncController.default().selectedItemURLs() ?? []) : []
        let containerURL = FIFinderSyncController.default().targetedURL()
        
        self.cachedSelectedURLs = selectedURLs
        if let container = containerURL {
            self.cachedTargetFolder = container
        } else if let firstSelected = selectedURLs.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: firstSelected.path, isDirectory: &isDir), isDir.boolValue {
                self.cachedTargetFolder = firstSelected
            } else {
                self.cachedTargetFolder = firstSelected.deletingLastPathComponent()
            }
        }
        
        // 1. 新建文件 (New File Submenu) - 紧凑、连贯、一目了然
        let newFileMenu = NSMenu(title: "新建文件")
        newFileMenu.autoenablesItems = false
        
        func createMenuItem(title: String, action: Selector, icon: NSImage?) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.image = icon
            return item
        }
        
        // TXT
        newFileMenu.addItem(createMenuItem(title: "TXT", action: #selector(actionNewTXT(_:)), icon: FileOperations.iconForFileType(ext: "txt")))
        
        // Markdown
        newFileMenu.addItem(createMenuItem(title: "Markdown", action: #selector(actionNewMarkdown(_:)), icon: FileOperations.iconForFileType(ext: "md")))
        
        // 检测系统办公套件：WPS Office
        let hasWPS = FileOperations.isAppInstalled(path: "/Applications/wpsoffice.app")
        let wpsIcon = FileOperations.iconForApp(path: "/Applications/wpsoffice.app")
        if hasWPS {
            newFileMenu.addItem(createMenuItem(title: "WPS 文字", action: #selector(actionNewWPSDoc(_:)), icon: wpsIcon))
            newFileMenu.addItem(createMenuItem(title: "WPS 表格", action: #selector(actionNewWPSSheet(_:)), icon: wpsIcon))
            newFileMenu.addItem(createMenuItem(title: "WPS 演示", action: #selector(actionNewWPSPpt(_:)), icon: wpsIcon))
        }
        
        // 通用 Office (Word, Excel, PPT)
        newFileMenu.addItem(createMenuItem(title: "Word", action: #selector(actionNewWord(_:)), icon: FileOperations.iconForFileType(ext: "docx")))
        newFileMenu.addItem(createMenuItem(title: "Excel", action: #selector(actionNewExcel(_:)), icon: FileOperations.iconForFileType(ext: "xlsx")))
        newFileMenu.addItem(createMenuItem(title: "PPT", action: #selector(actionNewPPT(_:)), icon: FileOperations.iconForFileType(ext: "pptx")))
        
        // 检测 Apple iWork
        if FileOperations.isAppInstalled(path: "/Applications/Pages.app") {
            newFileMenu.addItem(createMenuItem(title: "Pages", action: #selector(actionNewPages(_:)), icon: FileOperations.iconForApp(path: "/Applications/Pages.app")))
        }
        if FileOperations.isAppInstalled(path: "/Applications/Numbers.app") {
            newFileMenu.addItem(createMenuItem(title: "Numbers", action: #selector(actionNewNumbers(_:)), icon: FileOperations.iconForApp(path: "/Applications/Numbers.app")))
        }
        if FileOperations.isAppInstalled(path: "/Applications/Keynote.app") {
            newFileMenu.addItem(createMenuItem(title: "Keynote", action: #selector(actionNewKeynote(_:)), icon: FileOperations.iconForApp(path: "/Applications/Keynote.app")))
        }
        
        // 自定义模板列表 (从内存缓存极速读取)
        let customTemplates = FileOperations.getCustomTemplates()
        for tmpl in customTemplates {
            let item = createMenuItem(title: tmpl, action: #selector(actionNewCustomTemplate(_:)), icon: FileOperations.iconForFileType(ext: (tmpl as NSString).pathExtension))
            newFileMenu.addItem(item)
        }
        
        // 打开模板文件夹
        let openTemplatesItem = createMenuItem(title: "📂 打开模板文件夹...", action: #selector(actionOpenTemplatesFolder(_:)), icon: nil)
        newFileMenu.addItem(openTemplatesItem)
        
        let newFileRootItem = NSMenuItem(title: "📄 新建文件", action: nil, keyEquivalent: "")
        newFileRootItem.submenu = newFileMenu
        newFileRootItem.isEnabled = true
        menu.addItem(newFileRootItem)
        
        // 2. 快捷打开 (Open In Submenu)
        let openInMenu = NSMenu(title: "快捷打开")
        openInMenu.autoenablesItems = false
        
        if FileOperations.isAppInstalled(path: "/Applications/Wave.app") {
            openInMenu.addItem(createMenuItem(title: "Wave 终端", action: #selector(actionOpenWave(_:)), icon: FileOperations.iconForApp(path: "/Applications/Wave.app")))
        }
        if FileOperations.isAppInstalled(path: "/Applications/Visual Studio Code.app") {
            openInMenu.addItem(createMenuItem(title: "VS Code", action: #selector(actionOpenVSCode(_:)), icon: FileOperations.iconForApp(path: "/Applications/Visual Studio Code.app")))
        }
        if FileOperations.isAppInstalled(path: "/Applications/PyCharm.app") {
            openInMenu.addItem(createMenuItem(title: "PyCharm", action: #selector(actionOpenPyCharm(_:)), icon: FileOperations.iconForApp(path: "/Applications/PyCharm.app")))
        }
        openInMenu.addItem(createMenuItem(title: "系统终端", action: #selector(actionOpenTerminal(_:)), icon: FileOperations.iconForApp(path: "/System/Applications/Utilities/Terminal.app")))
        
        let openInRootItem = NSMenuItem(title: "🚀 快捷打开", action: nil, keyEquivalent: "")
        openInRootItem.submenu = openInMenu
        openInRootItem.isEnabled = true
        menu.addItem(openInRootItem)
        
        // 3. 拷贝路径 (Copy Path)
        let copyMenu = NSMenu(title: "拷贝路径")
        copyMenu.autoenablesItems = false
        copyMenu.addItem(createMenuItem(title: "绝对路径", action: #selector(actionCopyFullPath(_:)), icon: nil))
        copyMenu.addItem(createMenuItem(title: "文件名", action: #selector(actionCopyFilename(_:)), icon: nil))
        copyMenu.addItem(createMenuItem(title: "终端转义路径", action: #selector(actionCopyEscapedPath(_:)), icon: nil))
        
        let copyPathRootItem = NSMenuItem(title: "📋 拷贝路径", action: nil, keyEquivalent: "")
        copyPathRootItem.submenu = copyMenu
        copyPathRootItem.isEnabled = true
        menu.addItem(copyPathRootItem)
        
        // 4. 剪切 (Cut) - 仅当右键点击选中的具体文件时显示
        if isItemsContext && !selectedURLs.isEmpty {
            menu.addItem(createMenuItem(title: "✂️ 剪切 \(selectedURLs.count) 项", action: #selector(actionCutFiles(_:)), icon: nil))
        }
        
        // 5. 粘贴移动 (Move Here) - 只有剪切板里确实有待移动文件时才显示
        if let cutFiles = FileOperations.getCutFiles(), !cutFiles.isEmpty {
            menu.addItem(createMenuItem(title: "📌 移动 \(cutFiles.count) 项到此处", action: #selector(actionMoveFiles(_:)), icon: nil))
        }
        
        // 6. 移动文件到 / 复制文件到 (Move To / Copy To) - 仅当右键点击选中的具体文件时显示
        if isItemsContext && !selectedURLs.isEmpty {
            // 移动文件到
            let moveToMenu = NSMenu(title: "移动文件到")
            moveToMenu.autoenablesItems = false
            moveToMenu.addItem(createMenuItem(title: "下载", action: #selector(actionMoveToDownloads(_:)), icon: FileOperations.iconForApp(path: FileOperations.downloadsURL.path)))
            moveToMenu.addItem(createMenuItem(title: "图片", action: #selector(actionMoveToPictures(_:)), icon: FileOperations.iconForApp(path: FileOperations.picturesURL.path)))
            moveToMenu.addItem(createMenuItem(title: "音乐", action: #selector(actionMoveToMusic(_:)), icon: FileOperations.iconForApp(path: FileOperations.musicURL.path)))
            moveToMenu.addItem(createMenuItem(title: "影片", action: #selector(actionMoveToMovies(_:)), icon: FileOperations.iconForApp(path: FileOperations.moviesURL.path)))
            moveToMenu.addItem(createMenuItem(title: "文稿", action: #selector(actionMoveToDocuments(_:)), icon: FileOperations.iconForApp(path: FileOperations.documentsURL.path)))
            moveToMenu.addItem(createMenuItem(title: "自定义路径...", action: #selector(actionMoveToCustom(_:)), icon: nil))
            
            let moveToRootItem = NSMenuItem(title: "📦 移动文件到", action: nil, keyEquivalent: "")
            moveToRootItem.submenu = moveToMenu
            moveToRootItem.isEnabled = true
            menu.addItem(moveToRootItem)
            
            // 复制文件到
            let copyToMenu = NSMenu(title: "复制文件到")
            copyToMenu.autoenablesItems = false
            copyToMenu.addItem(createMenuItem(title: "下载", action: #selector(actionCopyToDownloads(_:)), icon: FileOperations.iconForApp(path: FileOperations.downloadsURL.path)))
            copyToMenu.addItem(createMenuItem(title: "图片", action: #selector(actionCopyToPictures(_:)), icon: FileOperations.iconForApp(path: FileOperations.picturesURL.path)))
            copyToMenu.addItem(createMenuItem(title: "音乐", action: #selector(actionCopyToMusic(_:)), icon: FileOperations.iconForApp(path: FileOperations.musicURL.path)))
            copyToMenu.addItem(createMenuItem(title: "影片", action: #selector(actionCopyToMovies(_:)), icon: FileOperations.iconForApp(path: FileOperations.moviesURL.path)))
            copyToMenu.addItem(createMenuItem(title: "文稿", action: #selector(actionCopyToDocuments(_:)), icon: FileOperations.iconForApp(path: FileOperations.documentsURL.path)))
            copyToMenu.addItem(createMenuItem(title: "自定义路径...", action: #selector(actionCopyToCustom(_:)), icon: nil))
            
            let copyToRootItem = NSMenuItem(title: "📑 复制文件到", action: nil, keyEquivalent: "")
            copyToRootItem.submenu = copyToMenu
            copyToRootItem.isEnabled = true
            menu.addItem(copyToRootItem)
        }
        
        // 7. 压缩与解压系列选项
        if isItemsContext && !selectedURLs.isEmpty {
            let isSingleArchive = (selectedURLs.count == 1 && FileOperations.isArchiveFile(url: selectedURLs[0]))
            
            if isSingleArchive {
                // 压缩文件上的4项专属操作：
                menu.addItem(createMenuItem(title: "📂 解压到当前文件夹", action: #selector(actionDecompressToCurrentFolder(_:)), icon: nil))
                menu.addItem(createMenuItem(title: "📁 解压到单独文件夹", action: #selector(actionDecompressToSeparateFolder(_:)), icon: nil))
                menu.addItem(createMenuItem(title: "🗑️ 解压到单独文件夹并删除原压缩包", action: #selector(actionDecompressToSeparateFolderAndDelete(_:)), icon: nil))
                menu.addItem(createMenuItem(title: "🗜️ 自定义压缩...", action: #selector(actionCustomCompress(_:)), icon: nil))
            } else {
                // 普通文件或文件夹：
                menu.addItem(createMenuItem(title: "🗜️ 压缩为 ZIP", action: #selector(actionCompressZip(_:)), icon: nil))
                menu.addItem(createMenuItem(title: "🗜️ 自定义压缩...", action: #selector(actionCustomCompress(_:)), icon: nil))
            }
        }
        
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        NSLog("[QuickMenu] menu(for: %ld) built in %.3f ms", menuKind.rawValue, elapsed)
        return menu
    }
    
    // MARK: - Target Resolution Helpers
    private func resolveTargetFolder() -> URL {
        if let container = FIFinderSyncController.default().targetedURL() {
            return container
        }
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        if let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                return first
            }
            return first.deletingLastPathComponent()
        }
        if let cached = cachedTargetFolder {
            return cached
        }
        return FileOperations.realHomeURL.appendingPathComponent("Desktop")
    }
    
    private func resolveSelectedOrTargetURL() -> URL {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        if let first = selected.first {
            return first
        }
        return resolveTargetFolder()
    }
    
    private func getSelectedURLs() -> [URL] {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        if !selected.isEmpty {
            return selected
        }
        if !cachedSelectedURLs.isEmpty {
            return cachedSelectedURLs
        }
        return [resolveTargetFolder()]
    }
    
    // MARK: - Dispatch Command to Host App (Atomic file write)
    private func dispatchCommand(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else { return }
        let containerDir = NSHomeDirectory()
        let tmpFileURL = URL(fileURLWithPath: containerDir).appendingPathComponent("command_tmp.json")
        let cmdFileURL = URL(fileURLWithPath: containerDir).appendingPathComponent("command.json")
        do {
            try data.write(to: tmpFileURL)
            if FileManager.default.fileExists(atPath: cmdFileURL.path) {
                try? FileManager.default.removeItem(at: cmdFileURL)
            }
            try FileManager.default.moveItem(at: tmpFileURL, to: cmdFileURL)
            FileOperations.log("Dispatched command atomically: \(payload)")
        } catch {
            FileOperations.log("Failed to dispatch command: \(error)")
        }
    }
    
    private func dispatchCreateFile(defaultName: String, templateName: String) {
        let folder = resolveTargetFolder()
        FileOperations.log("dispatchCreateFile -> defaultName: \(defaultName), folder: \(folder.path)")
        dispatchCommand([
            "command": "createFile",
            "folder": folder.path,
            "defaultName": defaultName,
            "templateName": templateName
        ])
    }
    
    // MARK: - Actions: New Files
    @objc public func actionNewTXT(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建文本.txt", templateName: "新建 文本文档.txt")
    }
    
    @objc public func actionNewMarkdown(_ sender: Any) {
        dispatchCreateFile(defaultName: "未命名.md", templateName: "新建 Markdown.md")
    }
    
    @objc public func actionNewWord(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建文档.docx", templateName: "新建 Word 文档.docx")
    }
    
    @objc public func actionNewExcel(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建表格.xlsx", templateName: "新建 Excel 工作表.xlsx")
    }
    
    @objc public func actionNewPPT(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建演示.pptx", templateName: "新建 PPT 演示.pptx")
    }
    
    @objc public func actionNewWPSDoc(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建文档.docx", templateName: "新建 Word 文档.docx")
    }
    
    @objc public func actionNewWPSSheet(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建表格.xlsx", templateName: "新建 Excel 工作表.xlsx")
    }
    
    @objc public func actionNewWPSPpt(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建演示.pptx", templateName: "新建 PPT 演示.pptx")
    }
    
    @objc public func actionNewPages(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建文档.pages", templateName: "新建 文本文档.txt")
    }
    
    @objc public func actionNewNumbers(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建表格.numbers", templateName: "新建 Excel 工作表.xlsx")
    }
    
    @objc public func actionNewKeynote(_ sender: Any) {
        dispatchCreateFile(defaultName: "新建演示.key", templateName: "新建 PPT 演示.pptx")
    }
    
    @objc public func actionNewCustomTemplate(_ sender: NSMenuItem) {
        dispatchCreateFile(defaultName: sender.title, templateName: sender.title)
    }
    
    @objc public func actionOpenTemplatesFolder(_ sender: Any) {
        dispatchCommand(["command": "openTemplatesFolder"])
    }
    
    // MARK: - Actions: Open In
    @objc public func actionOpenWave(_ sender: Any) {
        let target = resolveSelectedOrTargetURL()
        dispatchCommand(["command": "openApp", "app": "wave", "target": target.path])
    }
    
    @objc public func actionOpenVSCode(_ sender: Any) {
        let target = resolveSelectedOrTargetURL()
        dispatchCommand(["command": "openApp", "app": "vscode", "target": target.path])
    }
    
    @objc public func actionOpenPyCharm(_ sender: Any) {
        let target = resolveSelectedOrTargetURL()
        dispatchCommand(["command": "openApp", "app": "pycharm", "target": target.path])
    }
    
    @objc public func actionOpenTerminal(_ sender: Any) {
        let target = resolveSelectedOrTargetURL()
        dispatchCommand(["command": "openApp", "app": "terminal", "target": target.path])
    }
    
    // MARK: - Actions: Copy Path
    @objc public func actionCopyFullPath(_ sender: Any) {
        let urls = getSelectedURLs()
        FileOperations.copyPaths(urls: urls, style: .absolute)
    }
    
    @objc public func actionCopyFilename(_ sender: Any) {
        let urls = getSelectedURLs()
        FileOperations.copyPaths(urls: urls, style: .filename)
    }
    
    @objc public func actionCopyEscapedPath(_ sender: Any) {
        let urls = getSelectedURLs()
        FileOperations.copyPaths(urls: urls, style: .escaped)
    }
    
    // MARK: - Actions: Cut & Move
    @objc public func actionCutFiles(_ sender: Any) {
        let urls = getSelectedURLs()
        FileOperations.cutFiles(urls: urls)
    }
    
    @objc public func actionMoveFiles(_ sender: Any) {
        let folder = resolveTargetFolder()
        dispatchCommand(["command": "moveFiles", "folder": folder.path])
    }
    
    // MARK: - Actions: Compress & Decompress
    @objc public func actionCompressZip(_ sender: Any) {
        let urls = getSelectedURLs()
        let folder = resolveTargetFolder()
        dispatchCommand(["command": "compress", "paths": urls.map { $0.path }, "folder": folder.path])
    }
    
    @objc public func actionCustomCompress(_ sender: Any) {
        let urls = getSelectedURLs()
        let folder = resolveTargetFolder()
        dispatchCommand(["command": "customCompress", "paths": urls.map { $0.path }, "folder": folder.path])
    }
    
    @objc public func actionDecompressToCurrentFolder(_ sender: Any) {
        let urls = getSelectedURLs()
        if let firstArchive = urls.first {
            let folder = resolveTargetFolder()
            dispatchCommand([
                "command": "decompress",
                "mode": "currentFolder",
                "archive": firstArchive.path,
                "folder": folder.path
            ])
        }
    }
    
    @objc public func actionDecompressToSeparateFolder(_ sender: Any) {
        let urls = getSelectedURLs()
        if let firstArchive = urls.first {
            let folder = resolveTargetFolder()
            dispatchCommand([
                "command": "decompress",
                "mode": "separateFolder",
                "deleteArchive": false,
                "archive": firstArchive.path,
                "folder": folder.path
            ])
        }
    }
    
    @objc public func actionDecompressToSeparateFolderAndDelete(_ sender: Any) {
        let urls = getSelectedURLs()
        if let firstArchive = urls.first {
            let folder = resolveTargetFolder()
            dispatchCommand([
                "command": "decompress",
                "mode": "separateFolder",
                "deleteArchive": true,
                "archive": firstArchive.path,
                "folder": folder.path
            ])
        }
    }
    
    // MARK: - Actions: Move To Directory
    @objc public func actionMoveToDownloads(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "moveFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.downloadsURL.path])
    }
    @objc public func actionMoveToPictures(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "moveFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.picturesURL.path])
    }
    @objc public func actionMoveToMusic(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "moveFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.musicURL.path])
    }
    @objc public func actionMoveToMovies(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "moveFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.moviesURL.path])
    }
    @objc public func actionMoveToDocuments(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "moveFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.documentsURL.path])
    }
    @objc public func actionMoveToCustom(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "chooseAndMove", "paths": urls.map { $0.path }])
    }
    
    // MARK: - Actions: Copy To Directory
    @objc public func actionCopyToDownloads(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "copyFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.downloadsURL.path])
    }
    @objc public func actionCopyToPictures(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "copyFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.picturesURL.path])
    }
    @objc public func actionCopyToMusic(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "copyFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.musicURL.path])
    }
    @objc public func actionCopyToMovies(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "copyFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.moviesURL.path])
    }
    @objc public func actionCopyToDocuments(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "copyFilesToDir", "paths": urls.map { $0.path }, "targetDir": FileOperations.documentsURL.path])
    }
    @objc public func actionCopyToCustom(_ sender: Any) {
        let urls = getSelectedURLs()
        dispatchCommand(["command": "chooseAndCopy", "paths": urls.map { $0.path }])
    }
}
