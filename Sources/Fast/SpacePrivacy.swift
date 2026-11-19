import Foundation

// Settings › Spaces › a space › Privacy: choices of this Mac's, each on its
// own (Space.privacy).
//
// - Hide from AI: Yab records everything in the space for you, as in any
//   space (history, the day's threads, suggestions), and gives none of it
//   to an agent or a model. A private tab is hidden from AI too, but it
//   keeps nothing; here you keep it all, and only AI is kept out.
//
// Each rides one gate. A tab: Browser.whyHiddenFromAI, which a private tab
// answers too. The diary: a Diary.Reader, which every read for AI passes. A
// model: AIUse.allows, given the tab or space it is about to use.

struct SpacePrivacy: OptionSet, Codable, Hashable {
    let rawValue: Int

    static let hiddenFromAI = SpacePrivacy(rawValue: 1 << 0)

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

    /// Settings › Spaces › Privacy. Hide from AI writes the day notes
    /// agents read again, the space's threads out of them or back in.
    func setPrivacy(_ id: UUID, _ choice: SpacePrivacy, _ on: Bool) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), spaces[at].has(choice) != on else { return }
        var privacy = spaces[at].privacy ?? []
        if on { privacy.insert(choice) } else { privacy.remove(choice) }
        spaces[at].privacy = privacy.isEmpty ? nil : privacy
        Spaces.write(spaces)
        if choice == .hiddenFromAI { Diary.shared.rewriteDayNotes(of: id.uuidString) }
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
