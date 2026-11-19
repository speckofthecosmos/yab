import AppKit
import Combine
import SwiftUI
import WebKit

extension Browser {
    var linkCard: LinkCard { LinkCard.of(self) }
}

/// Owns a pointer read before an anchor (and therefore a Pointed) exists.
/// Tickets start when queued, so a document commit cancels both queued
/// work and a DOM answer already on its way back from WebKit.
struct LinkCardQueries {
    struct Ticket: Equatable {
        fileprivate let source: UUID
        fileprivate let generation: Int
    }
    private var generation = 0
    private var current: Ticket?

    mutating func begin(for source: UUID) -> Ticket {
        generation += 1
        let ticket = Ticket(source: source, generation: generation)
        current = ticket
        return ticket
    }

    func accepts(_ ticket: Ticket) -> Bool { current == ticket }
    mutating func cancel() { current = nil }

    @discardableResult
    mutating func cancel(for source: UUID) -> Bool {
        guard current?.source == source else { return false }
        current = nil
        return true
    }
}

/// Link previews live in a nonactivating child window so their edges are
/// the screen's, not the page's. Escape deliberately leaves this card up;
/// a click still belongs to the page, including Shift-click for Peek.
@MainActor
final class LinkCard {
    static let key = "links.preview"
    private static let all = NSMapTable<Browser, LinkCard>.weakToStrongObjects()
    static func of(_ browser: Browser) -> LinkCard {
        if let card = all.object(forKey: browser) { return card }
        let card = LinkCard(browser)
        all.setObject(card, forKey: browser)
        return card
    }

    final class Model: ObservableObject {
        @Published var page = LinkSummary.Page()
        @Published var preview = LinkSummary.Preview()
        @Published var image: NSImage?
        @Published var phase = "idle"
        @Published var up = false
        @Published var below = true
        var url: URL?
        /// The Share button in the card's host, top-left based (LinkCardHost).
        var shareRect = CGRect.zero
    }

    private struct Pointed {
        var url: URL
        var rect: CGRect
        var css: CGPoint
        var source: Tab
    }
    private struct Key: Hashable { var store: ObjectIdentifier; var url: URL }
    private struct Cached {
        weak var store: WKWebsiteDataStore?
        var page: LinkSummary.Page
        var preview: LinkSummary.Preview
        var image: NSImage?
        var at: Date
    }
    private weak var browser: Browser?
    private var pointed: Pointed?
    private var panel: LinkCardPanel?
    private var host: NSHostingView<LinkCardContents>?
    private let model = Model()
    private var pending: DispatchWorkItem?
    private var hitTesting: DispatchWorkItem?
    private var lighting: DispatchWorkItem?
    private var leaving: DispatchWorkItem?
    /// The Share menu, then the service it opened, is up: the pointer is
    /// off the card on purpose, so leaving it must not put the card away.
    private var sharing: LinkCardSharing?
    /// Share is still on screen: its picker (a popover, or a menu) is up.
    /// One that went without a word to its delegate ends sharing here.
    private var sharingUp: Bool {
        guard let sharing else { return false }
        // The picker's window comes a moment after the press; the browser
        // window resigning key on the way asked here before it was up.
        if Date().timeIntervalSince(sharing.since) < 1 { return true }
        let up = NSApp.windows.contains { window in
            let kind = String(describing: type(of: window))
            return window.isVisible && (kind.contains("Popover") || kind.contains("Menu"))
        }
        if !up { self.sharing = nil }
        return up
    }
    private var cooling: DispatchWorkItem?
    private var reading: Task<Void, Never>?
    private var loader: LinkCardLoad?
    private var loaderKey: Key?
    private var cache: [Key: Cached] = [:]
    private var serial = 0
    private var queries = LinkCardQueries()
    private var displayedGeneration: Int?
    private var heard = 0
    private var lastHit = "idle"
    private var rest: CGPoint?
    private var monitors: [Any] = []
    private var notes: [Any] = []
    private var watching = Set<AnyCancellable>()
    /// Fixture pages retain real URL/cookie semantics; only the host's
    /// selector list can be substituted on an isolated --test run.
    var pretendHost: String?

