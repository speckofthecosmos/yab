import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// The name of a folder a ⌘-click made (Research.gatherLinks), as Dia names
// its auto groups (docs/link-folders.md). The row shows a gray bar where the
// name goes until a model has said in two to four words what the page and
// its link are about; the name then shimmers in once. The model is the
// cheap one of the AI you connected in Yab (Claude's Haiku, Codex's fast
// and affordable one at low effort), yours first; Apple Intelligence on
// the Mac only when none is connected or none answers (the user's call,
// 2026-10-16). It is named once: tabs joining later keep it, as Dia keeps
// its name. A name you type, before or after, is never written over. With
// nothing to ask, or nothing that answers, it is "Folder 1", "Folder 2", as
// Dia's are when it has no name to give.
//
// Its mark is the site's icon while its pages are of one site; of more,
// with Settings › Tabs' "Add emoji to new folders" on, an emoji the same
// answer gives before the name, else the folder's own mark, as Dia's
// groups wear them (measured 2026-10-20, docs/link-folders.md).

@MainActor
enum LinkFolders {
    /// Names already given, by the titles they were given for, kept so the
    /// same tabs make the same name without asking again.
    private static var known: [String: String] = (try? Data(contentsOf: file))
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    private static var file: URL { Store.file("link-folder-names.json") }

    /// How long a link's title is waited for before asking with what there is.
    static let titleWait: Duration = .seconds(2)

