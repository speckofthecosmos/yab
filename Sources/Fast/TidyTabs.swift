import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// Tidy, beside Clear on the line under the kept tabs (feedback #313), as
// Arc Max's Tidy Tabs, available at five loose Today tabs (chosen Oct 23).
// Arc 1.170's reference (a recording of Arc's Tidy, 2026-10-20) shows a broom and "Tidy" left of Clear, as faint, with the tip
// "Organize Today Tabs". Pressed, both
// words go and the line turns to a small travelling wave while the model
// thinks (3.2 s there); then Today is sorted under named groups ("Travel
// Planning", "Baking"), the tabs that fit none left after them, and the
// wave lies flat again. ⌘Z puts the row back as it was.
//
// Here the groups are folders among today's (Nest.fleeting), the same
// kind two of today's tabs held over each other make: they go when today's
// go, and a folder down to one tab goes by itself. The model is the cheap
// one of the AI you connected (Claude's Haiku kept warm, Codex's), else
// Apple Intelligence on this Mac; with none of them Tidy isn't shown, as
// Arc's isn't without Arc Max. No agent tab, no tools: titles in, names and
// numbers out.

extension Browser {
    /// How many of today's loose tabs show Tidy: five, chosen
    /// on Oct 23, independently of Arc's unverified boundary.
    nonisolated static let tidyTabsFrom = 5

    /// Today's tabs Tidy may sort: loose ones of yours, not in a folder or a
    /// split, not a task's.
    var tidyTabsLoose: [Tab] {
        tabs.filter { tab in
            tab.pin == nil && !tab.kept && tab.nest == nil && !tab.shy && !tab.bench && (tab.pending ?? tab.address) != nil
                && tab.agent == nil && tab.worker == nil
                // One in from another space with you is not this row's: AgentFolders.settle
                // counts only the row's own tabs, so a folder holding it and one other
                // looked "alone" and was dissolved quietly a moment after Tidy made it.
                && tab.homeSpace == nil
                && pair(of: tab.id) == nil && !dusting.contains(tab.id)
        }
    }

    /// Whether Tidy stands on the line now.
    var canTidyTabs: Bool {
        // Not in a space hidden from AI: its titles would go to a model.
        // Tidy has its own switch, not AI in Yab's (FormModel.tidyReady).
        prefs.tidyTabs && !tabsTidying && dusting.isEmpty && tidyTabsLoose.count >= Browser.tidyTabsFrom && TidyTabs.can
            && !hidesFromAI(space: spaceID)
    }

    /// Tidy: today's tabs asked about, and put in folders by the answer.
    /// Nothing moves until it comes; with no answer the row stays as it is.
    func tidyTabs() {
        guard canTidyTabs else { return }
        let loose = tidyTabsLoose
        let lines = loose.map(TidyTabs.line)
        tabsTidying = true
        TidyTabs.lastAsked = Date()
        Task { @MainActor [weak self] in
            let groups = await TidyTabs.groups(lines)
            guard let self else { return }
            TidyTabs.lastMs = Int(Date().timeIntervalSince(TidyTabs.lastAsked ?? Date()) * 1000)
            tabsTidying = false
            guard prefs.tidyTabs else { return }
            if let groups { applyTidy(groups, of: loose) }
        }
    }

    /// The answer laid out: each group a folder of today's, at the head of
    /// today's in the order its first tab stood, the rest after them as
    /// they were. One step for ⌘Z.
    func applyTidy(_ groups: [TidyTabs.Group], of loose: [Tab]) {
        // The model may answer after tabs were paired, moved between
        // spaces, or taken by a task. Recheck the same eligibility used
        // when asking: settle counts only this space's own tabs and would
        // dissolve a group that is left with one own member.
        let free = Set(tidyTabsLoose.map(\.id))
        var used = Set<Tab.ID>()
        var made: [(nest: Nest, tabs: [Tab])] = []
        for group in groups {
            let members = group.tabs.compactMap { $0 >= 0 && $0 < loose.count ? loose[$0] : nil }
                .filter { free.contains($0.id) && !used.contains($0.id) }
            guard members.count >= 2 else { continue }
            members.forEach { used.insert($0.id) }
            let nest = Nest(name: group.name)
            nest.fleeting = true
            nest.born = Date()
            // In the row's order within each folder.
            made.append((nest, tabs.filter { tab in members.contains { $0 === tab } }))
        }
        guard !made.isEmpty else { return }
        let order = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        made.sort { (order[$0.tabs[0].id] ?? 0) < (order[$1.tabs[0].id] ?? 0) }
        let before = RowShape(self)
        ColumnMotion.next(.folder)
        for (nest, members) in made { members.forEach { $0.nest = nest } }
        let pins = tabs.filter { $0.pin != nil }
        let kept = tabs.filter { $0.pin == nil && $0.kept }
        let rest = tabs.filter { $0.pin == nil && !$0.kept && !used.contains($0.id) }
        lay(pins + kept + made.flatMap(\.tabs) + rest)
        folderBook.refresh()
        writeSession(now: true)
        did { [weak self] in
            ColumnMotion.next(.folder)
            self?.put(before)
        }
    }
}

