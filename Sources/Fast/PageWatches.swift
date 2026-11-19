import AppKit
import JavaScriptCore
import SwiftUI
import WebKit

// "Tell me when it drops under $200 / is back in stock / the order ships"
// (docs/agent-asks.md, wave 1). The agent calls `watch_page` once with a
// check it writes over the page's words; from then on Yab reads the page on
// its own every so many minutes and runs the check with no model: the page
// fetched with the space's sign-ins (AgentRead), or, when that doesn't show
// the thing, an open tab of it as it is drawn. The check runs in a bare
// JavaScriptCore context, no page, no network, two seconds at most.
//
// The moment the check holds, a notification says so in words ("Sony
// WH-1000XM6 is $189, under the $200 you asked for") and the watch ends;
// until then the tab's row says "Watching: under $200", after it the value
// it found, for a day. A check that stops reading the page three times in a
// row wakes an agent once to write it again (`watch_page` with `watch` and
// `check`). It runs on this Mac only, while Yab is open, as routines do.

struct PageWatch: Codable, Identifiable, Equatable {
    let id: String
    /// The page, without its fragment.
    var url: String
    /// What it watches, short: "Sony WH-1000XM6".
    var name: String
    /// The condition in the user's words: "under $200", "in stock".
    var until: String
    /// The body of a function of (text, html, url, json, number) that
    /// returns { value, holds }, or null when the page doesn't show it.
    var check: String
    /// The notification's sentence, `{value}` for what it found.
    var tell: String?
    /// The tab it was set on, whose row says so.
    var tab: UUID?
    /// The space whose sign-ins read it.
    var space: UUID?
    /// Minutes between reads.
    var every: Double
    var started: Date
    /// Over on its own after this, said nowhere.
    var expires: Date
    var checked: Date?
    /// What the check read last.
    var value: String?
    /// Reads in a row that found nothing, and why the last one didn't.
    var misses = 0
    var trouble: String?
    /// An agent was woken to write the check again.
    var woke: Bool?
    /// It held: when, and the sentence said.
    var held: Date?
    var said: String?

    var active: Bool { held == nil }
}

/// What a check made of a page.
enum WatchRead: Equatable {
    case holds(String)
    case not(String)
    case miss(String)

    var value: String? {
        switch self {
        case .holds(let value), .not(let value): return value
        case .miss: return nil
        }
    }
}

/// The parts of a watch with no Yab around them, for the tests.
enum PageWatchCheck {
    /// Reads in a row that find nothing before an agent writes it again.
    static let missesToWake = 3
    /// How long a held watch's value stays on its row.
    static let shownFor: TimeInterval = 86_400

    /// The page's address as a watch keeps it and rows match it.
    static func key(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        return parts.url?.absoluteString
    }

    /// The sentence a hit says: the agent's own with the value in it, or
    /// "Sony WH-1000XM6 is $189 (under $200)".
    static func sentence(_ watch: PageWatch, value: String) -> String {
        if let tell = watch.tell?.trimmingCharacters(in: .whitespacesAndNewlines), !tell.isEmpty {
            return tell.contains("{value}") ? tell.replacingOccurrences(of: "{value}", with: value) : tell
        }
        return "\(watch.name) is \(value) (\(watch.until))"
    }

    /// The words at the end of its tab's row.
    static func words(_ watch: PageWatch, now: Date, short: Bool = false) -> (text: String, loud: Bool)? {
        if let held = watch.held {
            guard now.timeIntervalSince(held) < shownFor, let value = watch.value else { return nil }
            return (value, true)
        }
        guard now < watch.expires else { return nil }
        return (short ? "Watching" : "Watching: " + watch.until, false)
    }

    /// Whether it reads now.
    static func due(_ watch: PageWatch, now: Date) -> Bool {
        guard watch.active, now < watch.expires else { return false }
        guard let checked = watch.checked else { return true }
        return now.timeIntervalSince(checked) >= watch.every * 60 - 5
    }

    /// Whether a miss just made is the one that wakes an agent.
    static func wakes(_ watch: PageWatch) -> Bool { watch.misses >= missesToWake && watch.woke != true }

    /// JavaScriptCore's own time limit, which it exports but doesn't declare.
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    nonisolated(unsafe) private static let setLimit: SetLimit? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
        .map { unsafeBitCast($0, to: SetLimit.self) }

