import Foundation
import YabCoreClient

// Settings › Spaces › a space › Privacy: three choices of this Mac's,
// each on its own (Space.privacy).
//
// - Hide from AI: Yab records everything in the space for you, as in any
//   space (history, the day's threads, suggestions), and gives none of it
//   to an agent or a model. A private tab is hidden from AI too, but it
//   keeps nothing; here you keep it all, and only AI is kept out.
// - Don't Keep Day Threads: its visits are history, never threads.
// - Don't Keep History: nothing of where you went in it is written down,
//   as in a private tab. Its sign-ins, tabs, pins and bookmarks stay.
//
// Each rides one gate. A tab: Browser.whyHiddenFromAI and
// Browser.recording, which a private tab answers too. The diary: a
// Diary.Reader, which every read for AI passes. A model: AIUse.allows,
// given the tab or space it is about to use.

struct SpacePrivacy: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let hiddenFromAI = SpacePrivacy(rawValue: 1 << 0)
    static let noThreads = SpacePrivacy(rawValue: 1 << 1)
    static let noHistory = SpacePrivacy(rawValue: 1 << 2)

    /// Taken from the list as it is read or written (Spaces.read, write):
    /// the diary's queue and the agents' read it, not only the main thread.
    static func take(_ list: [Space]) {
        AIUse.hiddenSpaces = Set(list.filter { $0.has(.hiddenFromAI) }.map(\.id.uuidString))
    }
}

extension Space {
    func has(_ choice: SpacePrivacy) -> Bool { privacy?.contains(choice) == true }
}

/// Why AI is not given a tab.
enum HiddenFromAI {
    /// A private tab: to an agent it isn't there.
    case privateTab
    /// A tab in a space hidden from AI: refused, and told why.
    case space

    /// What an agent hears for a tab in such a space.
    static let refusal = "the person hides this tab's space from AI: an agent can't see or use its tabs. Ask them to move the page to another space."

    /// What an agent hears for opening or reading in one.
    static let spaceRefusal = "the person hides that space from AI: an agent can't open pages or use its sign-ins there. Use another space."
}

/// What Yab writes down of a tab's browsing.
struct Recording: OptionSet {
    let rawValue: Int
    /// A visit in History and the diary, the page's words included.
    static let history = Recording(rawValue: 1 << 0)
    /// That visit in the day's threads too.
    static let threads = Recording(rawValue: 1 << 1)
}

extension Browser {
    /// Why no agent or model is given this tab, or nil when it may be.
    /// Never an agent's own tab, which is no space's row and works on in
    /// whichever space is on screen, nor a pin every space shares. A
    /// person's tab an agent took along counts by the space it came from.
    func whyHiddenFromAI(_ tab: Tab?) -> HiddenFromAI? {
        guard let tab else { return nil }
        if tab.shy { return .privateTab }
        guard !tab.bench, tab.everywhere == nil, let id = tab.homeSpace ?? spaceHolding(tab) else { return nil }
        return hidesFromAI(space: id) ? .space : nil
    }

    /// The one question before an agent or a model is given a tab.
    func hiddenFromAI(_ tab: Tab?) -> Bool { whyHiddenFromAI(tab) != nil }

    /// This window's list says so, or the one last written by any window.
    func hidesFromAI(space id: UUID) -> Bool {
        spaces.contains { $0.id == id && $0.has(.hiddenFromAI) } || AIUse.hides(id.uuidString)
    }

    /// Where an agent's page goes when it names no space: the one on
    /// screen, unless that is hidden from AI, whose sign-ins it would use;
    /// then the first that isn't. Nil when every space is.
    func spaceForAgent(_ named: UUID?) -> UUID?? {
        guard named == nil, hidesFromAI(space: spaceID) else { return .some(named) }
        guard let open = spaces.first(where: { !hidesFromAI(space: $0.id) }) else { return nil }
        return .some(open.id)
    }