@MainActor
enum TidyTabs {
    /// One group of the answer: its name and its tabs, by their place in
    /// the list asked about (0 first).
    struct Group: Equatable {
        let name: String
        let tabs: [Int]
    }

    /// For the bench: when the last Tidy asked, and how long the answer took.
    static var lastAsked: Date?
    static var lastMs: Int?
    /// For the bench: what the model said last, and who said it.
    static var lastSaid = ""
    static var lastBy = ""

    /// Whether anything can answer: an AI you connected, or this Mac's.
    static var can: Bool {
        if stand != nil { return true }
        return available(stand: false, agents: agents, apple: FormModel.tidyReady)
    }

    static func available(stand: Bool, agents: [String], apple: Bool) -> Bool {
        stand || !agents.isEmpty || apple
    }

    static var agents: [String] { connectedProviders(in: AgentSetupModel.shared) }

    static func connectedProviders(in setup: AgentSetupModel) -> [String] {
        // A connection made in Yab survives the general AI consent switch.
        // A CLI merely installed on the Mac is not a connected model.
        let connected = ["claude", "codex"].filter { cli in
            setup.connected(cli) || (cli == "claude" ? setup.status.claude : setup.status.codex)
                || setup.signedIn[cli] == true
        }
        return LinkFolders.order(preferred: Agents.preferred, connected: connected)
    }

    /// A --test run's stand-in for the answer, its JSON with tabs counted
    /// from 0: given by the bench with the press, or YAB_TIDY_ANSWER.
    static var stand: String? {
        guard Store.testing else { return nil }
        return benchAnswer ?? ProcessInfo.processInfo.environment["YAB_TIDY_ANSWER"].flatMap { $0.isEmpty ? nil : $0 }
    }
    static var benchAnswer: String?

    /// A tab as the model reads it: its title and its site.
    static func line(_ tab: Tab) -> String {
        let host = (tab.pending ?? tab.address)?.host().map(LinkFolders.site) ?? ""
        let title = host.isEmpty ? tab.title : MarkdownLink.title(tab.title, host: host)
        return (title.isEmpty ? host : title) + (host.isEmpty ? "" : " (\(host))")
    }

    nonisolated static let instructions = """
    Sort the user's open browser tabs into a few groups by what they are about, as Arc's Tidy Tabs does. \
    Give each group a short, specific name of one to three words in Title Case, in the titles' own language, \
    such as "Travel Planning", "Baking" or "Rust Docs". No site names unless the site is the subject. \
    A group has at least two tabs; leave a tab out when it fits no group. At most six groups. \
    Reply with JSON only, nothing else: {"groups":[{"name":"Travel Planning","tabs":[1,2,3]}]} \
    where the numbers are the tabs' numbers in the list.
    """

    static let sorter = WarmClaude(room: "agent/tidy-tabs", idle: 600, turns: 30,
                                   env: ["MAX_THINKING_TOKENS": "0"], tidy: true) {
        ["--model", "haiku", "--settings", #"{"alwaysThinkingEnabled":false}"#, "--append-system-prompt", instructions
            + "\nEach message is a new list of tabs, unrelated to the ones before."]
    }

    /// Tidy warms its own text-only worker under its own switch.
    static func warm() {
        guard Store.settings.object(forKey: "tidy.tabs") as? Bool ?? true,
              stand == nil, agents.first == "claude" else { return }
        sorter.warm()
    }

    private static func providerAnswer(_ prompt: String, count: Int) async -> (text: String, cli: String?) {
        for cli in agents {
            let said: String
            if cli == "claude" { said = await sorter.ask(prompt, within: 30) ?? "" }
            else { said = await PlanText.tidy(prompt, system: instructions, only: cli).text }
            if answer(said, count: count) != nil { return (said, cli) }
        }
        return ("", nil)
    }

    /// The groups for these tabs, or nil when nothing answered or the
    /// answer made no group.
    static func groups(_ lines: [String]) async -> [Group]? {
        await groups(lines, writer: { await providerAnswer($0, count: lines.count) }, localModel: model)
    }

