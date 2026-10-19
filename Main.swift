import AppKit
import Foundation

private enum QuoteOrigin { case webSocket, restFallback }
private enum QuoteError: LocalizedError {
    case invalidResponse, provider(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "OKX 未返回有效行情，请稍后重试"
        case .provider(let message): return message
        }
    }
}
private struct OKXSubscription: Codable { let channel: String; let instId: String }
private struct OKXSubscriptionRequest: Encodable { let op: String; let args: [OKXSubscription] }
private struct OKXEnvelope: Decodable {
    let event: String?
    let code: String?
    let msg: String?
    let arg: OKXSubscription?
    let data: [OKXTicker]?
}
private struct OKXRESTEnvelope: Decodable { let code: String; let msg: String; let data: [OKXTicker] }
private struct OKXTicker: Decodable {
    let instId: String
    let last: String
    let bidPx: String?
    let askPx: String?
    let open24h: String?
    let ts: String?
}
private struct Quote {
    let last: Double
    let bid: Double?
    let ask: Double?
    let change24h: Double?
    let serverTime: Date?
    init?(ticker: OKXTicker) {
        guard let last = Self.number(ticker.last), last > 0 else { return nil }
        self.last = last
        bid = Self.number(ticker.bidPx)
        ask = Self.number(ticker.askPx)
        change24h = Self.number(ticker.open24h).flatMap { $0 > 0 ? (last / $0 - 1) * 100 : nil }
        serverTime = ticker.ts.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }
    private static func number(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite else { return nil }
        return number
    }
}
private enum OKXMarketAPI {
    static func tickerTask(for id: String, completion: @escaping (Result<Quote, Error>) -> Void) -> URLSessionDataTask {
        var components = URLComponents(string: "https://www.okx.com/api/v5/market/ticker")!
        components.queryItems = [URLQueryItem(name: "instId", value: id)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("MUMenuBar/4.0", forHTTPHeaderField: "User-Agent")
        return URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Quote, Error>
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else { throw QuoteError.invalidResponse }
                let envelope = try JSONDecoder().decode(OKXRESTEnvelope.self, from: data)
                guard envelope.code == "0" else {
                    if envelope.code == "51001" { throw QuoteError.provider("找不到 \(id)，请检查 OKX 的完整标的代码") }
                    throw QuoteError.provider(envelope.msg.isEmpty ? "OKX 暂时无法提供此行情" : envelope.msg)
                }
                guard let ticker = envelope.data.first(where: { $0.instId == id }), let quote = Quote(ticker: ticker) else { throw QuoteError.invalidResponse }
                result = .success(quote)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
private final class QuoteRow: NSView {
    let symbolLabel = NSTextField(labelWithString: "")
    let priceLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    var trailingSpace: CGFloat = 14
    override var mouseDownCanMoveWindow: Bool { true }
    init(id: String, width: CGFloat, quoteMenu: NSMenu) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        menu = quoteMenu
        priceLabel.frame = NSRect(x: 11, y: 18, width: width - 22, height: 17)
        priceLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        priceLabel.lineBreakMode = .byTruncatingTail
        priceLabel.alignment = .right
        priceLabel.setAccessibilityIdentifier("price-\(id)")
        symbolLabel.frame = NSRect(x: 11, y: 18, width: 65, height: 17)
        symbolLabel.font = .systemFont(ofSize: 12, weight: .medium)
        symbolLabel.lineBreakMode = .byTruncatingTail
        symbolLabel.setAccessibilityIdentifier("symbol-\(id)")
        detailLabel.frame = NSRect(x: 11, y: 5, width: width - 22, height: 12)
        detailLabel.font = .systemFont(ofSize: 9, weight: .medium)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setAccessibilityIdentifier("detail-\(id)")
        for label in [symbolLabel, priceLabel, detailLabel] { label.menu = quoteMenu; addSubview(label) }
    }
    func setPrice(_ value: String, symbol: String, color: NSColor) {
        symbolLabel.stringValue = symbol
        priceLabel.stringValue = value
        priceLabel.textColor = color
        let available = frame.width - 11 - trailingSpace
        let measured = (value as NSString).size(withAttributes: [.font: priceLabel.font!]).width + 4
        let priceWidth = min(available - 32, max(40, measured))
        priceLabel.frame = NSRect(x: frame.width - trailingSpace - priceWidth, y: 18, width: priceWidth, height: 17)
        symbolLabel.frame.size.width = max(26, available - priceWidth - 5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let watchlistKey = "okxWatchlistInstrumentIDs"
    private let defaults: UserDefaults
    private var instrumentIDs: [String]
    private var watchlistID = UUID()
    private var floatingPanel: NSPanel?
    private var quoteRows: [String: QuoteRow] = [:]
    private let menu = NSMenu()
    private let settings = WatchlistSettingsController()
    private var validationID = UUID()
    private var validationTask: URLSessionDataTask?
    private var webSocketSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var connectionID = UUID()
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var healthTimer: Timer?
    private var pingTimer: Timer?
    private var lastWebSocketMessageAt = Date()
    private var webSocketQuoteAt: [String: Date] = [:]
    private var quotes: [String: Quote] = [:]
    private var origins: [String: QuoteOrigin] = [:]
    private var receivedAt: [String: Date] = [:]
    private var errors: [String: String] = [:]
    private var restTasks: [String: URLSessionDataTask] = [:]
    private var connectionDescription = "正在连接 OKX"
    private let priceFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 8
        return f
    }()
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.watchlistKey), let parsed = try? InstrumentSelection.parse(saved.joined(separator: "\n")) { instrumentIDs = parsed }
        else { instrumentIDs = InstrumentSelection.defaultIDs }
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.autoenablesItems = false
        menu.delegate = self
        settings.onApply = { [weak self] text in self?.validateAndApply(text) }
        settings.onCancel = { [weak self] in self?.cancelValidation() }
        configureFloatingPanel()
        fetchRESTTickers()
        startWebSocket()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkConnectionHealth() }
        healthTimer?.tolerance = 1
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sendPing() }
        pingTimer?.tolerance = 2
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reconnectNow), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate(); pingTimer?.invalidate(); cancelValidation()
        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketSession?.invalidateAndCancel()
        restTasks.values.forEach { $0.cancel() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floatingPanel?.orderFrontRegardless()
        showSettings()
        return true
    }
    private func configureFloatingPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 174, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        floatingPanel = panel
        rebuildPanel()
        #if APP_VERIFICATION
        let frameName = "OKXVerificationFloatingPanel"
        #else
        let frameName = "OKXMUFloatingPanel"
        #endif
        let desiredSize = panel.frame.size
        if !panel.setFrameUsingName(frameName), let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - panel.frame.width - 24, y: screen.visibleFrame.maxY - panel.frame.height - 6))
        }
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - desiredSize.height, width: desiredSize.width, height: desiredSize.height), display: true)
        panel.setFrameAutosaveName(frameName)
        clampPanelToScreen()
        #if !APP_VERIFICATION
        panel.orderFrontRegardless()
        #endif
    }
    private func rebuildPanel() {
        guard let panel = floatingPanel else { return }
        let single = instrumentIDs.count == 1
        let width: CGFloat = single && InstrumentSelection.displayName(for: instrumentIDs[0]).count <= 6 ? 174 : 246
        let listHeight = CGFloat(min(instrumentIDs.count, 6)) * 40
        let size = NSSize(width: width, height: listHeight + (single ? 0 : 24))
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: width, height: size.height), display: true)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow; background.blendingMode = .withinWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 11; background.layer?.masksToBounds = true
        background.menu = menu
        quoteRows.removeAll()
        if single {
            let id = instrumentIDs[0]
            let row = QuoteRow(id: id, width: width, quoteMenu: menu)
            row.trailingSpace = 46
            row.detailLabel.frame.size.width = 123
            background.addSubview(row); quoteRows[id] = row
        } else {
            let header = NSTextField(labelWithString: "OKX · \(instrumentIDs.count) 个标的")
            header.frame = NSRect(x: 11, y: listHeight + 4, width: width - 65, height: 15)
            header.font = .systemFont(ofSize: 10, weight: .medium); header.textColor = .secondaryLabelColor; header.menu = menu
            background.addSubview(header)
            let document = NSView(frame: NSRect(x: 0, y: 0, width: width - 2, height: CGFloat(instrumentIDs.count) * 40))
            for (index, id) in instrumentIDs.enumerated() {
                let row = QuoteRow(id: id, width: width - 8, quoteMenu: menu)
                row.frame.origin.y = CGFloat(instrumentIDs.count - index - 1) * 40
                document.addSubview(row); quoteRows[id] = row
                if index > 0 {
                    let line = NSBox(frame: NSRect(x: 11, y: row.frame.maxY, width: width - 28, height: 1))
                    line.boxType = .separator; document.addSubview(line)
                }
            }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: listHeight))
            scroll.drawsBackground = false; scroll.hasVerticalScroller = instrumentIDs.count > 6
            scroll.autohidesScrollers = true; scroll.documentView = document
            background.addSubview(scroll)
            document.scroll(NSPoint(x: 0, y: document.frame.height))
        }
        let controlY: CGFloat = single ? 9 : listHeight + 2
        let gear = NSButton(frame: NSRect(x: width - 43, y: controlY, width: 18, height: 20))
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "选择标的")
        gear.imagePosition = .imageOnly; gear.isBordered = false; gear.contentTintColor = .secondaryLabelColor
        gear.target = self; gear.action = #selector(showSettings)
        gear.toolTip = "选择标的：添加、移除或调整显示顺序"
        gear.setAccessibilityIdentifier("watchlist-settings"); background.addSubview(gear)
        let close = NSButton(frame: NSRect(x: width - 24, y: controlY, width: 17, height: 20))
        close.title = "×"; close.isBordered = false; close.font = .systemFont(ofSize: 16, weight: .medium)
        close.contentTintColor = .secondaryLabelColor; close.target = self; close.action = #selector(quit); close.toolTip = "退出行情"
        background.addSubview(close)
        panel.contentView = background
        instrumentIDs.forEach(renderRow)
        clampPanelToScreen()
    }
    private func clampPanelToScreen() {
        guard let panel = floatingPanel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: max(visible.minX + 4, min(frame.minX, visible.maxX - frame.width - 4)), y: max(visible.minY + 4, min(frame.minY, visible.maxY - frame.height - 4))))
    }
    @objc private func showSettings() { settings.show(instrumentIDs: instrumentIDs) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func reconnectNow() { reconnectAttempt = 0; fetchRESTTickers(); startWebSocket() }
    @objc private func openInstrument(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let url = InstrumentSelection.tradingURL(for: id) else { return }
        NSWorkspace.shared.open(url)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "OKX · \(instrumentIDs.count) 个标的", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        for id in instrumentIDs {
            let quote = quotes[id]
            let item = NSMenuItem(title: "\(id)  \(quote.map { price($0.last) } ?? "—")", action: nil, keyEquivalent: "")
            let details = NSMenu(); details.autoenablesItems = false
            let lines = [
                "最新成交：\(quote.map { price($0.last) } ?? "—") \(InstrumentSelection.quoteCurrency(for: id))",
                "24h：\(quote?.change24h.map { String(format: "%+.2f%%", $0) } ?? "—")",
                "买一 / 卖一：\(quote?.bid.map(price) ?? "—") / \(quote?.ask.map(price) ?? "—")",
                "行情时间：\(quote?.serverTime.map { timestampFormatter.string(from: $0) } ?? "—")",
                "状态：\(errors[id] ?? connectionDescription)"
            ]
            for line in lines { let detail = NSMenuItem(title: line, action: nil, keyEquivalent: ""); detail.isEnabled = false; details.addItem(detail) }
            details.addItem(.separator())
            let open = actionItem("打开 OKX 标的", #selector(openInstrument(_:))); open.representedObject = id
            details.addItem(open); item.submenu = details; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("选择标的…", #selector(showSettings), key: ","))
        menu.addItem(actionItem("立即重连", #selector(reconnectNow), key: "r"))
        menu.addItem(actionItem("退出行情", #selector(quit), key: "q"))
    }
    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; return item
    }
    private func cancelValidation() { validationID = UUID(); validationTask?.cancel(); validationTask = nil }
    private func validateAndApply(_ text: String) {
        cancelValidation()
        do { let ids = try InstrumentSelection.parse(text); validateNext(ids, index: 0, collected: [:], token: validationID) }
        catch { settings.setValidationState(isValidating: false, message: error.localizedDescription, isError: true) }
    }
    private func validateNext(_ ids: [String], index: Int, collected: [String: Quote], token: UUID) {
        guard validationID == token else { return }
        guard index < ids.count else { applyWatchlist(ids, initialQuotes: collected); settings.closeAfterApplying(); return }
        let id = ids[index]
        settings.setValidationState(isValidating: true, message: "正在检查 \(index + 1)/\(ids.count) · \(id)")
        let task = OKXMarketAPI.tickerTask(for: id) { [weak self] result in
            guard let self, self.validationID == token else { return }
            self.validationTask = nil
            switch result {
            case .success(let quote):
                var next = collected; next[id] = quote
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.validateNext(ids, index: index + 1, collected: next, token: token) }
            case .failure(let error):
                self.settings.setValidationState(isValidating: false, message: "\(id)：\(error.localizedDescription)\n列表尚未更改，修改后可重新保存。", isError: true)
            }
        }
        validationTask = task; task.resume()
    }
    private func applyWatchlist(_ ids: [String], initialQuotes: [String: Quote]) {
        watchlistID = UUID(); restTasks.values.forEach { $0.cancel() }; restTasks.removeAll()
        instrumentIDs = ids; defaults.set(ids, forKey: Self.watchlistKey)
        quotes = initialQuotes
        origins = Dictionary(uniqueKeysWithValues: ids.map { ($0, .restFallback) })
        receivedAt = Dictionary(uniqueKeysWithValues: ids.map { ($0, Date()) })
        errors.removeAll(); webSocketQuoteAt.removeAll(); rebuildPanel(); reconnectAttempt = 0; startWebSocket()
    }
    private func startWebSocket() {
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil; connectionID = UUID()
        let token = connectionID
        webSocketTask?.cancel(with: .goingAway, reason: nil); webSocketSession?.invalidateAndCancel()
        webSocketQuoteAt.removeAll(); lastWebSocketMessageAt = Date(); connectionDescription = "正在连接 OKX"
        let configuration = URLSessionConfiguration.default; configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: URL(string: "wss://ws.okx.com:8443/ws/v5/public")!)
        webSocketSession = session; webSocketTask = task; task.resume()
        let request = OKXSubscriptionRequest(op: "subscribe", args: instrumentIDs.map { OKXSubscription(channel: "tickers", instId: $0) })
        guard let data = try? JSONEncoder().encode(request), let message = String(data: data, encoding: .utf8) else { return }
        task.send(.string(message)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.connectionID == token else { return }
                if let error { self.scheduleReconnect(reason: error.localizedDescription) }
                else { self.receiveNextMessage(from: task, token: token) }
            }
        }
    }
    private func receiveNextMessage(from task: URLSessionWebSocketTask, token: UUID) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.connectionID == token, self.webSocketTask === task else { return }
                switch result {
                case .failure(let error): self.scheduleReconnect(reason: error.localizedDescription)
                case .success(let message):
                    self.lastWebSocketMessageAt = Date()
                    switch message {
                    case .string(let text): self.handleWebSocketPayload(Data(text.utf8))
                    case .data(let data): self.handleWebSocketPayload(data)
                    @unknown default: break
                    }
                    if self.connectionID == token, self.webSocketTask === task { self.receiveNextMessage(from: task, token: token) }
                }
            }
        }
    }
    private func handleWebSocketPayload(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(OKXEnvelope.self, from: data) else { return }
        if envelope.event == "error" || (envelope.code != nil && envelope.code != "0") {
            if let id = envelope.arg?.instId, instrumentIDs.contains(id) { errors[id] = envelope.msg ?? "OKX 拒绝了此标的订阅"; renderRow(id) }
            else { scheduleReconnect(reason: envelope.msg ?? "OKX 暂时无法订阅") }
            return
        }
        if envelope.event == "subscribe" { connectionDescription = "OKX WebSocket 已连接" }
        for ticker in envelope.data ?? [] {
            guard instrumentIDs.contains(ticker.instId), let quote = Quote(ticker: ticker) else { continue }
            reconnectAttempt = 0; webSocketQuoteAt[ticker.instId] = Date(); connectionDescription = "OKX WebSocket 实时推送"
            accept(quote, for: ticker.instId, origin: .webSocket)
        }
    }
    private func fetchRESTTickers() { instrumentIDs.forEach(fetchRESTTicker) }
    private func fetchRESTTicker(_ id: String) {
        guard restTasks[id] == nil else { return }
        let generation = watchlistID
        let task = OKXMarketAPI.tickerTask(for: id) { [weak self] result in
            guard let self, self.watchlistID == generation, self.instrumentIDs.contains(id) else { return }
            self.restTasks[id] = nil
            switch result {
            case .success(let quote): self.accept(quote, for: id, origin: .restFallback)
            case .failure(let error): self.errors[id] = error.localizedDescription; self.renderRow(id)
            }
        }
        restTasks[id] = task; task.resume()
    }
    private func accept(_ quote: Quote, for id: String, origin: QuoteOrigin) {
        // Ignore HTTP responses that arrived after a newer streaming quote.
        if let previous = quotes[id]?.serverTime, let next = quote.serverTime, next < previous { return }
        quotes[id] = quote; origins[id] = origin; receivedAt[id] = Date(); errors[id] = nil; renderRow(id)
    }
    private func checkConnectionHealth() {
        let now = Date()
        for id in instrumentIDs {
            if quotes[id] == nil || now.timeIntervalSince(webSocketQuoteAt[id] ?? .distantPast) > 15 { fetchRESTTicker(id) }
            renderRow(id)
        }
        if webSocketTask != nil && now.timeIntervalSince(lastWebSocketMessageAt) > 45 { scheduleReconnect(reason: "连接暂时无响应") }
    }
    private func sendPing() {
        guard let task = webSocketTask else { return }
        let token = connectionID
        task.send(.string("ping")) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.connectionID == token, let error else { return }
                self.scheduleReconnect(reason: error.localizedDescription)
            }
        }
    }
    private func scheduleReconnect(reason: String) {
        guard reconnectWorkItem == nil else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil); webSocketTask = nil
        webSocketSession?.invalidateAndCancel(); webSocketSession = nil; connectionID = UUID()
        reconnectAttempt = min(reconnectAttempt + 1, 7)
        let delay = min(pow(2, Double(reconnectAttempt - 1)), 60)
        connectionDescription = "\(Int(delay)) 秒后重连 · \(reason)"
        instrumentIDs.forEach(renderRow)
        let work = DispatchWorkItem { [weak self] in self?.reconnectWorkItem = nil; self?.startWebSocket() }
        reconnectWorkItem = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func renderRow(_ id: String) {
        guard let row = quoteRows[id] else { return }
        let name = InstrumentSelection.displayName(for: id)
        guard let quote = quotes[id] else {
            row.setPrice("—", symbol: name, color: errors[id] == nil ? .secondaryLabelColor : .systemRed)
            row.detailLabel.stringValue = errors[id] == nil ? "OKX · 正在连接" : "OKX · 更新失败，自动重试"
            row.toolTip = "\(id)\n\(errors[id] ?? connectionDescription)\n点击齿轮选择标的；右键查看详情。"
            return
        }
        let stale = Date().timeIntervalSince(receivedAt[id] ?? .distantPast) > 30
        let change = quote.change24h ?? 0
        row.setPrice(compactPrice(quote.last), symbol: name, color: stale ? .secondaryLabelColor : change < 0 ? .systemRed : change > 0 ? .systemGreen : .labelColor)
        let percentage = quote.change24h.map { "\($0 < 0 ? "▼" : "▲") \(String(format: "%.2f%%", abs($0)))" } ?? "—"
        let suffix = stale ? " · 更新暂停" : errors[id] != nil ? " · 重试中" : origins[id] == .restFallback ? " · 轮询" : ""
        let market = instrumentIDs.count == 1 ? "" : "\(InstrumentSelection.marketName(for: id)) · "
        row.detailLabel.stringValue = "OKX · \(market)24h \(percentage)\(suffix)"
        row.toolTip = "\(id) · \(price(quote.last)) \(InstrumentSelection.quoteCurrency(for: id))\n行情时间：\(quote.serverTime.map { timestampFormatter.string(from: $0) } ?? "—")\n\(errors[id] ?? connectionDescription)\n可拖动；点击齿轮选择标的；右键查看详情。"
    }
    private func compactPrice(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.0f", value) }
        if value >= 100 { return String(format: "%.1f", value) }
        if value >= 1 { return String(format: "%.2f", value) }
        if value >= 0.01 { return String(format: "%.4f", value) }
        return price(value)
    }
    private func price(_ value: Double) -> String {
        if value > 0 && value < 0.00000001 { return String(format: "%.5g", value) }
        return priceFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

#if APP_VERIFICATION
extension AppDelegate {
    func beginVerification() {
        Task { @MainActor in
            func waitFor(_ predicate: () -> Bool, seconds: Double = 25) async -> Bool {
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline {
                    if predicate() { return true }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                return predicate()
            }
            var results: [String: Bool] = [:]
            results["live_quotes_for_all"] = await waitFor { self.instrumentIDs.allSatisfy { self.quotes[$0] != nil } }
            results["websocket_for_all"] = await waitFor { self.instrumentIDs.allSatisfy { self.origins[$0] == .webSocket } }
            results["three_native_rows"] = self.quoteRows.count == 3 && self.floatingPanel?.frame.size == NSSize(width: 246, height: 144)
            let live = self.instrumentIDs.map { id in ["id": id, "text": self.quoteRows[id]?.priceLabel.stringValue ?? "", "last": String(self.quotes[id]?.last ?? 0)] }
            if let view = self.floatingPanel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "work/MUMenuBar/QA/multi-panel.png"))
            }
            self.validateAndApply("ETH, MU, BTC-USDT")
            results["valid_manual_save"] = await waitFor { self.defaults.stringArray(forKey: Self.watchlistKey) == ["ETH-USDT-SWAP", "MU-USDT-SWAP", "BTC-USDT"] }
            let original = self.instrumentIDs
            self.validateAndApply("MU, FAKEZZZZ-USDT-SWAP")
            @MainActor func fields(_ view: NSView) -> [String] {
                (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(fields)
            }
            results["unknown_id_error"] = await waitFor { self.settings.window?.contentView.map { fields($0).contains { $0.contains("找不到") && $0.contains("列表尚未更改") } } ?? false }
            results["invalid_save_keeps_list"] = self.instrumentIDs == original && self.defaults.stringArray(forKey: Self.watchlistKey) == original
            self.validateAndApply("")
            results["empty_save_keeps_list"] = self.instrumentIDs == original
            self.validateAndApply("BTC, ETH")
            self.cancelValidation()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            results["cancel_keeps_list"] = self.instrumentIDs == original
            results["reload_saved_selection"] = AppDelegate(defaults: self.defaults).instrumentIDs == original
            results["tiny_price_not_zero"] = self.price(0.00000000123) != "0"
            let longRow = QuoteRow(id: "BTC-USD-261225-100000-C", width: 238, quoteMenu: self.menu)
            longRow.setPrice("0.12345678", symbol: "BTC-USD-261225-100000-C", color: .labelColor)
            let requiredPriceWidth = (longRow.priceLabel.stringValue as NSString).size(withAttributes: [.font: longRow.priceLabel.font!]).width
            results["long_id_keeps_price_visible"] = longRow.priceLabel.frame.width >= requiredPriceWidth && longRow.symbolLabel.frame.maxX < longRow.priceLabel.frame.minX
            if let id = original.first, let quote = self.quotes[id] {
                let older = OKXTicker(instId: id, last: "1", bidPx: nil, askPx: nil, open24h: nil, ts: "1000")
                self.accept(Quote(ticker: older)!, for: id, origin: .restFallback)
                results["older_http_cannot_overwrite"] = self.quotes[id]?.last == quote.last
                self.receivedAt[id] = Date().addingTimeInterval(-31); self.renderRow(id)
                results["stale_price_labeled"] = self.quoteRows[id]?.detailLabel.stringValue.contains("更新暂停") == true
            }
            self.instrumentIDs = (0..<20).map { "TEST\($0)-USDT-SWAP" }; self.rebuildPanel()
            let scroll = self.floatingPanel?.contentView?.subviews.compactMap { $0 as? NSScrollView }.first
            results["twenty_rows_scroll"] = self.quoteRows.count == 20 && scroll?.hasVerticalScroller == true && self.floatingPanel?.frame.height == 264
            results["scroll_starts_at_first_row"] = scroll.map { abs($0.documentVisibleRect.maxY - 800) < 2 } ?? false
            let report: [String: Any] = ["checks": results, "live": live]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data.write(to: URL(fileURLWithPath: "work/MUMenuBar/QA/verification.json"))
            print(String(data: data, encoding: .utf8)!)
            self.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            exit(results.values.allSatisfy { $0 } ? 0 : 1)
        }
    }
}
@main
enum VerificationMain {
    private static var delegate: AppDelegate!
    static func main() {
        let application = NSApplication.shared
        let domain = "com.zhuangtingyou.mumenubar.verification.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(["MU-USDT-SWAP", "BTC-USDT", "ETH-USDT-SWAP"], forKey: "okxWatchlistInstrumentIDs")
        delegate = AppDelegate(defaults: defaults)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        DispatchQueue.main.async { delegate.beginVerification() }
        application.run()
    }
}
#else
@main
enum MUMenuBarMain {
    private static let delegate = AppDelegate()
    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
#endif