    private init(_ browser: Browser) {
        self.browser = browser
        browser.changes(\.activeID).dropFirst().sink { [weak self] _ in self?.dismiss() }.store(in: &watching)
        browser.prefs.changes(\.linkPreviews).dropFirst().sink { [weak self] on in
            if !on { self?.dismiss(); self?.clearWarm(); self?.cache.removeAll() }
        }.store(in: &watching)
        browser.changes(\.tabs).sink { [weak self] tabs in
            guard let self, let source = self.pointed?.source, !tabs.contains(where: { $0 === source }) else { return }
            self.dismiss(); self.clearWarm()
        }.store(in: &watching)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged, .scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged, .rightMouseDown]) { [weak self] event in
            AppKitMainThread.sync { self?.event(event) }
            return event
        } as Any)
        for name in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didResignKeyNotification] {
            notes.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                AppKitMainThread.sync {
                    guard let self, !self.sharingUp else { return }
                    if name == NSApplication.didResignActiveNotification || (note.object as? NSWindow) === self.pointed?.source.builtPage?.window {
                        self.dismiss()
                        if name == NSWindow.willCloseNotification { self.clearWarm(); self.cache.removeAll() }
                    }
                }
            })
        }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        notes.forEach(NotificationCenter.default.removeObserver)
        reading?.cancel()
        hitTesting?.cancel()
    }

    private var overCard: Bool { model.up && panel?.isVisible == true && cardFrame.contains(NSEvent.mouseLocation) == true }

    /// The clear room round the card in its panel, for the shadow the
    /// card's frame casts: a borderless window cuts a shadow at its edge.
    static let room: CGFloat = 32
    /// The card host's own coordinates, for the Share button's place.
    static let space = "link-card"
    /// The card on screen, its panel less the room.
    private var cardFrame: NSRect { (panel?.frame ?? .zero).insetBy(dx: Self.room, dy: Self.room) }

    private func readPointer(in source: Tab, web: any PageHandle, mouse: CGPoint, flags: NSEvent.ModifierFlags,
                             ticket: LinkCardQueries.Ticket) {
        guard queries.accepts(ticket), let browser, browser.prefs.linkPreviews, !source.bench,
              source.id == browser.activeID, source.builtPage === web, web.window?.isVisible == true,
              browser.peeking == nil else { return }
        if overCard { leaving?.cancel(); return }
        var local = web.convert(web.window!.convertPoint(fromScreen: mouse), from: nil)
        guard web.bounds.contains(local) else { leave(); return }
        if !web.isFlipped { local.y = web.bounds.height - local.y }
        let fake = Store.testing ? pretendHost ?? "" : ""
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [fake]), encoding: .utf8)!
        let js = "window.__yabLinkCardInfo && __yabLinkCardInfo(\(local.x),\(local.y),\(web.bounds.width),\(quoted)[0])"
        web.run(js, in: .yab) { [weak self, weak source, weak web] result in
            guard let self, let source, let web, self.queries.accepts(ticket), source.id == self.browser?.activeID else { return }
            guard case .success(let value) = result, let info = value as? [String: Any],
                  let address = (info["url"] as? String).flatMap(URL.init(string:)), LinkCardRules.web(address), !CallLink.isCall(address),
                  let box = info["box"] as? [NSNumber], box.count == 4,
                  let unit = info["unit"] as? Double, unit > 0, let window = web.window
            else { if Store.testing { self.lastHit = "no anchor" }; self.leave(); return }
            let selecting = info["selection"] as? Bool ?? true
            let holding = !selecting && self.model.up && self.pointed?.source === source && self.pointed?.url == address && LinkStatus.clicking(flags).isEmpty
            guard holding || LinkCardRules.eligible(flags: flags, selection: selecting, peekClick: PeekClick.read(in: Store.settings)) else {
                if Store.testing { self.lastHit = "ineligible" }
                self.leave(); return
            }
            if Store.testing { self.lastHit = "eligible" }
            var rect = CGRect(x: box[0].doubleValue / unit, y: box[1].doubleValue / unit,
                              width: box[2].doubleValue / unit, height: box[3].doubleValue / unit)
            if !web.isFlipped { rect.origin.y = web.bounds.height - rect.maxY }
            guard rect.width > 0, rect.height > 0, web.bounds.intersects(rect) else { self.leave(); return }
            let next = Pointed(url: address, rect: window.convertToScreen(web.convert(rect, to: nil)),
                               css: CGPoint(x: local.x * unit, y: local.y * unit), source: source)
            self.arrive(next, mouse: mouse)
        }
    }

    private func arrive(_ next: Pointed, mouse: CGPoint) {
        let same = pointed?.url == next.url && pointed?.source === next.source && pointed?.rect == next.rect
        leaving?.cancel()
        if same, panel?.isVisible == true, model.up { return }
        if same, let rest, hypot(rest.x - mouse.x, rest.y - mouse.y) < 3 { return }
        dismiss()
        pointed = next
        rest = mouse
        if !next.source.shy { LinkSummary.warm() }
        serial += 1
        let generation = serial
        let light = DispatchWorkItem { [weak self] in
            guard let self, self.serial == generation else { return }
            self.highlight(true)
        }
        lighting = light
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkCardRules.highlight, execute: light)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.serial == generation, self.browser?.prefs.linkPreviews == true else { return }
            self.load(next, generation: generation)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkCardRules.dwell, execute: work)
    }

    private func readEvent(_ event: NSEvent) {
        // The app's actual pointer events, including stationary Shift.
        // WebKit's private status-link callback only changes on movement.
        hitTesting?.cancel(); hitTesting = nil
        queries.cancel()
        guard browser?.prefs.linkPreviews == true,
              let source = browser?.active, !source.bench, let web = source.builtPage, let window = web.window,
              event.window === window || (event.type == .flagsChanged && event.window == nil && window.isKeyWindow) else { return }
        if Store.testing { heard += 1 }
        let mouse = event.type == .mouseMoved ? window.convertPoint(toScreen: event.locationInWindow) : NSEvent.mouseLocation
        if !model.up, let rest, hypot(rest.x - mouse.x, rest.y - mouse.y) >= 3 { dismiss() }
        let ticket = queries.begin(for: source.id)
        let work = DispatchWorkItem { [weak self, weak source, weak web] in
            guard let self, let source, let web else { return }
            self.readPointer(in: source, web: web, mouse: mouse, flags: event.modifierFlags, ticket: ticket)
        }
        hitTesting = work
        // A moving pointer queues no stream of WebKit IPC requests.
        if event.type == .flagsChanged { work.perform() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work) }
    }

    private func event(_ event: NSEvent) {
        defer {
            if event.type == .mouseMoved || event.type == .flagsChanged { readEvent(event) }
        }
        guard let point = pointed, !sharingUp else { return }
        switch event.type {
        case .flagsChanged:
            // Releasing Shift after a card came leaves it under the hand.
            if panel?.isVisible == true, LinkStatus.clicking(event.modifierFlags).isEmpty { return }
            break
        case .mouseMoved:
            if overCard || point.rect.contains(NSEvent.mouseLocation) { leaving?.cancel() } else { leave() }
        case .keyDown:
            if event.keyCode != 53 { dismiss() }
        case .scrollWheel:
            if event.window === point.source.builtPage?.window { dismiss() }
        case .leftMouseDragged:
            if !overCard { dismiss() }
        case .leftMouseDown, .rightMouseDown:
            // Keep the warm page and the card's origin through a click on
            // the source link; Browser.peek takes them synchronously.
            if !overCard && !point.rect.contains(NSEvent.mouseLocation) { dismiss() }
        default: break
        }
    }

    private func leave() {
        guard pointed != nil, !sharingUp else { return }
        guard !overCard else { leaving?.cancel(); return }
        if panel?.isVisible != true { dismiss(); return }
        guard leaving?.isCancelled != false else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overCard else { return }
            self.dismiss()
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LinkCardRules.linger, execute: work)
    }

    private func highlight(_ on: Bool) {
        guard let point = pointed, let web = point.source.builtPage else { return }
        web.run("window.__yabLinkCardLightAt && __yabLinkCardLightAt(\(point.css.x),\(point.css.y),\(on))", in: .yab) { _ in }
    }

    func forget(_ source: Tab) {
        source.builtPage?.window?.acceptsMouseMovedEvents = true
        // didCommit may arrive before the DOM reply assigned Pointed.
        if queries.cancel(for: source.id) {
            hitTesting?.cancel(); hitTesting = nil
        }
        if pointed?.source === source { dismiss(); clearWarm() }
    }

    func dismiss() {
        serial += 1; queries.cancel()
        displayedGeneration = nil
        hitTesting?.cancel(); hitTesting = nil
        pending?.cancel(); pending = nil
        lighting?.cancel(); lighting = nil
        leaving?.cancel(); leaving = nil
        reading?.cancel(); reading = nil
        highlight(false)
        let old = panel
        if old?.isVisible == true {
            model.up = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                if self?.panel === old, self?.model.up == true { return }
                old?.parent?.removeChildWindow(old!)
                old?.orderOut(nil)
            }
        }
        pointed = nil; rest = nil
        if loader?.finished != true || loader?.page.shy == true { clearWarm() }
        else {
            cooling?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.clearWarm() }
            cooling = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
    }

    private func clearWarm() {
        cooling?.cancel(); cooling = nil
        loader?.cancel(); loader = nil; loaderKey = nil
    }

    private func load(_ point: Pointed, generation: Int) {
        let key = Key(store: ObjectIdentifier(point.source.store), url: point.url)
        cooling?.cancel()
        if loaderKey != key { clearWarm() }
        let old = cache[key].flatMap { value in
            value.store === point.source.store && Date().timeIntervalSince(value.at) < LinkCardRules.lifetime ? value : nil
        }
        model.url = point.url
        model.page = .init(); model.phase = "idle"
        model.preview = .init(); model.image = nil
        if let old {
            model.page = old.page; model.preview = old.preview; model.image = old.image; model.phase = "ready"
            displayedGeneration = generation
            draw()
        }
        if loader == nil { loader = LinkCardLoad(url: point.url, source: point.source); loaderKey = key }
        guard let loader else { return }
        reading = Task { [weak self, weak loader] in
            guard let self, let loader else { return }
            do {
                let page = try await loader.read()
                guard serial == generation, !Task.isCancelled else { return }
                if old != nil { return }
                model.page = page
                model.phase = page.title.isEmpty && page.description.isEmpty ? "unavailable" : "loading"
                displayedGeneration = generation
                draw()
                async let picture: Void = loadImage(page, url: loader.page.address ?? point.url, store: point.source.store, generation: generation)
                // Otherwise the card keeps its title and picture.
                if model.phase != "unavailable", AIUse.allows(.background, for: point.source) {
                    await LinkSummary.preview(page, cloud: !point.source.shy) { [weak self] preview in
                        guard let self, self.serial == generation, !Task.isCancelled else { return }
                        self.model.preview = preview
                        self.draw()
                    }
                }
                await picture
                guard serial == generation, !Task.isCancelled else { return }
                if model.phase != "unavailable" { model.phase = "ready" }
                draw()
                if !point.source.shy, model.phase == "ready" {
                    cache[key] = Cached(store: point.source.store, page: page, preview: model.preview, image: model.image, at: Date())
                    if cache.count > 48, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
                }
            } catch {
                guard serial == generation, !Task.isCancelled else { return }
                model.page = .init(); model.phase = "unavailable"; model.preview = .init(); model.image = nil
                displayedGeneration = generation
                draw()
                clearWarm()
            }
        }
    }

    private func loadImage(_ page: LinkSummary.Page, url: URL, store: WKWebsiteDataStore, generation: Int) async {
        let image = await LinkCardLoad.image(page.image, relativeTo: url, store: store)
        guard serial == generation, !Task.isCancelled else { return }
        model.image = image
        draw()
    }

    private func draw() {
        guard displayedGeneration == serial, let point = pointed, model.url == point.url,
              let parent = point.source.builtPage?.window, parent.isVisible else { return }
        let fresh = panel == nil || panel?.parent !== parent
        if fresh {
            panel?.parent?.removeChildWindow(panel!)
            panel?.orderOut(nil)
            let made = LinkCardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            made.title = "Link Preview"
            made.isReleasedWhenClosed = false; made.isOpaque = false; made.backgroundColor = .clear
            made.hasShadow = false; made.hidesOnDeactivate = true; made.animationBehavior = .none
            let content = LinkCardHost(rootView: LinkCardContents(model: model, share: { [weak self] in self?.share() }))
            content.left = { [weak self] in self?.leave() }
            content.share = { [weak self] point in
                guard let self else { return false }
                guard self.model.phase == "ready", self.model.shareRect.contains(point) else { return false }
                self.share()
                return true
            }
            content.resized = { [weak self] in self?.draw() }
            content.sizingOptions = [.intrinsicContentSize]
            content.safeAreaRegions = []
            content.wantsLayer = true
            made.host = content
            made.contentView = WindowHosting.measured(content)
            host = content; panel = made
        }
        guard let panel, let host else { return }
        let wasVisible = panel.isVisible && model.up
        host.layoutSubtreeIfNeeded()
        let height = max(72, ceil(host.intrinsicContentSize.height) - 2 * Self.room)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: point.rect.midX, y: point.rect.midY)) }) ?? parent.screen
        let frame = LinkCardRules.place(link: point.rect, size: CGSize(width: LinkCardRules.width, height: height),
                                       screen: screen?.visibleFrame ?? parent.frame)
        let below = frame.maxY <= point.rect.minY
        if model.below != below { model.below = below }
        let room = frame.insetBy(dx: -Self.room, dy: -Self.room)
        if panel.frame != room { panel.setFrame(room, display: true) }
        if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
        panel.appearance = parent.effectiveAppearance
        panel.orderFront(nil)
        if !wasVisible {
            model.up = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pointed != nil else { return }
                self.model.up = true
            }
        }
    }

    private var shares = 0
    private func share() {
        shares += 1
        guard let host, let url = model.url else { return }
        let words = ([model.page.title, model.preview.summary] + model.preview.facts.map { "\($0.label): \($0.text)" }).filter { !$0.isEmpty }.joined(separator: "\n")
        let picker = NSSharingServicePicker(items: [words, url])
        let watch = LinkCardSharing(window: pointed?.source.builtPage?.window ?? host.window) { [weak self] in
            guard let self else { return }
            self.sharing = nil
            if !self.overCard { self.leave() }
        }
        sharing = watch
        picker.delegate = watch
        // From the browser window under the card, at the button: the card's
        // own panel never becomes key, and a menu shown from it closed at once.
        let button = NSRect(x: cardFrame.maxX - 12 - 22, y: cardFrame.minY + 12, width: 22, height: 22)
        if let parent = pointed?.source.builtPage?.window, let view = parent.contentView {
            picker.show(relativeTo: view.convert(parent.convertFromScreen(button), from: nil), of: view, preferredEdge: .minY)
        } else {
            picker.show(relativeTo: host.bounds.insetBy(dx: Self.room, dy: Self.room), of: host, preferredEdge: .maxY)
        }
    }

    /// The warm page is transferred, never reloaded. Its card also supplies
    /// the opening picture and rectangle for Peek's existing morph.
    func take(_ url: URL, from source: Tab, over view: PeekView) -> (page: Tab?, origin: PeekOrigin?, finished: Bool) {
        guard let point = pointed, point.source === source, point.url == url else { return (nil, nil, false) }
        var origin: PeekOrigin?
        if let panel, panel.isVisible, let host, let window = view.window {
            let frame = view.convert(window.convertFromScreen(cardFrame), from: nil)
            let card = host.bounds.insetBy(dx: Self.room, dy: Self.room)
            let rep = host.bitmapImageRepForCachingDisplay(in: card)
            if let rep { host.cacheDisplay(in: card, to: rep) }
            origin = PeekOrigin(rect: frame, corner: Radius.floating, picture: rep?.cgImage)
        }
        let finished = loader?.finished == true
        let warm = loaderKey == Key(store: ObjectIdentifier(source.store), url: url) ? loader?.take() : nil
        if warm != nil { loader = nil; loaderKey = nil }
        dismiss()
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        return (warm, origin, warm != nil && finished)
    }

    var report: [String: Any] {
        let frame = panel?.isVisible == true ? cardFrame : .zero
        var report: [String: Any] = ["shown": model.up && panel?.isVisible == true, "phase": model.phase,
                "url": pointed?.url.absoluteString ?? "", "enabled": browser?.prefs.linkPreviews ?? false,
                "card": [frame.minX, frame.minY, frame.width, frame.height],
                "summary": model.preview.summary, "title": model.page.title, "facts": model.preview.facts.count,
                "warm": loader?.finished == true, "cache": cache.count, "model_available": FormModel.ready, "model_error": LinkSummary.lastError, "writer": LinkSummary.lastWriter, "sharing": sharingUp, "shares": shares,
                "window": panel?.isVisible == true ? panel?.windowNumber ?? 0 : 0]
        if Store.testing { report["native_events"] = heard; report["last_hit"] = lastHit }
        return report
    }

    var filmWindow: NSWindow? { panel?.isVisible == true ? panel : nil }
}

