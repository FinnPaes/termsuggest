// TermSuggest overlay: a floating, non-activating panel that shows the
// suggestions next to the terminal cursor (like Fig / Kiro did).
//
// It connects to the termsuggest daemon socket, receives "show"/"hide"
// messages (JSON lines) and sends "accept" back when an item is clicked.
// Cursor position comes from the Accessibility API when permitted, otherwise
// it is estimated from the terminal window frame and the cell grid.
import Cocoa
import ApplicationServices

// MARK: - Messages

struct Item: Decodable {
    let display: String
    let desc: String
    let kind: String
}

struct Message: Decodable {
    let type: String
    let conn: Int?
    let items: [Item]?
    let sel: Int?
    let aRow: Int?, aCol: Int?, cRow: Int?, cCol: Int?
    let cols: Int?, lines: Int?
    let cellW: Double?, cellH: Double?
}

// MARK: - Logging

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/termsuggest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("overlay.log")
    }()
    static let enabled = ProcessInfo.processInfo.environment["TERMSUGGEST_DEBUG"] != nil
        || FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("debug").path)

    static func write(_ s: String, force: Bool = false) {
        guard enabled || force else { return }
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Socket client

final class SocketClient {
    let path: String
    var fd: Int32 = -1
    var onMessage: ((Message) -> Void)?
    var onDisconnect: (() -> Void)?
    private let queue = DispatchQueue(label: "termsuggest.socket")

    init(path: String) { self.path = path }

    func start() {
        queue.async { self.loop() }
    }

    private func loop() {
        while true {
            if connectSocket() {
                send("overlay")
                readLines()
                DispatchQueue.main.async { self.onDisconnect?() }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func connectSocket() -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 { close(s); return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        Log.write("connected to \(path)")
        return true
    }

    private func readLines() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let msg = try? JSONDecoder().decode(Message.self, from: line) {
                    DispatchQueue.main.async { self.onMessage?(msg) }
                }
            }
        }
        close(fd)
        fd = -1
    }

    func send(_ line: String) {
        let s = fd
        guard s >= 0 else { return }
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(s, $0.baseAddress, data.count) }
    }
}

// MARK: - Look

enum Style {
    static let rowHeight: CGFloat = 26
    static let maxRows = 8
    static let padding: CGFloat = 5
    static let iconWidth: CGFloat = 26
    static let nameFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .medium)
    static let descFont = NSFont.systemFont(ofSize: 11.5)
    static let footerFont = NSFont.systemFont(ofSize: 11)

    static func symbol(for kind: String) -> (String, NSColor) {
        switch kind {
        case "subcommand": return ("arrow.right.square.fill", .systemBlue)
        case "option": return ("flag.fill", .systemOrange)
        case "folder": return ("folder.fill", .systemTeal)
        case "file": return ("doc.fill", .systemGray)
        case "command": return ("terminal.fill", .systemGreen)
        default: return ("tag.fill", .systemPurple)
        }
    }
}

// MARK: - List view

final class ListView: NSView {
    var items: [Item] = []
    var selected = 0
    var top = 0
    var nameWidth: CGFloat = 120
    var onClick: ((Int) -> Void)?
    private var symbolCache: [String: NSImage] = [:]

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var visibleRows: Int { min(items.count, Style.maxRows) }

    func scrollToSelection() {
        if selected < top { top = selected }
        if selected >= top + Style.maxRows { top = selected - Style.maxRows + 1 }
        top = max(0, min(top, max(0, items.count - Style.maxRows)))
    }