    /// The production dispatch path, with model boundaries injectable for tests.
    static func groups(_ lines: [String],
                       writer: (String) async -> (text: String, cli: String?),
                       localModel: (String) async -> String?) async -> [Group]? {
        guard Store.settings.object(forKey: "tidy.tabs") as? Bool ?? true else { return nil }
        let list = lines.prefix(60).enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let prompt = "Tabs:\n" + list
        if let stand {
            // After about Arc's time for one, to see the wave.
            try? await Task.sleep(for: .milliseconds(1200))
            return answer(stand, count: lines.count, from: 0)
        }
        let written = await writer(prompt)
        lastSaid = written.text
        lastBy = written.cli ?? ""
        guard Store.settings.object(forKey: "tidy.tabs") as? Bool ?? true else { return nil }
        if let groups = answer(written.text, count: lines.count) { return groups }
        if let said = await localModel(prompt) {
            lastSaid = said
            lastBy = "mac"
            return answer(said, count: lines.count)
        }
        return nil
    }

    /// The model's JSON read: names that fit (LinkFolders.fits), tabs by
    /// their number (`from` 1 as asked, 0 for the stand-in), each tab in
    /// one group only, two or more a group.
    nonisolated static func answer(_ said: String, count: Int, from: Int = 1) -> [Group]? {
        guard let start = said.firstIndex(of: "{"), let end = said.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(said[start...end].utf8)) as? [String: Any],
              let list = object["groups"] as? [[String: Any]] else { return nil }
        var seen = Set<Int>()
        var out: [Group] = []
        for item in list.prefix(8) {
            let name = (item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.")))
            guard LinkFolders.fits(name) else { continue }
            let numbers = (item["tabs"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }
            var tabs: [Int] = []
            for n in numbers {
                let (i, overflow) = n.subtractingReportingOverflow(from)
                if !overflow, i >= 0, i < count, !seen.contains(i), !tabs.contains(i) { tabs.append(i) }
            }
            guard tabs.count >= 2 else { continue }
            seen.formUnion(tabs)
            out.append(Group(name: name, tabs: tabs))
        }
        return out.isEmpty ? nil : out
    }

    nonisolated static func model(_ prompt: String) async -> String? {
        guard Store.settings.object(forKey: "tidy.tabs") as? Bool ?? true, FormModel.tidyReady else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            guard let plan = try? await session.respond(to: prompt, generating: TidyPlan.self, options: GenerationOptions(sampling: .greedy)) else { return nil }
            let groups = plan.content.groups.map { ["name": $0.name, "tabs": $0.tabs] as [String: Any] }
            guard let data = try? JSONSerialization.data(withJSONObject: ["groups": groups]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct TidyPlan {
    @Guide(description: "A few groups of tabs that belong together, at most six")
    var groups: [TidyPlanGroup]
}

@available(macOS 26, *)
@Generable
struct TidyPlanGroup {
    @Guide(description: "One to three words in Title Case naming what the tabs are about together")
    var name: String
    @Guide(description: "The numbers of the tabs in this group, as numbered in the list, at least two")
    var tabs: [Int]
}
#endif

/// The kept line while Tidy waits for its answer: a small wave running
/// along it, as Arc's does, lying flat again once the answer is in.
struct TidyWave: View {
    var on: Bool
    @State private var lift: CGFloat = 0
    @State private var waving = false

    var body: some View {
        Group {
            if waving {
                TimelineView(.animation) { context in
                    WaveLine(phase: context.date.timeIntervalSinceReferenceDate, lift: lift)
                        .stroke(Palette.ink.opacity(0.14), lineWidth: 1)
                }
            } else {
                Rectangle()
                    .fill(Palette.ink.opacity(0.08))
                    .frame(height: 1)
            }
        }
        .frame(height: 6)
        .onChange(of: on, initial: true) { _, on in
            if on {
                waving = true
                withAnimation(.easeOut(duration: 0.25)) { lift = 1.5 }
            } else if waving {
                withAnimation(.easeInOut(duration: 0.35)) { lift = 0 } completion: { if lift == 0 { waving = false } }
            }
        }
    }
}

/// A sine along the middle of its frame, `lift` high, moving with `phase`.
struct WaveLine: Shape {
    var phase: Double
    var lift: CGFloat

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Arc's: about six points a wave, travelling about 24 a second.
        let length: CGFloat = 6
        let shift = CGFloat(phase * 24).truncatingRemainder(dividingBy: length)
        var x: CGFloat = 0
        while x <= rect.width {
            let y = rect.midY + lift * sin((x + shift) / length * 2 * .pi)
            if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            x += 0.5
        }
        return path
    }
}