    /// The check over a page's words: what it read and whether the
    /// condition holds, or why it read nothing. Off the main thread.
    static func run(_ check: String, text: String, html: String = "", url: String = "", seconds: Double = 2) -> WatchRead {
        guard let context = JSContext() else { return .miss("no JavaScript") }
        setLimit?(JSContextGetGroup(context.jsGlobalContextRef), seconds, nil, nil)
        var thrown: String?
        context.exceptionHandler = { _, error in thrown = error?.toString() ?? "an error" }
        context.setObject(text, forKeyedSubscript: "__text" as NSString)
        context.setObject(html, forKeyedSubscript: "__html" as NSString)
        context.setObject(url, forKeyedSubscript: "__url" as NSString)
        let script = """
        (function(){
          const number = s => { if (s == null) return NaN; const m = String(s).replace(/[\\u00a0\\s]/g, '').match(/-?\\d[\\d,]*(?:\\.\\d+)?/); return m ? parseFloat(m[0].replace(/,/g, '')) : NaN; };
          const json = (() => { const t = (__html || __text).trim(); if (!/^[\\[{]/.test(t)) return null; try { return JSON.parse(t); } catch (e) { return null; } })();
          const r = (function(text, html, url, json, number){ "use strict";
        \(check)
          })(__text, __html, __url, json, number);
          if (r == null) return null;
          return JSON.stringify({ value: r.value == null ? null : String(r.value), holds: r.holds });
        })()
        """
        let result = context.evaluateScript(script)
        if let thrown { return .miss(thrown.contains("JavaScript execution terminated") ? "the check ran too long" : thrown) }
        guard let result, !result.isNull, !result.isUndefined else { return .miss("the check found nothing on the page") }
        guard let data = result.toString()?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .miss("the check returned no { value, holds }") }
        guard let holds = object["holds"] as? Bool else { return .miss("the check returned no holds: true or false") }
        let value = (object["value"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) } ?? ""
        guard !value.isEmpty else { return .miss("the check returned no value") }
        return holds ? .holds(value) : .not(value)
    }
}

@MainActor
final class PageWatches: ObservableObject {
    static let shared = PageWatches()

