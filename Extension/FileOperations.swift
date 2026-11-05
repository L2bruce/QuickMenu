import Cocoa
import UniformTypeIdentifiers

public enum PathCopyStyle {
    case absolute
    case filename
    case escaped
}

public class FileOperations {
    
    // Custom pasteboard type for cut operations
    public static let cutPasteboardType = NSPasteboard.PasteboardType("com.bruce.quickmenu.cutpaths")
    
    // Archive extensions supported
    public static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "z"
    ]
    
    public static func isArchiveFile(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return archiveExtensions.contains(ext)
    }
    
    public static func log(_ message: String) {
        NSLog("[QuickMenu] %@", message)
    }
    
    // MARK: - User Directories & Template Path
    public static let realHomeURL: URL = {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let path = FileManager.default.string(withFileSystemRepresentation: home, length: strlen(home))
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())")
    }()
    
    public static let downloadsURL: URL = realHomeURL.appendingPathComponent("Downloads")
    public static let picturesURL: URL = realHomeURL.appendingPathComponent("Pictures")
    public static let musicURL: URL = realHomeURL.appendingPathComponent("Music")
    public static let moviesURL: URL = realHomeURL.appendingPathComponent("Movies")
    public static let documentsURL: URL = realHomeURL.appendingPathComponent("Documents")

    public static let userTemplatesDirectory: URL = {
        let dir = realHomeURL.appendingPathComponent("Library/Application Support/QuickMenu/Templates", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()
    
    // MARK: - In-Memory Caches for Instant Menu Rendering
    private static let cacheLock = NSLock()
    private static var appInstalledCache: [String: Bool] = [:]
    private static var appIconCache: [String: NSImage] = [:]
    private static var fileTypeIconCache: [String: NSImage] = [:]
    private static var lastPasteboardChangeCount: Int = -1
    private static var cachedCutURLs: [URL]? = nil
    private static var cachedCustomTemplates: [String] = []
    private static var lastTemplatesCheckTime: TimeInterval = 0

    // MARK: - App Detection & Icons
    public static func isAppInstalled(path: String) -> Bool {
        cacheLock.lock()
        if let cached = appInstalledCache[path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        let installed = FileManager.default.fileExists(atPath: path)
        cacheLock.lock()
        appInstalledCache[path] = installed
        cacheLock.unlock()
        return installed
    }
    
    /// 将系统大图标光栅化为单个紧凑的 32x32 (@2x Retina, 16pt) 单张位图表示。
    /// 解决系统原始图标序列化导致上百兆 XPC 传输与右键严重延迟的核心性能瓶颈！
    public static func rasterizeToMenuIcon(_ source: NSImage) -> NSImage {
        let targetSize = NSSize(width: 16, height: 16)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            source.size = targetSize
            return source
        }
        rep.size = targetSize
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        
        let finalImage = NSImage(size: targetSize)
        finalImage.addRepresentation(rep)
        return finalImage
    }
    
    public static func iconForApp(path: String) -> NSImage? {
        cacheLock.lock()
        if let cached = appIconCache[path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let rawIcon = NSWorkspace.shared.icon(forFile: path)
        let cleanIcon = rasterizeToMenuIcon(rawIcon)
        
        cacheLock.lock()
        appIconCache[path] = cleanIcon
        cacheLock.unlock()
        return cleanIcon
    }
    
    public static func iconForFileType(ext: String) -> NSImage? {
        let key = ext.lowercased()
        cacheLock.lock()
        if let cached = fileTypeIconCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        var img: NSImage?
        if #available(macOS 12.0, *), let uti = UTType(filenameExtension: key) {
            img = NSWorkspace.shared.icon(for: uti)
        } else {
            img = NSWorkspace.shared.icon(forFileType: key)
        }
        let rawImg = img ?? NSImage(size: NSSize(width: 16, height: 16))
        let cleanImg = rasterizeToMenuIcon(rawImg)
        
        cacheLock.lock()
        fileTypeIconCache[key] = cleanImg
        cacheLock.unlock()
        return cleanImg
    }
    
    // MARK: - Custom Templates with 5s In-Memory Cache
    public static func getCustomTemplates() -> [String] {
        let now = Date().timeIntervalSince1970
        cacheLock.lock()
        if now - lastTemplatesCheckTime < 5.0 {
            let res = cachedCustomTemplates
            cacheLock.unlock()
            return res
        }
        cacheLock.unlock()
        
        let dir = userTemplatesDirectory
        let defaultNames: Set<String> = [
            "新建 文本文档.txt",
            "新建 Markdown.md",
            "新建 Word 文档.docx",
            "新建 Excel 工作表.xlsx",
            "新建 PPT 演示.pptx"
        ]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let filtered = files.filter { !$0.hasPrefix(".") && !defaultNames.contains($0) }
        
        cacheLock.lock()
        cachedCustomTemplates = filtered
        lastTemplatesCheckTime = now
        cacheLock.unlock()
        return filtered
    }
    
    // MARK: - Background Cache Pre-warming
    public static func prewarmCache() {
        for ext in ["txt", "md", "docx", "xlsx", "pptx", "pages", "numbers", "key"] {
            _ = iconForFileType(ext: ext)
        }
        let apps = [
            "/Applications/wpsoffice.app",
            "/Applications/Wave.app",
            "/Applications/Visual Studio Code.app",
            "/Applications/PyCharm.app",
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Pages.app",
            "/Applications/Numbers.app",
            "/Applications/Keynote.app"
        ]
        for app in apps {
            if isAppInstalled(path: app) {
                _ = iconForApp(path: app)
            }
        }
        let folders = [
            downloadsURL.path,
            picturesURL.path,
            musicURL.path,
            moviesURL.path,
            documentsURL.path
        ]
        for folder in folders {
            _ = iconForApp(path: folder)
        }
        _ = getCustomTemplates()
    }
    
    // MARK: - File Name Conflict Resolution
    public static func uniqueURL(for targetURL: URL) -> URL {
        let fileManager = FileManager.default
        let folder = targetURL.deletingLastPathComponent()
        let filenameWithoutExt = targetURL.deletingPathExtension().lastPathComponent
        let ext = targetURL.pathExtension
        
        var candidate = targetURL
        var counter = 1
        
        while fileManager.fileExists(atPath: candidate.path) {
            let newName: String
            if ext.isEmpty {
                newName = "\(filenameWithoutExt) (\(counter))"
            } else {
                newName = "\(filenameWithoutExt) (\(counter)).\(ext)"
            }
            candidate = folder.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }
    
    // MARK: - Create File From Template
    public static func createFile(defaultName: String, templateName: String, in folderURL: URL) {
        log("createFile requested -> defaultName: \(defaultName), template: \(templateName), folder: \(folderURL.path)")
        let fileManager = FileManager.default
        let destinationURL = uniqueURL(for: folderURL.appendingPathComponent(defaultName))
        
        var templateData: Data? = nil
        let userTmpl = userTemplatesDirectory.appendingPathComponent(templateName)
        if let d = try? Data(contentsOf: userTmpl) {
            templateData = d
        } else if let resURL = Bundle.main.url(forResource: (templateName as NSString).deletingPathExtension,
                                             withExtension: (templateName as NSString).pathExtension,
                                             subdirectory: "Templates"),
                let d = try? Data(contentsOf: resURL) {
            templateData = d
        } else if let resPath = Bundle.main.resourceURL?.appendingPathComponent("Templates/\(templateName)"),
                let d = try? Data(contentsOf: resPath) {
            templateData = d
        }
        
        var success = false
        if let data = templateData {
            if fileManager.createFile(atPath: destinationURL.path, contents: data, attributes: nil) {
                success = true
            } else {
                do {
                    try data.write(to: destinationURL)
                    success = true
                } catch {
                    log("Write failed: \(error)")
                }
            }
        } else {
            success = fileManager.createFile(atPath: destinationURL.path, contents: Data(), attributes: nil)
        }
        
        if success {
            log("File creation finished successfully: \(destinationURL.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
            }
        } else {
            log("ERROR: Could not create file at \(destinationURL.path)")
        }
    }
    
    // MARK: - Copy Paths
    public static func copyPaths(urls: [URL], style: PathCopyStyle) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        let strings: [String] = urls.map { url in
            switch style {
            case .absolute:
                return url.path
            case .filename:
                return url.lastPathComponent
            case .escaped:
                var escaped = ""
                let charsToEscape: Set<Character> = [" ", "(", ")", "[", "]", "{", "}", "&", "$", "'", "\"", "*", "?", ";", "@", "`", "!", "|", "<", ">"]
                for ch in url.path {
                    if charsToEscape.contains(ch) {
                        escaped.append("\\")
                    }
                    escaped.append(ch)
                }
                return escaped
            }
        }
        
        let joined = strings.joined(separator: "\n")
        pasteboard.setString(joined, forType: .string)
        log("Copied \(urls.count) paths to pasteboard")
    }
    
    // MARK: - Cut and Move
    public static func cutFiles(urls: [URL]) {
        let validPaths = urls.map { $0.path }
        guard !validPaths.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([cutPasteboardType, .string], owner: nil)
        
        if let data = try? JSONEncoder().encode(validPaths) {
            pasteboard.setData(data, forType: cutPasteboardType)
            pasteboard.setString(validPaths.joined(separator: "\n"), forType: .string)
            log("Cut \(validPaths.count) files")
        }
    }
    
    public static func getCutFiles() -> [URL]? {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        cacheLock.lock()
        if currentChangeCount == lastPasteboardChangeCount {
            let res = cachedCutURLs
            cacheLock.unlock()
            return res
        }
        cacheLock.unlock()
        
        guard let types = pasteboard.types, types.contains(cutPasteboardType),
              let data = pasteboard.data(forType: cutPasteboardType),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            cacheLock.lock()
            lastPasteboardChangeCount = currentChangeCount
            cachedCutURLs = nil
            cacheLock.unlock()
            return nil
        }
        
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let result = urls.isEmpty ? nil : urls
        
        cacheLock.lock()
        lastPasteboardChangeCount = currentChangeCount
        cachedCutURLs = result
        cacheLock.unlock()
        return result
    }
    
    public static func moveCutFiles(to destinationFolder: URL) {
        guard let filesToMove = getCutFiles() else { return }
        let fileManager = FileManager.default
        var movedURLs: [URL] = []
        
        for fileURL in filesToMove {
            var targetURL = destinationFolder.appendingPathComponent(fileURL.lastPathComponent)
            if targetURL.path != fileURL.path && !destinationFolder.path.hasPrefix(fileURL.path + "/") {
                targetURL = uniqueURL(for: targetURL)
                do {
                    try fileManager.moveItem(at: fileURL, to: targetURL)
                    movedURLs.append(targetURL)
                    log("Moved: \(fileURL.path) -> \(targetURL.path)")
                } catch {
                    log("Move error: \(error)")
                }
            }
        }
        
        NSPasteboard.general.clearContents()
        
        if !movedURLs.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSWorkspace.shared.activateFileViewerSelecting(movedURLs)
            }
        }
    }
    
    // MARK: - Direct Move & Copy to Specific Directory
    
    public static func moveFiles(urls: [URL], to destinationDirectory: URL) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var movedURLs: [URL] = []
        
        for sourceURL in urls {
            let targetURL = uniqueURL(for: destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent))
            if targetURL.path != sourceURL.path {
                do {
                    try fm.moveItem(at: sourceURL, to: targetURL)
                    movedURLs.append(targetURL)
                    log("Moved: \(sourceURL.path) -> \(targetURL.path)")
                } catch {
                    log("Move error: \(error)")
                }
            }
        }
        
        if !movedURLs.isEmpty {
            DispatchQueue.main.async {
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting(movedURLs)
            }
        }
    }
    
    public static func copyFiles(urls: [URL], to destinationDirectory: URL) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        var copiedURLs: [URL] = []
        
        for sourceURL in urls {
            let targetURL = uniqueURL(for: destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent))
            do {
                try fm.copyItem(at: sourceURL, to: targetURL)
                copiedURLs.append(targetURL)
                log("Copied: \(sourceURL.path) -> \(targetURL.path)")
            } catch {
                log("Copy error: \(error)")
            }
        }
        
        if !copiedURLs.isEmpty {
            DispatchQueue.main.async {
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting(copiedURLs)
            }
        }
    }
    
    // MARK: - Open in Applications
    public static func openInWave(url: URL) {
        let dirURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let waveURL = URL(fileURLWithPath: "/Applications/Wave.app")
        if FileManager.default.fileExists(atPath: waveURL.path) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([dirURL], withApplicationAt: waveURL, configuration: config, completionHandler: nil)
            log("Opened Wave at \(dirURL.path)")
        }
    }
    
    public static func openInVSCode(url: URL) {
        let vscodeURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        if FileManager.default.fileExists(atPath: vscodeURL.path) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: vscodeURL, configuration: config, completionHandler: nil)
            log("Opened VSCode at \(url.path)")
        }
    }
    
    public static func openInPyCharm(url: URL) {
        let pycharmURL = URL(fileURLWithPath: "/Applications/PyCharm.app")
        if FileManager.default.fileExists(atPath: pycharmURL.path) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: pycharmURL, configuration: config, completionHandler: nil)
            log("Opened PyCharm at \(url.path)")
        }
    }
    
    public static func openInTerminal(url: URL) {
        let dirURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([dirURL], withApplicationAt: terminalURL, configuration: config, completionHandler: nil)
        log("Opened Terminal at \(dirURL.path)")
    }
    
    // MARK: - Standard Compress to ZIP
    public static func compressToZip(urls: [URL], in targetFolder: URL) {
        guard !urls.isEmpty else { return }
        
        let parentDir = urls.first?.deletingLastPathComponent() ?? targetFolder
        let zipName: String
        if urls.count == 1 {
            zipName = "\(urls[0].deletingPathExtension().lastPathComponent).zip"
        } else {
            zipName = "归档.zip"
        }
        let destZipURL = uniqueURL(for: parentDir.appendingPathComponent(zipName))
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            var args = ["-c", "-k", "--sequesterRsrc"]
            for url in urls {
                args.append("--keepParent")
                args.append(url.path)
            }
            args.append(destZipURL.path)
            process.arguments = args
            
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        log("Compress to zip completed: \(destZipURL.path)")
                        NSSound(named: "Glass")?.play()
                        NSWorkspace.shared.activateFileViewerSelecting([destZipURL])
                    }
                }
            } catch {
                log("Compress error: \(error)")
            }
        }
    }
    
    // MARK: - Detect ZIP Encryption
    public static func isZipEncrypted(url: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fileHandle.close() }
        
        let header = fileHandle.readData(ofLength: 30)
        guard header.count >= 8 else { return false }
        
        // Check PK\x03\x04 signature
        guard header[0] == 0x50 && header[1] == 0x4b && header[2] == 0x03 && header[3] == 0x04 else {
            return false
        }
        
        let flag = UInt16(header[6]) | (UInt16(header[7]) << 8)
        return (flag & 0x0001) != 0
    }
    
    // MARK: - Advanced Decompress
    public static func decompressArchive(archiveURL: URL, currentFolder: URL, mode: String, deleteArchive: Bool, onNeedsPassword: ((Bool) -> Void)? = nil) {
        let fileManager = FileManager.default
        let ext = archiveURL.pathExtension.lowercased()
        
        // If it is an encrypted zip, trigger password prompt immediately without creating empty folders
        if ext == "zip" && isZipEncrypted(url: archiveURL) {
            log("ZIP archive is encrypted: \(archiveURL.path)")
            if let callback = onNeedsPassword {
                DispatchQueue.main.async {
                    callback(true)
                }
                return
            }
        }
        
        let destFolder: URL
        let isSeparate = (mode == "separateFolder")
        
        if isSeparate {
            var baseName = archiveURL.deletingPathExtension().lastPathComponent
            if baseName.hasSuffix(".tar") {
                baseName = (baseName as NSString).deletingPathExtension
            }
            let candidate = currentFolder.appendingPathComponent(baseName, isDirectory: true)
            destFolder = uniqueURL(for: candidate)
        } else {
            destFolder = currentFolder
        }
        
        try? fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
        
        let beforeItems = Set((try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? [])
        log("Starting decompress: \(archiveURL.path) -> \(destFolder.path), separate: \(isSeparate), deleteArchive: \(deleteArchive)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var success = false
            var needsPasswordFallback = false
            
            if ext == "zip" {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-x", "-k", archiveURL.path, destFolder.path]
                do {
                    try p.run()
                    p.waitUntilExit()
                    success = (p.terminationStatus == 0)
                } catch {
                    log("ditto failed: \(error)")
                }
                
                // Fallback to unzip
                if !success {
                    let unzipProc = Process()
                    unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    unzipProc.arguments = ["-q", "-o", "-P", "", archiveURL.path, "-d", destFolder.path]
                    try? unzipProc.run()
                    unzipProc.waitUntilExit()
                    let unzipStatus = unzipProc.terminationStatus
                    if unzipStatus == 0 {
                        success = true
                    } else if unzipStatus == 82 || unzipStatus == 2 || isZipEncrypted(url: archiveURL) {
                        needsPasswordFallback = true
                    }
                }
            } else if ["tar", "gz", "tgz", "bz2", "tbz", "xz", "txz"].contains(ext) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                p.arguments = ["-xf", archiveURL.path, "-C", destFolder.path]
                do {
                    try p.run()
                    p.waitUntilExit()
                    success = (p.terminationStatus == 0)
                } catch {
                    log("tar failed: \(error)")
                }
            } else {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.open(archiveURL, configuration: config, completionHandler: nil)
                success = true
            }
            
            // Clean up empty folder if failed
            if !success && isSeparate {
                let items = (try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? []
                if items.isEmpty {
                    try? fileManager.removeItem(at: destFolder)
                }
            }
            
            DispatchQueue.main.async {
                if needsPasswordFallback, let callback = onNeedsPassword {
                    callback(true)
                    return
                }
                
                if success {
                    log("Decompress succeeded for \(archiveURL.lastPathComponent)")
                    NSSound(named: "Glass")?.play()
                    
                    if deleteArchive {
                        NSWorkspace.shared.recycle([archiveURL], completionHandler: nil)
                    }
                    
                    if isSeparate {
                        NSWorkspace.shared.activateFileViewerSelecting([destFolder])
                    } else {
                        let afterItems = Set((try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? [])
                        let newItems = afterItems.subtracting(beforeItems)
                        if !newItems.isEmpty {
                            let highlightURLs = newItems.map { destFolder.appendingPathComponent($0) }
                            NSWorkspace.shared.activateFileViewerSelecting(highlightURLs)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([destFolder])
                        }
                    }
                } else {
                    log("ERROR: Decompress process failed for \(archiveURL.path)")
                }
            }
        }
    }
    
    // MARK: - Decompress Encrypted ZIP with Password
    public static func decompressZipWithPassword(archiveURL: URL, currentFolder: URL, mode: String, deleteArchive: Bool, password: String, completion: @escaping (Bool, Bool) -> Void) {
        let fileManager = FileManager.default
        let destFolder: URL
        let isSeparate = (mode == "separateFolder")
        
        if isSeparate {
            var baseName = archiveURL.deletingPathExtension().lastPathComponent
            if baseName.hasSuffix(".tar") {
                baseName = (baseName as NSString).deletingPathExtension
            }
            let candidate = currentFolder.appendingPathComponent(baseName, isDirectory: true)
            destFolder = uniqueURL(for: candidate)
        } else {
            destFolder = currentFolder
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            try? fileManager.createDirectory(at: destFolder, withIntermediateDirectories: true)
            let beforeItems = Set((try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? [])
            
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", "-P", password, archiveURL.path, "-d", destFolder.path]
            try? p.run()
            p.waitUntilExit()
            
            let status = p.terminationStatus
            let success = (status == 0)
            let wrongPassword = (status == 82 || status == 2)
            
            if !success && isSeparate {
                let items = (try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? []
                if items.isEmpty {
                    try? fileManager.removeItem(at: destFolder)
                }
            }
            
            DispatchQueue.main.async {
                if success {
                    log("Decompress with password succeeded for \(archiveURL.lastPathComponent)")
                    NSSound(named: "Glass")?.play()
                    
                    if deleteArchive {
                        NSWorkspace.shared.recycle([archiveURL], completionHandler: nil)
                    }
                    
                    if isSeparate {
                        NSWorkspace.shared.activateFileViewerSelecting([destFolder])
                    } else {
                        let afterItems = Set((try? fileManager.contentsOfDirectory(atPath: destFolder.path)) ?? [])
                        let newItems = afterItems.subtracting(beforeItems)
                        if !newItems.isEmpty {
                            let highlightURLs = newItems.map { destFolder.appendingPathComponent($0) }
                            NSWorkspace.shared.activateFileViewerSelecting(highlightURLs)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([destFolder])
                        }
                    }
                    completion(true, false)
                } else {
                    log("ERROR: Unzip with password failed with status \(status)")
                    completion(false, wrongPassword)
                }
            }
        }
    }
    
    // MARK: - Custom Compression
    public static func performCustomCompress(sourceURLs: [URL], baseName: String, isZip: Bool, password: String?, targetFolder: URL) {
        guard !sourceURLs.isEmpty else { return }
        let parentDir = sourceURLs.first?.deletingLastPathComponent() ?? targetFolder
        let ext = isZip ? "zip" : "tar.gz"
        let candidate = parentDir.appendingPathComponent("\(baseName).\(ext)")
        let destURL = uniqueURL(for: candidate)
        
        log("performCustomCompress -> dest: \(destURL.path), count: \(sourceURLs.count), hasPassword: \(password != nil)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var success = false
            if isZip {
                if let pwd = password, !pwd.isEmpty {
                    // Password protected zip
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                    p.currentDirectoryURL = parentDir
                    var args = ["-q", "-r", "-P", pwd, destURL.path]
                    for url in sourceURLs {
                        args.append(url.lastPathComponent)
                    }
                    p.arguments = args
                    do {
                        try p.run()
                        p.waitUntilExit()
                        success = (p.terminationStatus == 0)
                    } catch {
                        log("zip password failed: \(error)")
                    }
                } else {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    var args = ["-c", "-k", "--sequesterRsrc"]
                    for url in sourceURLs {
                        args.append("--keepParent")
                        args.append(url.path)
                    }
                    args.append(destURL.path)
                    p.arguments = args
                    do {
                        try p.run()
                        p.waitUntilExit()
                        success = (p.terminationStatus == 0)
                    } catch {
                        log("ditto compress failed: \(error)")
                    }
                }
            } else {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                p.currentDirectoryURL = parentDir
                var args = ["-czf", destURL.path]
                for url in sourceURLs {
                    args.append(url.lastPathComponent)
                }
                p.arguments = args
                do {
                    try p.run()
                    p.waitUntilExit()
                    success = (p.terminationStatus == 0)
                } catch {
                    log("tar.gz compress failed: \(error)")
                }
            }
            
            DispatchQueue.main.async {
                if success {
                    log("Custom compress succeeded: \(destURL.path)")
                    NSSound(named: "Glass")?.play()
                    NSWorkspace.shared.activateFileViewerSelecting([destURL])
                } else {
                    log("ERROR: Custom compress failed")
                }
            }
        }
    }
}