    /// Made: the next free "Folder N" at once, the bar over it while the
    /// model is asked, the model's name in its place once it answers.
    static func name(_ nest: Nest, in browser: Browser) {
        nest.name = fallback(among: browser)
        // Settings › AI › While You Browse › Folder Names off: Folder N.
        guard browser.prefs.folderNames, AIUse.allows(.background, space: browser.spaceID) else { return }
        guard stand != nil || !agents.isEmpty || FormModel.ready else { return }
        Rename.warm()
        nest.unnamed = true
        let given = nest.name
        Task { @MainActor [weak browser, weak nest] in
            // The link's title comes with its page: waited for a moment.
            var waited: Duration = .zero
            while waited < titleWait, let browser, let nest, titles(nest, in: browser).count < 2 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += .milliseconds(200)
            }
            guard let browser, let nest else { return }
            let titles = titles(nest, in: browser)
            // An emoji too for pages of more than one site, in the same answer.
            let emoji = browser.prefs.folderEmoji && !oneSite(nest, in: browser)
            let key = (emoji ? "emoji\u{1}" : "") + titles.joined(separator: "\u{1}")
            var said = known[key].map(split)
            if said == nil, let stand {
                // A --test run on a Mac without the model: its answer
                // stood in, after Dia's time for one, to see the bar and
                // the shimmer (evals/cmd-click-folders).
                try? await Task.sleep(for: .milliseconds(900))
                said = split(stand)
            } else if said == nil, titles.count > 1 {
                for cli in agents {
                    if let answer = await agent(cli, titles, emoji: emoji).map(split), fits(answer.name) { said = answer; break }
                }
                if said == nil, let answer = await model(titles, emoji: emoji).map(split), fits(answer.name) { said = answer }
                if let said { remember(key, (said.emoji.map { $0 + " " } ?? "") + said.name) }
            }
            // Typed over meanwhile, or gone: left as it is.
            guard nest.unnamed, nest.name == given else { return }
            guard browser.prefs.folderNames, browser.nests.contains(where: { $0 === nest }) else {
                nest.unnamed = false
                return
            }
            // The gray bar to dust first, while the row still shows it; the
            // name comes in behind it, as every name Yab gives (Rename.swift).
            let dusted = said != nil && Rename.dust(folder: nest.key, in: browser)
            nest.unnamed = false
            if let said {
                if dusted { nest.renamed = Date() }
                nest.name = said.name
                // Its emoji, unless a mark was picked for it meanwhile.
                if emoji, let mark = said.emoji, nest.customMark == nil { nest.customMark = mark }
                nest.named = Date()
                browser.writeSession()
            }
        }
    }

    /// An answer's leading emoji, if it has one, and the name after it.
    nonisolated static func split(_ said: String) -> (emoji: String?, name: String) {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, isEmoji(first) else { return (nil, text) }
        let name = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.-–:")))
        return (String(first), name)
    }

    nonisolated static func isEmoji(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }

    /// What a ⌘-click folder wears: its first tab's site icon while its
    /// tabs are of one site, the emoji its name came with (`emoji`), or
    /// nil, the folder's own mark (none given, or one picked that isn't an
    /// emoji, which CustomMarks draws).
    static func mark(_ nest: Nest, in browser: Browser) -> (tab: Tab, emoji: NSImage?)? {
        guard nest.linked, let first = browser.tabs.first(where: { $0.nest === nest }) else { return nil }
        if let mark = nest.customMark {
            guard mark.count == 1, let c = mark.first, isEmoji(c), let image = CustomMarks.image(mark) else { return nil }
            return (first, image)
        }
        return oneSite(nest, in: browser) ? (first, nil) : nil
    }

    /// Its tabs all of one site (www. aside): the mark is that site's icon.
    static func oneSite(_ nest: Nest, in browser: Browser) -> Bool {
        let hosts = Set(browser.tabs.filter { $0.nest === nest }.compactMap { ($0.pending ?? $0.address)?.host() }.map(site))
        return hosts.count <= 1
    }

    nonisolated static func site(_ host: String) -> String {
        host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)).lowercased() : host.lowercased()
    }

    /// A --test run's stand-in for the model's answer (YAB_FOLDER_NAME).
    private static var stand: String? {
        Store.testing ? ProcessInfo.processInfo.environment["YAB_FOLDER_NAME"].flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// The AI you connected that names folders, yours first, then the
    /// other. A test run asks none, unless it names them
    /// (YAB_FOLDER_AGENTS=claude,codex: the eval's real name on a Mac whose
    /// plans are signed in, without Connect writing that Mac's config).
    static var agents: [String] {
        guard Store.testing else {
            return order(preferred: Agents.preferred, connected: ["claude", "codex"].filter(AgentSetup.connected))
        }
        return (ProcessInfo.processInfo.environment["YAB_FOLDER_AGENTS"] ?? "").split(separator: ",").map(String.init)
            .filter(["claude", "codex"].contains)
    }

    nonisolated static func order(preferred: String, connected: [String]) -> [String] {
        connected.filter { $0 == preferred } + connected.filter { $0 != preferred }
    }

    /// Codex's cheap model: the one it calls fast and affordable, else
    /// whatever Codex runs by default.
    static var codexModel: String? {
        AgentModels.codex().first { $0.about.lowercased().contains("affordable") }?.model
    }

    /// Claude's Haiku, kept running while a ⌘-click folder could be made
    /// (warm), and never thinking: the name landed 8 s after the click on
    /// adhd, Claude Code's start about 1 s of it and Haiku thinking (on
    /// with the Mac's own Claude settings) the rest. Measured there
    /// (evals/cmd-click-folders/warm_timing.py): an ask 2.1-4.3 s warm
    /// with thinking, 0.7 s without; a start and its first ask 1.6 s.
    /// It goes after ten minutes without a page, and is started afresh
    /// every 40 names so the turns don't pile up.
    static let namer = WarmClaude(room: "agent/folder-names", idle: 600, turns: 40, env: ["MAX_THINKING_TOKENS": "0"]) {
        ["--model", "haiku", "--settings", #"{"alwaysThinkingEnabled":false}"#, "--append-system-prompt", instructions
            + "\nEach message is a new group of tabs, unrelated to the ones before. Reply with the name and nothing else, "
            + "with one emoji before it only when the message asks for one."]
    }

    /// A page came in front with the switch on: Haiku started now, so the
    /// ⌘-click it may get doesn't wait out Claude Code's start. Only when
    /// Claude is the AI asked first, for a tab of yours.
    static func warm(_ tab: Tab, in browser: Browser) {
        guard browser.prefs.linkFolders, browser.prefs.folderNames, AIUse.allows(.background), tab.id == browser.activeID, tab.agent == nil, !tab.shy, !tab.bench,
              stand == nil, agents.first == "claude" else { return }
        namer.warm()
    }

    /// A name from the connected agent's cheap model, with no tools: Claude
    /// kept warm (namer), Codex run once as PostWriter runs it; nil when it
    /// fails or takes too long.
    static func agent(_ cli: String, _ titles: [String], emoji: Bool = false) async -> String? {
        let list = titles.prefix(12).map { "- " + $0 }.joined(separator: "\n") + (emoji ? "\n\n" + emojiAsk : "")
        var said = ""
        if cli == "claude" {
            said = await namer.ask("Tabs:\n" + list, within: 30) ?? ""
        } else if cli == "codex" {
            guard let permit = ProviderConsent.shared.permit("codex") else { return nil }
            let found = await AgentLaunch.environment()
            guard permit.valid, let launch = AgentLaunch.resolve(cli, in: found) else { return nil }
            let codex = launch.binary
            let prompt = instructions + "\n\nTabs:\n" + list + (emoji ? "\n\nReply with the emoji and the name and nothing else." : "\n\nReply with the name and nothing else.")
            let room = Store.file("agent/folder-names")
            try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
            let env = launch.env
            let out = room.appendingPathComponent("name-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: out) }
            // No tools: a page's title can say anything (PlanText).
            let args = PlanText.codexArgs(prompt, out: out.path, model: codexModel, effort: "low")
            _ = await Shell.timed("/bin/bash", ["-c", "exec \"$0\" \"$@\" </dev/null", codex] + args, env: env, limit: 45, in: room, permit: permit)
            said = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        }
        let clean = said.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.")))
        return clean.isEmpty ? nil : clean
    }

    /// Asked with the tabs when the folder is to wear an emoji: one answer
    /// for both, the same call.
    nonisolated static let emojiAsk = "Start with one emoji that fits them, then a space, then the name."

    /// "Folder N", the lowest N no folder in the window has.
    static func fallback(among browser: Browser) -> String {
        let taken = Set(browser.nests.map(\.name))
        var n = 1
        while taken.contains("Folder \(n)") { n += 1 }
        return "Folder \(n)"
    }

    private static func titles(_ nest: Nest, in browser: Browser) -> [String] {
        browser.tabs.filter { $0.nest === nest }.compactMap { tab in
            let title = tab.address.flatMap { url in url.host().map { MarkdownLink.title(tab.title, host: $0) } } ?? tab.title
            return title.isEmpty || title == tab.address?.absoluteString ? nil : title
        }
    }

    private static func remember(_ key: String, _ name: String) {
        known[key] = name
        if known.count > 400 { known = Dictionary(uniqueKeysWithValues: known.suffix(300).map { ($0.key, $0.value) }) }
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// A model's answer that can stand as a folder's name: two to four
    /// words, short, not a sentence.
    nonisolated static func fits(_ said: String) -> Bool {
        let words = said.split(whereSeparator: \.isWhitespace)
        return (1...4).contains(words.count) && said.count <= 32 && !said.hasSuffix(".")
            && !said.contains("\n") && !said.lowercased().hasPrefix("tab group") && !said.lowercased().hasPrefix("folder")
    }

    /// Dia's own words to its model, for the same kind of name.
    nonisolated static let instructions = """
    Generate a short, specific name (2-4 words) for this group of browser tabs, opened one from another. \
    Say what they are about together, in the titles' own language. No quotes, no full stop, no site names \
    unless the site is the subject.
    Examples: "Sourdough", "Bread" is Sourdough & Bread. "Q4 roadmap draft", "Hiring plan for the platform team" is Q4 Planning.
    """

    nonisolated static func model(_ titles: [String], emoji: Bool = false) async -> String? {
        guard FormModel.ready else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "Tabs:\n" + titles.prefix(12).map { "- " + $0 }.joined(separator: "\n")
            let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))
            if emoji {
                let answer = try? await session.respond(to: prompt, generating: FolderNameEmoji.self, options: GenerationOptions(sampling: .greedy))
                guard let answer else { return nil }
                let mark = answer.content.emoji.trimmingCharacters(in: trim)
                let name = answer.content.name.trimmingCharacters(in: trim)
                return (mark.first.map(isEmoji) == true ? String(mark.first!) + " " : "") + name
            }
            let answer = try? await session.respond(to: prompt, generating: FolderName.self, options: GenerationOptions(sampling: .greedy))
            return answer?.content.name.trimmingCharacters(in: trim)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct FolderName {
    @Guide(description: "Two to four words naming what the tabs are about together")
    var name: String
}

@available(macOS 26, *)
@Generable
struct FolderNameEmoji {
    @Guide(description: "One emoji that fits what the tabs are about")
    var emoji: String
    @Guide(description: "Two to four words naming what the tabs are about together")
    var name: String
}
#endif