    /// Bumped when what a row or a menu shows changes, not at every read.
    @Published private(set) var revision = 0
    private(set) var all: [PageWatch] = []
    /// What each hit said, for the bench: the notification's words.
    private(set) var told: [[String: String]] = []
    private var reading: Set<String> = []
    private var timer: Timer?
    private var file: URL { Store.file("page-watches.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder.withDates.decode([PageWatch].self, from: data) { all = read }
    }

    private func save(shown: Bool = true) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.withDates.encode(all).write(to: file, options: .atomic)
        if shown { revision += 1 }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { PageWatches.shared.tick() }
        }
    }

    /// The watch whose words a tab's row wears.
    func watch(for tab: Tab) -> PageWatch? {
        let key = PageWatchCheck.key(tab.address)
        let now = Date()
        return all.last { ($0.tab == tab.id || $0.url == key) && PageWatchCheck.words($0, now: now) != nil }
    }

    // MARK: - set, change, stop

    struct Trouble: Error { let said: String }

    /// A new watch, after its check read the page once: the watch, or that
    /// it holds already (no watch then), or why it can't be.
    func add(url: URL, name: String, until: String, check: String, tell: String?, tab: Tab?, space: UUID,
             every: Double, days: Double, done: @escaping (Result<(PageWatch, WatchRead), Trouble>) -> Void) {
        guard let key = PageWatchCheck.key(url) else { done(.failure(Trouble(said: "watch_page watches http(s) pages"))); return }
        let until = until.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !until.isEmpty else { done(.failure(Trouble(said: "say what to watch for in until: \"under $200\", \"in stock\""))); return }
        guard !check.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, check.count <= 8000 else {
            done(.failure(Trouble(said: "check is the body of a function of (text, html, url, json, number), up to 8000 characters"))); return
        }
        let least = Store.testing ? 1.0 : 5.0
        let now = Date()
        let watch = PageWatch(id: Routines.newID(key + until), url: key, name: String(name.prefix(80)), until: String(until.prefix(60)), check: check,
                              tell: tell, tab: tab?.id, space: space, every: min(max(every, least), 1440), started: now,
                              expires: now.addingTimeInterval(min(max(days, 1), 90) * 86_400))
        read(watch, tab: tab) { [weak self] read, page in
            guard let self else { return }
            switch read {
            case .miss(let why):
                done(.failure(Trouble(said: "\(why). Write the check again over what the page says; it reads: " + String(page.prefix(600)))))
            case .holds:
                done(.success((watch, read)))
            case .not(let value):
                var made = watch
                made.checked = Date()
                made.value = value
                // One watch a page and condition: asked again, the new one.
                self.all.removeAll { $0.url == key && $0.until.lowercased() == until.lowercased() && $0.active }
                self.all.append(made)
                self.save()
                self.start()
                done(.success((made, read)))
            }
        }
    }

    /// Its check written again (after a wake), tried on the page first.
    func rewrite(_ id: String, check: String, tell: String?, done: @escaping (Result<(PageWatch, WatchRead), Trouble>) -> Void) {
        guard let watch = all.first(where: { $0.id == id && $0.active }) else { done(.failure(Trouble(said: "no watch \(id)"))); return }
        var trial = watch
        trial.check = check
        if let tell { trial.tell = tell }
        read(trial, tab: nil) { [weak self] read, page in
            guard let self else { return }
            if case .miss(let why) = read { done(.failure(Trouble(said: "\(why). The page reads: " + String(page.prefix(600))))); return }
            guard let index = self.all.firstIndex(where: { $0.id == id }) else { done(.failure(Trouble(said: "no watch \(id)"))); return }
            self.all[index].check = check
            self.all[index].tell = trial.tell
            self.all[index].misses = 0
            self.all[index].trouble = nil
            self.all[index].woke = nil
            self.settle(index, read)
            done(.success((self.all.first { $0.id == id } ?? trial, read)))
        }
    }

    /// Ended by the user or the agent; nothing is said.
    @discardableResult
    func stop(_ id: String) -> PageWatch? {
        guard let index = all.firstIndex(where: { $0.id == id || id.count >= 3 && $0.id.hasPrefix(id) }) else { return nil }
        let gone = all.remove(at: index)
        save()
        return gone
    }

    // MARK: - reading

    /// Every watch owed a read (all of them with `force`), each once at a
    /// time; `done` when they are all read.
    func tick(force: Bool = false, done: (() -> Void)? = nil) {
        let now = Date()
        // Over on their own: past their days, or a held one's day on its row.
        let before = all.count
        all.removeAll { $0.active ? now >= $0.expires : now.timeIntervalSince($0.held ?? now) >= PageWatchCheck.shownFor }
        if all.count != before { save() }
        let owed = all.filter { $0.active && !reading.contains($0.id) && (force || PageWatchCheck.due($0, now: now)) }
        guard !owed.isEmpty else { done?(); return }
        let group = DispatchGroup()
        for watch in owed {
            reading.insert(watch.id)
            group.enter()
            read(watch, tab: nil) { [weak self] read, _ in
                defer { group.leave() }
                guard let self else { return }
                self.reading.remove(watch.id)
                guard let index = self.all.firstIndex(where: { $0.id == watch.id && $0.active }) else { return }
                self.settle(index, read)
            }
        }
        group.notify(queue: .main) { done?() }
    }

    /// What a read means for the watch: a hit tells and ends it, a miss
    /// counts toward a wake.
    private func settle(_ index: Int, _ read: WatchRead) {
        all[index].checked = Date()
        switch read {
        case .not(let value):
            let shown = all[index].misses > 0
            all[index].value = value
            all[index].misses = 0
            all[index].trouble = nil
            save(shown: shown)
        case .holds(let value):
            all[index].value = value
            all[index].held = Date()
            let said = PageWatchCheck.sentence(all[index], value: value)
            all[index].said = said
            save()
            tell(all[index], said)
        case .miss(let why):
            all[index].misses += 1
            all[index].trouble = why
            let wakes = PageWatchCheck.wakes(all[index])
            if wakes { all[index].woke = true }
            save(shown: false)
            if wakes { wake(all[index]) }
        }
    }

    /// The page as the check sees it: fetched with the space's sign-ins;
    /// an open tab of it as drawn when the fetch doesn't show the thing.
    private func read(_ watch: PageWatch, tab: Tab?, done: @escaping (WatchRead, String) -> Void) {
        guard let url = URL(string: watch.url) else { done(.miss("no address"), ""); return }
        let check = watch.check
        let open = tab.flatMap { $0.asleep ? nil : $0 } ?? openTab(watch)
        AgentRead.run(url, method: "GET", body: nil, type: nil, keepHTML: true, store: Spaces.store(for: watch.space ?? Spaces.current)) { got in
            DispatchQueue.main.async {
                let status = got["status"] as? Int ?? 0
                let body = got["text"] as? String ?? ""
                let html = (got["type"] as? String ?? "").contains("html") ? body : ""
                Task.detached(priority: .utility) {
                    let text = html.isEmpty ? body : AgentRead.plain(html)
                    let fetched = (200..<300).contains(status) ? PageWatchCheck.run(check, text: text, html: html, url: watch.url)
                        : .miss(got["error"] as? String ?? "the page answered \(status)")
                    await MainActor.run {
                        guard case .miss = fetched, let open else { done(fetched, text); return }
                        self.live(open) { page in
                            guard let page else { done(fetched, text); return }
                            Task.detached(priority: .utility) {
                                let drawn = PageWatchCheck.run(check, text: page.text, html: page.html, url: watch.url)
                                await MainActor.run { done(drawn, page.text) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// An open, awake tab of the page, the one it was set on first.
    private func openTab(_ watch: PageWatch) -> Tab? {
        let tabs = BrowserWindows.shared.browsers.flatMap(\.tabs).filter { !$0.asleep }
        return tabs.first { $0.id == watch.tab } ?? tabs.first { PageWatchCheck.key($0.address) == watch.url }
    }

    private func live(_ tab: Tab, done: @escaping @MainActor ((text: String, html: String)?) -> Void) {
        let body = "return { text: document.body ? document.body.innerText : '', html: document.documentElement.outerHTML.slice(0, 2000000) };"
        AgentPage.run(tab, body) { result in
            guard case .success(let value) = result, let page = value as? [String: Any] else { done(nil); return }
            done((page["text"] as? String ?? "", page["html"] as? String ?? ""))
        }
    }

    // MARK: - saying so

    private func tell(_ watch: PageWatch, _ said: String) {
        told.append(["watch": watch.id, "title": watch.name, "body": said, "url": watch.url])
        AgentNotices.shared.browser = Agents.shared.browser
        AgentNotices.shared.post(watch: watch.id, url: watch.url, title: watch.name, body: said)
    }

    /// A check that stopped reading the page: an agent writes it again,
    /// once, and says nothing to the user unless the page is gone.
    private func wake(_ watch: PageWatch) {
        guard Agents.installed, AIUse.allows(.background, space: watch.space) else { return }
        let choice = ModelDefaults.shared.pick(.tasks)
        let prompt = """
        Yab watches \(watch.url) for the user (\(watch.name): \(watch.until)) with a check you wrote, and the check \
        has stopped reading the page: \(watch.trouble ?? "it found nothing"). Open the page, see where the thing is \
        now, and call `watch_page` with watch "\(watch.id)" and a new check (the body of a function of text, html, \
        url, json, number that returns { value, holds }). The check was:
        \(watch.check)
        Don't tell the user anything unless the page is gone; then stop the watch (`watch_page` with stop "\(watch.id)") \
        and say so in one line.
        """
        _ = Agents.shared.run(prompt: prompt, cli: choice.cli, model: choice.model, effort: choice.effort, access: "browser",
                              quiet: true, name: "Watch: \(watch.name)", resume: nil)
    }

    /// For the bench and the agent's list.
    func describe(_ watch: PageWatch) -> [String: Any] {
        let stamp = ISO8601DateFormatter()
        return ["watch": watch.id, "url": watch.url, "name": watch.name, "until": watch.until, "every": watch.every,
                "value": watch.value ?? "", "misses": watch.misses, "trouble": watch.trouble ?? "", "woke": watch.woke == true,
                "active": watch.active, "said": watch.said ?? "", "tab": watch.tab?.uuidString ?? "",
                "checked": watch.checked.map { stamp.string(from: $0) } ?? "", "expires": stamp.string(from: watch.expires),
                "words": PageWatchCheck.words(watch, now: Date())?.text ?? ""]
    }

    var toldSoFar: [[String: String]] { told }
}

private extension JSONEncoder {
    static var withDates: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}

private extension JSONDecoder {
    static var withDates: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}

/// At the end of a watched page's row: "Watching: under $200", faint; once
/// it held, what it found, in ink, for a day. Words, no ring or dot. A tab
/// across the top, with room for little more than its name, says only
/// "Watching" (`short`).
struct WatchWords: View {
    @ObservedObject var tab: Tab
    var short = false
    @ObservedObject private var watches = PageWatches.shared
    @Environment(\.tone) private var tone

    var body: some View {
        if let watch = watches.watch(for: tab), let words = PageWatchCheck.words(watch, now: Date(), short: short) {
            Text(words.text)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(words.loud ? Palette.ink : Palette.faint(on: tone))
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(words.text)
        }
    }
}

// MARK: - the agent's verbs (AgentBench)

extension Bench {
    static let watchVerbs: [String: AgentHandler] = [
        "agent-watch-page": { $0.handleAgentWatchPage($1) },
        "agent-watch-pages": { $0.handleAgentWatchPages($1) },
        "agent-watch-page-tick": { $0.handleAgentWatchPageTick($1) },
    ]

    /// watch_page: set one, write its check again, stop one, or list them.
    func handleAgentWatchPage(_ c: AgentCall) {
        let request = c.request
        let answer = c.answer
        let watches = PageWatches.shared
        func string(_ key: String) -> String { (request[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func reply(_ result: Result<(PageWatch, WatchRead), PageWatches.Trouble>) {
            switch result {
            case .failure(let trouble): answer(["error": trouble.said])
            case .success(let (watch, read)):
                var out = watches.describe(watch)
                if case .holds(let value) = read {
                    out["holds"] = true
                    out["said"] = PageWatchCheck.sentence(watch, value: value)
                }
                out["value"] = read.value ?? ""
                answer(out)
            }
        }
        if !string("stop").isEmpty {
            let id = string("stop")
            if id == "all" {
                let gone = watches.all.filter(\.active)
                gone.forEach { watches.stop($0.id) }
                answer(["stopped": gone.map(\.name)])
            } else if let gone = watches.stop(id) {
                answer(["stopped": [gone.name]])
            } else {
                answer(["error": "no watch \(id)"])
            }
            return
        }
        if !string("watch").isEmpty {
            guard !string("check").isEmpty else { answer(["error": "a watch's new check goes in check"]); return }
            c.agents.touch(c.session, "watch · \(string("watch"))")
            watches.rewrite(string("watch"), check: string("check"), tell: request["tell"] as? String, done: reply)
            return
        }
        let tab = find(request, in: c.browser)
        guard let url = tab?.address ?? URL(string: string("url")), PageWatchCheck.key(url) != nil else {
            if string("id").isEmpty && string("url").isEmpty {
                answer(["watches": watches.all.filter(\.active).map { watches.describe($0) }])
            } else {
                let none: [String: Any] = ["error": "watch_page watches an http(s) page: give its tab or url"]
                answer(tab == nil && !string("id").isEmpty ? missing(request) : none)
            }
            return
        }
        let name = string("name").isEmpty ? (tab?.label ?? url.host() ?? url.absoluteString) : string("name")
        c.agents.touch(c.session, "watch · \(url.host() ?? "")")
        watches.add(url: url, name: name, until: string("until"), check: request["check"] as? String ?? "", tell: request["tell"] as? String,
                    tab: tab, space: c.browser.spaceID, every: request["every"] as? Double ?? 30, days: request["days"] as? Double ?? 30, done: reply)
    }

    /// Every watch, ended ones too, and what each hit said.
    func handleAgentWatchPages(_ c: AgentCall) {
        let watches = PageWatches.shared
        var out: [String: Any] = ["watches": watches.all.map { watches.describe($0) }, "told": watches.toldSoFar]
        if let id = (c.request["id"] as? String).flatMap({ $0.isEmpty ? nil : $0 }), let tab = find(c.request, in: c.browser) {
            out["tab"] = id
            out["words"] = watches.watch(for: tab).flatMap { PageWatchCheck.words($0, now: Date())?.text } ?? ""
        }
        c.answer(out)
    }

    /// Every watch read now, as the clock would when they are due: a
    /// --test run only. Answers once they are all read.
    func handleAgentWatchPageTick(_ c: AgentCall) {
        guard Store.testing else { c.answer(["error": "agent-watch-page-tick only works on a --test run"]); return }
        PageWatches.shared.tick(force: true) {
            let watches = PageWatches.shared
            c.answer(["watches": watches.all.map { watches.describe($0) }, "told": watches.toldSoFar])
        }
    }
}
