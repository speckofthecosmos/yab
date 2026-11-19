import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Short names for kept tabs, as Arc Max's Tidy Tab Titles gives pinned
// tabs: the site's own name and a count come out of the title by rule
// (MarkdownLink.title, Diary.clean), and a title still long after that is
// said in a few words by the model on this Mac, asked once per address and
// title and kept (docs/live-folders.md, "The rest"). A name you give a tab
// (⌃⌘R) always wins, and the whole title stays in its card. The switch is
// Settings › AI › While You Browse › Tidy Tab Titles.

@MainActor
final class ShortNames: ObservableObject {
    static let shared = ShortNames()

    /// Past this, a title is asked to be said shorter.
    static let long = 28

    /// Settings › AI › While You Browse › Tidy Tab Titles (Preferences
    /// keeps it here as it changes).
    static var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            for browser in BrowserWindows.shared.browsers { for tab in browser.tabs where tab.kept { tab.objectWillChange.send() } }
        }
    }

    private var known: [String: String]
    private var asking: Set<String> = []
    private static var file: URL { Store.file("short-names.json") }

    private init() {
        known = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The file again, as sync wrote it from another Mac (SyncCenter).
    func reload() {
        known = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? known
    }

    /// What a kept tab's row says in place of its title, or nil for the
    /// title as it is. The rule's answer at once; the model's once it has
    /// one, the tab told so it draws again.
    func name(for tab: Tab) -> String? {
        guard Self.enabled, tab.kept, tab.name == nil, tab.live == nil, let url = tab.address, let host = url.host(), !tab.title.isEmpty else { return nil }
        let ruled = MarkdownLink.title(tab.title, host: host)
        guard ruled.count > Self.long else { return ruled == tab.title ? nil : ruled }
        let key = Self.key(url, ruled)
        if let said = known[key] { return said.isEmpty ? ruled : said }
        guard AIUse.allows(.background, for: tab) else { return ruled }
        ask(ruled, key: key, for: tab)
        return ruled
    }

    nonisolated static func key(_ url: URL, _ title: String) -> String { url.absoluteString + "\u{1}" + title }

    /// Whether a model's answer can stand for a title: shorter, a few words,
    /// not a sentence about it.
    nonisolated static func fits(_ said: String, for title: String) -> Bool {
        let words = said.split(separator: " ")
        return !said.isEmpty && said.count < title.count && said.count <= 32 && (1...5).contains(words.count)
            && !said.hasSuffix(".") && !said.lowercased().hasPrefix("the title")
    }

    private func ask(_ title: String, key: String, for tab: Tab) {
        guard !asking.contains(key), FormModel.ready else { return }
        asking.insert(key)
        Rename.warm()
        Task.detached(priority: .utility) { [weak tab] in
            let said = await ShortNames.model(title)
            await MainActor.run {
                ShortNames.shared.asking.remove(key)
                ShortNames.shared.landed(said.flatMap { ShortNames.fits($0, for: title) ? $0 : nil } ?? "", key: key, for: tab)
            }
        }
    }

    /// The model's name for a title (or "" for none), kept, and shown: a
    /// row drawn now has its old name go to dust first, while it still
    /// shows it, then the new one comes in behind (Rename.swift).
    private func landed(_ name: String, key: String, for tab: Tab?) {
        // An answer belongs to the address and title it was asked for. A
        // navigation, a hand-written name or switching the feature off
        // while it worked must not animate a different row.
        if !name.isEmpty, let tab, Self.enabled, tab.kept, tab.name == nil,
           let url = tab.address, let host = url.host(),
           Self.key(url, MarkdownLink.title(tab.title, host: host)) == key,
           let browser = BrowserWindows.shared.browsers.first(where: { $0.tabs.contains { $0 === tab } }),
           Rename.dust(tab: tab, in: browser) {
            tab.tidiedAt = Date()
        }
        known[key] = name
        if known.count > 800 { known = Dictionary(uniqueKeysWithValues: known.suffix(600).map { ($0.key, $0.value) }) }
        save()
        tab?.objectWillChange.send()
    }

    /// A test run's stand-in for the model (bench "tidy-name"): this name
    /// for the kept tab, by the same way an answer lands. False when the
    /// tab has no title to tidy.
    func stand(_ name: String, for tab: Tab) -> Bool {
        guard Store.testing, Self.enabled, tab.kept, tab.name == nil, let url = tab.address, let host = url.host(), !tab.title.isEmpty else { return false }
        Rename.warm()
        landed(name, key: Self.key(url, MarkdownLink.title(tab.title, host: host)), for: tab)
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    static let instructions = """
    A browser tab shows a web page's title. Say what the page is in two to four words, \
    as a person would name the tab: the thing itself, in the title's own language, no site name, \
    no quotes, no full stop.
    Examples: "How to Configure Nginx as a Reverse Proxy for Node.js Applications on Ubuntu 24.04" is Nginx reverse proxy. \
    "Q4 Planning: Roadmap, Hiring and Budget for the Platform Team (Draft)" is Q4 planning.
    """

    nonisolated static func model(_ title: String) async -> String? {
        guard FormModel.ready else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            let answer = try? await session.respond(to: "Title: \(title)", generating: Short.self, options: GenerationOptions(sampling: .greedy))
            return answer?.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        return nil
    }
}

/// A chat's name in the column's head, short enough to fit there: when
/// its name is only the first thing asked, cut (Chat.title, TaskLine.title),
/// the model on this Mac says it in two or three words, once. A name the
/// agent gives (the `name` tool) or a routine's stays as it is.
@MainActor
enum ChatTitles {
    /// Past this, a name is asked to be said shorter: it fits the head's glass.
    static let long = 22
    private static var asked: Set<String> = []

    static func shorten(_ chat: Chat) {
        let first = chat.items.first { $0.kind == .asked }?.text ?? chat.title
        let cut = [first, Chat.title(from: first), TaskLine.title(first)]
        guard chat.title.count > long, cut.contains(chat.title), !asked.contains(chat.id), FormModel.ready else { return }
        asked.insert(chat.id)
        let id = chat.id, was = chat.title
        Task.detached(priority: .utility) {
            guard let said = await ChatTitles.model(first), ChatTitles.fits(said, asked: first) else { return }
            await MainActor.run { ChatTitles.rename(id, from: was, to: said) }
        }
    }

    /// Unless something else named it meanwhile. A session with no title of
    /// its own (a chat begun in the column) is named too: the head reads
    /// the session's title first and watches only that (ChatFeed), so the
    /// list said the new name while the head kept the cut question.
    private static func rename(_ id: String, from was: String, to name: String) {
        if let session = Agents.shared.session(id), session.title == nil || session.title == was { session.title = name }
        if var kept = Chats.shared.chat(id), kept.title == was {
            kept.title = name
            Chats.shared.keep(kept)
        }
        Agents.shared.objectWillChange.send()
    }

    nonisolated static func fits(_ said: String, asked: String = "") -> Bool {
        let words = said.split(separator: " ")
        return !said.isEmpty && said.count <= 24 && (1...4).contains(words.count) && !said.hasSuffix(".")
            && sameScript(said, asked)
    }

    /// The small model, lost in slang, once named a question in one
    /// alphabet with a name in another: a name in another alphabet than the
    /// question is a guess, and the cut question stays.
    nonisolated static func sameScript(_ said: String, _ asked: String) -> Bool {
        func latin(_ text: String) -> Bool? {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !letters.isEmpty else { return nil }
            let count = letters.filter { $0.value < 0x0250 || (0x1E00...0x1EFF).contains($0.value) }.count
            return count * 2 > letters.count
        }
        guard let one = latin(said), let other = latin(asked) else { return true }
        return one == other
    }

    nonisolated static let instructions = """
    Someone asked an assistant something in a chat. Name the chat in two or three words, \
    at most 24 characters, as a person would title the conversation: its subject, in the \
    message's own language, no quotes, no full stop.
    Keep what tells this chat apart: a place, a person, a day.
    Examples: "What's on my calendar this afternoon?" is Afternoon calendar. \
    "Find me a cheap flight to Lisbon for next weekend, window seat" is Lisbon flight. \
    "Summarize this PR and tell me if it's safe to merge" is PR review. \
    "Reply to Anna's email about the venue" is Anna's venue email.
    """

    nonisolated static func model(_ asked: String) async -> String? {
        guard FormModel.ready else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            let answer = try? await session.respond(to: "Message: \(String(asked.prefix(400)))", generating: ShortChat.self, options: GenerationOptions(sampling: .greedy))
            return answer?.content.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct ShortChat {
    @Guide(description: "Two or three words naming the chat, at most 24 characters")
    var name: String
}
#endif

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct Short {
    @Guide(description: "Two to four words naming what the page is")
    var name: String
}
#endif