    private func icon(_ kind: String, selected: Bool) -> NSImage? {
        let key = "\(kind)-\(selected)"
        if let img = symbolCache[key] { return img }
        let (name, color) = Style.symbol(for: kind)
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: selected ? .white : color))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        symbolCache[key] = img
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let width = bounds.width

        for row in 0..<visibleRows {
            let i = top + row
            guard i < items.count else { break }
            let item = items[i]
            let y = Style.padding + CGFloat(row) * Style.rowHeight
            let rowRect = NSRect(x: Style.padding, y: y, width: width - Style.padding * 2, height: Style.rowHeight)
            let isSel = i == selected

            if isSel {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 6, yRadius: 6).fill()
            }

            if let img = icon(item.kind, selected: isSel) {
                let s = img.size
                img.draw(in: NSRect(x: rowRect.minX + (Style.iconWidth - s.width) / 2,
                                    y: y + (Style.rowHeight - s.height) / 2, width: s.width, height: s.height))
            }

            let nameColor: NSColor = isSel ? .white : .labelColor
            let descColor: NSColor = isSel ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
            let name = NSAttributedString(string: item.display, attributes: [
                .font: Style.nameFont, .foregroundColor: nameColor, .paragraphStyle: para,
            ])
            let nameX = rowRect.minX + Style.iconWidth + 2
            let nh = name.size().height
            name.draw(with: NSRect(x: nameX, y: y + (Style.rowHeight - nh) / 2, width: nameWidth, height: nh),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            if !item.desc.isEmpty {
                let desc = NSAttributedString(string: item.desc, attributes: [
                    .font: Style.descFont, .foregroundColor: descColor, .paragraphStyle: para,
                ])
                let dx = nameX + nameWidth + 14
                let dw = rowRect.maxX - dx - 8
                if dw > 30 {
                    let dh = desc.size().height
                    desc.draw(with: NSRect(x: dx, y: y + (Style.rowHeight - dh) / 2, width: dw, height: dh),
                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
        }

        // Scroll indicator
        if items.count > Style.maxRows {
            let trackH = CGFloat(visibleRows) * Style.rowHeight
            let thumbH = max(16, trackH * CGFloat(Style.maxRows) / CGFloat(items.count))
            let thumbY = Style.padding + (trackH - thumbH) * CGFloat(top) / CGFloat(items.count - Style.maxRows)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: width - 4.5, y: thumbY, width: 2.5, height: thumbH), xRadius: 1.25, yRadius: 1.25).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = Int((p.y - Style.padding) / Style.rowHeight)
        let i = top + row
        if row >= 0, row < visibleRows, i < items.count { onClick?(i) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard items.count > Style.maxRows else { return }
        let delta = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        top = max(0, min(items.count - Style.maxRows, top + delta))
        needsDisplay = true
    }
}

// MARK: - Panel

final class Overlay: NSObject {
    let client: SocketClient
    let panel: NSPanel
    let effect: NSVisualEffectView
    let list = ListView()
    let footer = NSTextField(wrappingLabelWithString: "")
    let separator = NSBox()
    var conn = 0
    var terminalPid: pid_t = 0
    var lastItemsKey = ""

    init(socketPath: String) {
        client = SocketClient(path: socketPath)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        effect = NSVisualEffectView()
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none

        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        effect.addSubview(list)
        separator.boxType = .separator
        effect.addSubview(separator)
        footer.font = Style.footerFont
        footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 2
        footer.lineBreakMode = .byTruncatingTail
        effect.addSubview(footer)

        list.onClick = { [weak self] i in
            guard let self else { return }
            self.client.send("{\"type\":\"accept\",\"conn\":\(self.conn),\"index\":\(i)}")
        }
        client.onMessage = { [weak self] m in self?.handle(m) }
        client.onDisconnect = { [weak self] in self?.hide() }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func start() { client.start() }

    @objc func appActivated(_ n: Notification) {
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier != terminalPid { hide() }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func handle(_ m: Message) {
        guard m.type == "show", let items = m.items, !items.isEmpty else {
            // Only the shell that opened the list may close it.
            if m.conn == nil || m.conn == conn || !panel.isVisible { hide() }
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        terminalPid = front.processIdentifier
        conn = m.conn ?? 0

        let key = items.map { $0.display }.joined(separator: "\u{1}")
        if key != lastItemsKey {
            list.top = 0
            lastItemsKey = key
        }
        list.items = items
        list.selected = max(0, min(items.count - 1, (m.sel ?? 1) - 1))
        list.scrollToSelection()

        layout(items: items)
        guard let origin = position(m) else {
            Log.write("no position")
            hide()
            return
        }
        place(lineTopLeft: origin.0, lineHeight: origin.1)
        list.needsDisplay = true
        panel.orderFrontRegardless()
    }

    // Size the panel for the current items.
    func layout(items: [Item]) {
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: Style.nameFont]
        let descAttrs: [NSAttributedString.Key: Any] = [.font: Style.descFont]
        var nw: CGFloat = 60, dw: CGFloat = 0
        for it in items.prefix(60) {
            nw = max(nw, (it.display as NSString).size(withAttributes: nameAttrs).width)
            dw = max(dw, (it.desc as NSString).size(withAttributes: descAttrs).width)
        }
        nw = min(ceil(nw) + 2, 260)
        list.nameWidth = nw
        var width = Style.padding * 2 + Style.iconWidth + 2 + nw + (dw > 0 ? 14 + min(dw, 300) : 0) + 14
        width = max(240, min(width, 620))

        let listH = CGFloat(list.visibleRows) * Style.rowHeight + Style.padding * 2
        let sel = list.selected < items.count ? items[list.selected] : nil
        var footerH: CGFloat = 0
        let inlineDescW = width - (Style.padding * 2 + Style.iconWidth + 2 + nw + 14 + 8)
        if let sel, !sel.desc.isEmpty,
           (sel.desc as NSString).size(withAttributes: descAttrs).width > inlineDescW {
            footer.stringValue = sel.desc
            footer.preferredMaxLayoutWidth = width - 24
            let h = min(footer.fittingSize.height, 34)
            footerH = h + 12
            footer.frame = NSRect(x: 12, y: 6, width: width - 24, height: h)
            footer.isHidden = false
            separator.isHidden = false
            separator.frame = NSRect(x: 0, y: footerH - 1, width: width, height: 1)
        } else {
            footer.isHidden = true
            separator.isHidden = true
        }
        let height = listH + footerH
        list.frame = NSRect(x: 0, y: footerH, width: width, height: listH)
        effect.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.setContentSize(NSSize(width: width, height: height))
    }

    // Top-left (screen coords, origin top-left) of the line the word being
    // completed is on, aligned to the start of that word, plus the line height.
    func position(_ m: Message) -> (CGPoint, CGFloat)? {
        let aRow = m.aRow ?? 0, aCol = m.aCol ?? 0, cRow = m.cRow ?? 0, cCol = m.cCol ?? 0
        let cols = max(1, m.cols ?? 80), lines = max(1, m.lines ?? 24)
        let window = frontWindowFrame(pid: terminalPid)

        if let caret = axCaretRect(pid: terminalPid), caret.height > 4, caret.height < 200 {
            if window == nil || window!.insetBy(dx: -4, dy: -4).contains(caret.origin) {
                let cw = (m.cellW ?? 0) > 0 ? CGFloat(m.cellW!) : caret.width > 2 ? caret.width : 8
                let ch = caret.height
                let x = caret.minX - CGFloat(cCol - aCol) * cw
                let y = caret.minY - CGFloat(cRow - aRow) * ch
                Log.write("ax caret=\(caret) -> \(x),\(y)")
                return (CGPoint(x: x, y: y), ch)
            }
        }

        guard let frame = window, aRow > 0 else { return nil }
        let prefs = UserDefaults(suiteName: "com.googlecode.iterm2")
        let isITerm = NSRunningApplication(processIdentifier: terminalPid)?.bundleIdentifier == "com.googlecode.iterm2"
        let hMargin = CGFloat(isITerm ? (prefs?.object(forKey: "TerminalMargin") as? Double ?? 5) : 2)
        let vMargin = CGFloat(isITerm ? (prefs?.object(forKey: "TerminalVMargin") as? Double ?? 2) : 2)
        var cw = CGFloat(m.cellW ?? 0), ch = CGFloat(m.cellH ?? 0)
        if cw <= 0 { cw = (frame.width - 2 * hMargin) / CGFloat(cols) }
        if ch <= 0 { ch = (frame.height - 28 - 2 * vMargin) / CGFloat(lines) }
        // Rows are laid out from the bottom of the window up, which is stable
        // regardless of title bar / tab bar height.
        let bottom = frame.maxY - vMargin
        let y = bottom - CGFloat(lines - aRow + 1) * ch
        let x = frame.minX + hMargin + CGFloat(aCol - 1) * cw
        Log.write("grid frame=\(frame) cell=\(cw)x\(ch) row=\(aRow) col=\(aCol) -> \(x),\(y)")
        return (CGPoint(x: x, y: y), ch)
    }

    func place(lineTopLeft p: CGPoint, lineHeight: CGFloat) {
        guard let primary = NSScreen.screens.first else { return }
        let size = panel.frame.size
        // Convert from top-left global coords to Cocoa (bottom-left) coords.
        let lineTop = primary.frame.maxY - p.y
        let lineBottom = lineTop - lineHeight
        var x = p.x - Style.padding - Style.iconWidth - 2
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: p.x, y: lineBottom)) } ?? primary
        let vis = screen.visibleFrame
        var y = lineBottom - 4 - size.height
        // Not enough room below (prompt at the bottom of the terminal): show it
        // above, with extra room so it never covers the line being typed even
        // when the line position is only estimated.
        if y < vis.minY { y = lineTop + max(10, lineHeight * 0.6) }
        x = min(max(x, vis.minX + 4), vis.maxX - size.width - 4)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func frontWindowFrame(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width > 100, rect.height > 60 else { continue }
            return rect
        }
        return nil
    }

    func axCaretRect(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }
        range.length = 1
        guard let one = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, one, &boundsRef) == .success,
              let bv = boundsRef, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: Overlay!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let socketPath = args.count > 1 && args[1].hasSuffix(".sock") ? args[1] :
            (NSTemporaryDirectory() as NSString).appendingPathComponent("termsuggest-\(getuid()).sock")

        if args.contains("--render-test") {
            renderTest()
            NSApp.terminate(nil)
            return
        }

        // Ask once for Accessibility access: it gives exact cursor positions.
        let asked = UserDefaults.standard.bool(forKey: "askedAccessibility")
        if !AXIsProcessTrusted() && !asked {
            UserDefaults.standard.set(true, forKey: "askedAccessibility")
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        Log.write("started, socket=\(socketPath) trusted=\(AXIsProcessTrusted())", force: true)

        overlay = Overlay(socketPath: socketPath)
        overlay.start()
    }

    // Draws a sample list into a PNG (for checking the look without a screen).
    func renderTest() {
        let o = Overlay(socketPath: "/dev/null")
        let items = [
            Item(display: "push", desc: "Update remote refs", kind: "subcommand"),
            Item(display: "pull", desc: "Integrate with another repository", kind: "subcommand"),
            Item(display: "--force", desc: "Force updates", kind: "option"),
            Item(display: "src/", desc: "", kind: "folder"),
            Item(display: "package.json", desc: "", kind: "file"),
            Item(display: "origin", desc: "Remote", kind: "arg"),
            Item(display: "git", desc: "Distributed version control system", kind: "command"),
        ]
        o.list.items = items
        o.list.selected = 1
        o.layout(items: items)
        let view = o.effect
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = CommandLine.arguments.last!
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