    /// The one question before a visit is written down: nothing of a
    /// private tab or an agent's own, nor of a space that keeps no
    /// history; no threads of an agent at work in your tab, a guest's, or
    /// a space that keeps none.
    func recording(_ tab: Tab, in space: UUID? = nil) -> Recording {
        guard !tab.shy, !tab.bench else { return [] }
        let privacy = (space ?? spaceHolding(tab)).flatMap { id in spaces.first { $0.id == id } }?.privacy ?? []
        if privacy.contains(.noHistory) { return [] }
        if privacy.contains(.noThreads) || tab.agent != nil || tab.guest != nil { return .history }
        return [.history, .threads]
    }

    /// Settings › Spaces › Privacy. Hide from AI writes the day notes
    /// agents read again, the space's threads out of them or back in.
    func setPrivacy(_ id: UUID, _ choice: SpacePrivacy, _ on: Bool) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), spaces[at].has(choice) != on else { return }
        var privacy = spaces[at].privacy ?? []
        if on { privacy.insert(choice) } else { privacy.remove(choice) }
        spaces[at].privacy = privacy.isEmpty ? nil : privacy
        Spaces.write(spaces)
        if choice == .hiddenFromAI { Diary.shared.rewriteDayNotes(of: id.uuidString) }
        if choice == .noHistory, let core = ChromiumProcess.shared.connectedClient {
            let profile = ChromiumPersistentProfiles.profile(store: Spaces.store(for: id), placement: id)
            Task { await ChromiumHistory.opened(profile, core: core) }
        }
    }
}

extension Tab {
    /// Why AI is not given it, in whichever window holds it: for the places
    /// that ask of a tab alone.
    @MainActor var whyHiddenFromAI: HiddenFromAI? {
        shy ? .privateTab : BrowserWindows.shared.browsers.lazy.compactMap { $0.whyHiddenFromAI(self) }.first
    }

    @MainActor var hiddenFromAI: Bool { whyHiddenFromAI != nil }
}

extension AIUse {
    /// `allows`, and the tab is not in a space hidden from AI. A private
    /// tab is the caller's to weigh: some models may still read one on
    /// this Mac.
    @MainActor static func allows(_ use: Use, for tab: Tab?) -> Bool {
        allows(use) && tab?.whyHiddenFromAI != .space
    }

    static func allows(_ use: Use, space: UUID?) -> Bool { allows(use, space: space?.uuidString) }
}

extension Diary {
    /// Who a read of the diary is for. The person reads it all; anything
    /// that goes to an agent or a model reads as `.ai`, which leaves out
    /// every page a visit in a space hidden from AI reached, even one also
    /// opened elsewhere: a page's title and words are one row, not one per
    /// space. A thread holding such a page is left out too, as its name may
    /// be that page's title.
    struct Reader: Sendable {
        /// The spaces whose pages it is not given.
        let hidden: Set<String>

        static let person = Reader(hidden: [])
        static var ai: Reader { Reader(hidden: AIUse.hiddenSpaces) }

        /// SQL true for a page it may read, by the page's key column.
        func page(_ key: String) -> String {
            hidden.isEmpty ? "1" : "\(key) NOT IN (\(heldKeys))"
        }

        /// SQL true for a thread it may read, by the thread's id column.
        func thread(_ id: String) -> String {
            hidden.isEmpty ? "1" : "\(id) NOT IN (SELECT thread FROM visits WHERE thread IS NOT NULL AND key IN (\(heldKeys)))"
        }

        private var heldKeys: String {
            "SELECT key FROM visits WHERE space IN (" + hidden.sorted().map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ") + ")"
        }
    }
}

/// Don't Keep History on Chromium's side: its profile keeps a history of its
/// own, beside Yab's. A profile saves none while any space using it keeps
/// none (Chrome's SavingBrowserHistoryDisabled, YabCore `profile.history`),
/// said each time a page opens it and when the choice changes.
@MainActor
enum ChromiumHistory {
    static func saving(_ profile: String) -> Bool {
        !Spaces.read().contains { space in
            space.has(.noHistory) && ChromiumPersistentProfiles.profile(store: Spaces.store(for: space.id), placement: space.id) == profile
        }
    }

    static func opened(_ profile: String, core: YabCoreClient) async {
        do { _ = try await core.request("profile.history", params: ["profile": .string(profile), "saving": .bool(saving(profile))]) }
        catch { DebugLog.note("chromium-history", ["profile": profile, "error": String(describing: error)]) }
    }
}