/// Hears the Share menu close with nothing chosen, or the chosen
/// service finish, and keeps that service's sheet on the card's window.
private final class LinkCardSharing: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private weak var window: NSWindow?
    private var done: (() -> Void)?
    let since = Date()
    init(window: NSWindow?, done: @escaping () -> Void) { self.window = window; self.done = done }
    private func finish() { let done = done; self.done = nil; DispatchQueue.main.async { done?() } }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor service: NSSharingService) -> NSSharingServiceDelegate? { self }
    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish() }
    }
    func sharingService(_ service: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { window }
    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { finish() }
    func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: any Error) { finish() }
}

private final class LinkCardPanel: NSPanel {
    weak var host: LinkCardHost?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private var sharing = false
    override func sendEvent(_ event: NSEvent) {
        if let host {
            // On the press, as a pop-up menu opens: a release never
            // reached this panel from the bench's click on adhd.
            if event.type == .leftMouseDown, host.share?(host.topLeft(event)) == true {
                sharing = true
                return
            }
            if event.type == .leftMouseUp, sharing {
                sharing = false
                return
            }
        }
        super.sendEvent(event)
    }
}

/// A card may extend past its parent window. Its own tracking area hears
/// a departure straight onto the desktop, where a local mouse monitor
/// otherwise receives no next mouseMoved event.
private final class LinkCardHost: NSHostingView<LinkCardContents> {
    var left: (() -> Void)?
    var resized: (() -> Void)?
    /// A press on Share, answered by the panel (LinkCardPanel): it never
    /// becomes key, and its SwiftUI button never heard a click (shares
    /// stayed 0 on adhd and main, 2026-10-21). Takes the point in this
    /// view, top-left based; false when it missed the button.
    var share: ((CGPoint) -> Bool)?
    private var area: NSTrackingArea?
    func topLeft(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.resized?() }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        // The card's own rect, not the clear room round it for its shadow.
        let next = NSTrackingArea(rect: bounds.insetBy(dx: LinkCard.room, dy: LinkCard.room),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        area = next
        addTrackingArea(next)
    }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); left?() }
}

