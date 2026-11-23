import Cocoa
import Network
import WebKit

// MARK: - Embedded Local HTTP Server

final class LocalHTTPServer {
    private let rootDirectory: URL
    private let queue = DispatchQueue(label: "com.excalidraw.localserver", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func start(preferredPort: UInt16 = 5001, completion: @escaping (Result<UInt16, Error>) -> Void) {
        startListener(port: NWEndpoint.Port(rawValue: preferredPort)) { [weak self] result in
            switch result {
            case .success(let boundPort):
                completion(.success(boundPort))
            case .failure:
                // Fallback to any available ephemeral port if preferredPort is busy
                self?.startListener(port: .any, completion: completion)
            }
        }
    }

    private func startListener(port: NWEndpoint.Port?, completion: @escaping (Result<UInt16, Error>) -> Void) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let nwListener = try NWListener(using: params, on: port ?? .any)
            var didComplete = false

            nwListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if !didComplete, let actualPort = nwListener.port?.rawValue {
                        didComplete = true
                        self.port = actualPort
                        completion(.success(actualPort))
                    }
                case .failed(let error):
                    nwListener.cancel()
                    if !didComplete {
                        didComplete = true
                        completion(.failure(error))
                    }
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            self.listener = nwListener
            nwListener.start(queue: queue)
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data = data {
                accumulated.append(data)
            }

            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: 0..<headerEnd.lowerBound)
                self.processHTTPRequest(headerData: headerData, on: connection)
                return
            }

            if isComplete || error != nil || accumulated.count > 131072 {
                connection.cancel()
                return
            }

            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    private func processHTTPRequest(headerData: Data, on connection: NWConnection) {
        guard let headerString = String(data: headerData, encoding: .utf8),
              let requestLine = headerString.components(separatedBy: "\r\n").first else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8), on: connection)
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8), on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendResponse(status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("Method Not Allowed".utf8), on: connection)
            return
        }

        let rawTarget = String(parts[1])
        let pathOnly = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let decodedPath = pathOnly.removingPercentEncoding ?? pathOnly
        let trimmed = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath

        let candidatePath = trimmed.isEmpty ? "index.html" : trimmed
        var fileURL = rootDirectory.appendingPathComponent(candidatePath).standardizedFileURL

        // Prevent path traversal outside rootDirectory
        guard fileURL.path.hasPrefix(rootDirectory.path) else {
            sendResponse(status: "403 Forbidden", contentType: "text/plain; charset=utf-8", body: Data("Forbidden".utf8), on: connection)
            return
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) {
            if isDir.boolValue {
                fileURL = fileURL.appendingPathComponent("index.html")
            }
        } else if fileURL.pathExtension.isEmpty {
            // SPA fallback for client-side routes
            fileURL = rootDirectory.appendingPathComponent("index.html")
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            sendResponse(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not Found".utf8), on: connection)
            return
        }

        let mimeType = mimeTypeForExtension(fileURL.pathExtension.lowercased())
        sendResponse(
            status: "200 OK",
            contentType: mimeType,
            body: method == "HEAD" ? Data() : body,
            contentLengthOverride: body.count,
            on: connection
        )
    }

    private func sendResponse(
        status: String,
        contentType: String,
        body: Data,
        contentLengthOverride: Int? = nil,
        on connection: NWConnection
    ) {
        let length = contentLengthOverride ?? body.count
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        case "map": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - macOS Application Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var server: LocalHTTPServer?
    private var serverURL: URL?
    private var serverPort: UInt16 = 5001

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupWindowAndWebView()
        startServerAndLoad()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupWindowAndWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(self, name: "excalidrawDesktop")

        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 820)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Excalidraw"
        window.center()
        window.setFrameAutosaveName("ExcalidrawMainWindow")
        window.minSize = NSSize(width: 640, height: 480)

        webView = WKWebView(frame: contentRect, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false

        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startServerAndLoad() {
        guard let webRoot = Bundle.main.resourceURL?.appendingPathComponent("web"),
              FileManager.default.fileExists(atPath: webRoot.appendingPathComponent("index.html").path) else {
            showErrorAlert(title: "Missing Web Bundle", message: "Could not find bundled Excalidraw web files inside the app.")
            return
        }

        let localServer = LocalHTTPServer(rootDirectory: webRoot)
        self.server = localServer

        localServer.start(preferredPort: 5001) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let port):
                    let url = URL(string: "http://127.0.0.1:\(port)/")!
                    self.serverPort = port
                    self.serverURL = url
                    self.window.title = "Excalidraw (localhost:\(port))"
                    self.webView.load(URLRequest(url: url))
                case .failure(let error):
                    self.showErrorAlert(title: "Server Error", message: "Failed to start local server: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Excalidraw", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Excalidraw", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Excalidraw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        let browserItem = NSMenuItem(title: "Open in Default Browser", action: #selector(openInBrowser), keyEquivalent: "b")
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(browserItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Edit Menu (enables Cmd+C/V/X/A/Z in WKWebView)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openInBrowser() {
        if let url = serverURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func zoomIn() {
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
    }

    @objc private func zoomOut() {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.5)
    }

    @objc private func zoomReset() {
        webView.pageZoom = 1.0
    }

    // MARK: - WKNavigationDelegate & Downloads

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host?.lowercased(),
           host != "127.0.0.1" && host != "localhost" {
            // Open external links in default browser
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: self.window) { result in
                completionHandler(result == .OK ? panel.url : nil)
            }
        }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Excalidraw"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Excalidraw"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Excalidraw"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input

        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
        }
    }

    // MARK: - WKScriptMessageHandler (Native File Save/Open Bridge)

    private static let lastFileDefaultsKey = "lastOpenedExcalidrawFilePath"

    private func rememberLastFileIfProject(_ url: URL) {
        if url.pathExtension.lowercased() == "excalidraw" {
            UserDefaults.standard.set(url.path, forKey: Self.lastFileDefaultsKey)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "excalidrawDesktop",
              let body = message.body as? [String: Any],
              let requestId = body["requestId"] as? String,
              let action = body["action"] as? String else {
            return
        }

        switch action {
        case "saveFile":
            handleBridgeSaveFile(requestId: requestId, body: body)
        case "openFile":
            handleBridgeOpenFile(requestId: requestId, body: body)
        case "getLastFile":
            handleBridgeGetLastFile(requestId: requestId)
        default:
            resolveDesktopBridge(requestId: requestId, result: nil, error: "Unknown action: \(action)")
        }
    }

    private func handleBridgeGetLastFile(requestId: String) {
        guard let path = UserDefaults.standard.string(forKey: Self.lastFileDefaultsKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            resolveDesktopBridge(requestId: requestId, result: ["found": false], error: nil)
            return
        }

        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            window.title = "Excalidraw — \(url.lastPathComponent)"
            resolveDesktopBridge(
                requestId: requestId,
                result: [
                    "found": true,
                    "name": url.lastPathComponent,
                    "path": url.path,
                    "contentBase64": data.base64EncodedString()
                ],
                error: nil
            )
        } catch {
            resolveDesktopBridge(requestId: requestId, result: ["found": false], error: nil)
        }
    }

    private func handleBridgeSaveFile(requestId: String, body: [String: Any]) {
        guard let contentBase64 = body["contentBase64"] as? String,
              let data = Data(base64Encoded: contentBase64) else {
            resolveDesktopBridge(requestId: requestId, result: nil, error: "Invalid file content")
            return
        }

        let suggestedName = (body["suggestedName"] as? String) ?? "Untitled.excalidraw"

        if let existingPath = body["path"] as? String, !existingPath.isEmpty {
            let targetURL = URL(fileURLWithPath: existingPath)
            do {
                try data.write(to: targetURL, options: .atomic)
                rememberLastFileIfProject(targetURL)
                window.title = "Excalidraw — \(targetURL.lastPathComponent)"
                resolveDesktopBridge(
                    requestId: requestId,
                    result: ["path": targetURL.path, "name": targetURL.lastPathComponent],
                    error: nil
                )
            } catch {
                resolveDesktopBridge(requestId: requestId, result: nil, error: error.localizedDescription)
            }
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let url = panel.url else {
                self.resolveDesktopBridge(requestId: requestId, result: ["cancelled": true], error: nil)
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                rememberLastFileIfProject(url)
                self.window.title = "Excalidraw — \(url.lastPathComponent)"
                self.resolveDesktopBridge(
                    requestId: requestId,
                    result: ["path": url.path, "name": url.lastPathComponent],
                    error: nil
                )
            } catch {
                self.resolveDesktopBridge(requestId: requestId, result: nil, error: error.localizedDescription)
            }
        }
    }

    private func handleBridgeOpenFile(requestId: String, body: [String: Any]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = (body["multiple"] as? Bool) ?? false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, !panel.urls.isEmpty else {
                self.resolveDesktopBridge(requestId: requestId, result: ["cancelled": true], error: nil)
                return
            }

            var filesPayload: [[String: Any]] = []
            for url in panel.urls {
                do {
                    let data = try Data(contentsOf: url)
                    filesPayload.append([
                        "name": url.lastPathComponent,
                        "path": url.path,
                        "contentBase64": data.base64EncodedString()
                    ])
                } catch {
                    self.resolveDesktopBridge(requestId: requestId, result: nil, error: error.localizedDescription)
                    return
                }
            }

            if let first = panel.urls.first {
                self.rememberLastFileIfProject(first)
                self.window.title = "Excalidraw — \(first.lastPathComponent)"
            }
            self.resolveDesktopBridge(requestId: requestId, result: ["files": filesPayload], error: nil)
        }
    }

    private func resolveDesktopBridge(requestId: String, result: [String: Any]?, error: String?) {
        let resultJSON: String
        if let result = result,
           let jsonData = try? JSONSerialization.data(withJSONObject: result),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            resultJSON = jsonStr
        } else {
            resultJSON = "null"
        }

        let errorJSON: String
        if let error = error,
           let jsonData = try? JSONSerialization.data(withJSONObject: [error]),
           let jsonArrayStr = String(data: jsonData, encoding: .utf8),
           jsonArrayStr.count >= 2 {
            // Extract the quoted string from the 1-element JSON array
            let start = jsonArrayStr.index(after: jsonArrayStr.startIndex)
            let end = jsonArrayStr.index(before: jsonArrayStr.endIndex)
            errorJSON = String(jsonArrayStr[start..<end])
        } else {
            errorJSON = "null"
        }

        let reqData = (try? JSONSerialization.data(withJSONObject: [requestId])) ?? Data()
        let reqArrayStr = String(data: reqData, encoding: .utf8) ?? "[\"\"]"
        let reqStart = reqArrayStr.index(after: reqArrayStr.startIndex)
        let reqEnd = reqArrayStr.index(before: reqArrayStr.endIndex)
        let reqIDJSON = String(reqArrayStr[reqStart..<reqEnd])

        let js = "window.__excalidrawDesktopResolve && window.__excalidrawDesktopResolve(\(reqIDJSON), \(resultJSON), \(errorJSON));"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