private struct LinkCardContents: View {
    @ObservedObject var model: LinkCard.Model
    let share: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: LinkCardRules.width, height: 112).clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.url?.host().map(IDN.shown) ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.faint).lineLimit(1)
                if !model.page.title.isEmpty {
                    Text(model.page.title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if model.phase == "unavailable" {
                    Text("No preview").font(.system(size: 13)).foregroundStyle(Palette.faint)
                } else if model.phase == "loading", model.preview.summary.isEmpty {
                    RoundedRectangle(cornerRadius: Radius.small).fill(Palette.wash).frame(height: 9)
                    RoundedRectangle(cornerRadius: Radius.small).fill(Palette.wash).frame(width: 188, height: 9)
                } else {
                    let words = model.preview.summary.isEmpty ? String(model.page.description.prefix(220)) : model.preview.summary
                    if !words.isEmpty {
                        Text(words).font(.system(size: 13, weight: model.preview.summary.isEmpty ? .regular : .medium))
                            .foregroundStyle(Palette.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(model.preview.facts.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: row.icon).font(.system(size: 12)).foregroundStyle(Palette.faint).frame(width: 16)
                            (Text(row.label.trimmingCharacters(in: CharacterSet(charactersIn: ":")) + ": ").fontWeight(.semibold) + Text(row.text))
                                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if model.phase == "ready" {
                    HStack { Spacer(); Button(action: share) { Symbol("square.and.arrow.up", size: 11) }
                        .buttonStyle(.yab(.secondary, .small, icon: .square)).keyTip("Share Preview")
                        .focusable(false)
                        .accessibilityLabel("Share Preview")
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(LinkCard.space)) } action: { model.shareRect = $0 } }
                }
            }
            .padding(12)
        }
        .frame(width: LinkCardRules.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // The picture runs to the card's edge, so no inset of the card's
        // own: its ground, hairline and shadow at the floating corner.
        .clipShape(RoundedRectangle(cornerRadius: Radius.floating, style: .continuous))
        .shapeFrame(Radius.floating)
        .scaleEffect(x: reduced || model.up ? 1 : 0.96, y: reduced || model.up ? 1 : 0.03, anchor: model.below ? .top : .bottom)
        .animation(reduced ? nil : model.up ? Motion.glide : Motion.leave, value: model.up)
        .opacity(model.up ? 1 : 0)
        .animation(.linear(duration: model.up ? 0.08 : 0.14), value: model.up)
        .padding(LinkCard.room)
        .coordinateSpace(.named(LinkCard.space))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link preview")
    }
}
