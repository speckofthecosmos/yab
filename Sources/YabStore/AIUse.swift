import Foundation

/// Settings › AI › AI in Yab: how much of Yab's AI is there, one choice
/// read by every AI surface through `allows` (register 955, #1041a, #787,
/// 1179). It lives here, beside AppleModelAccess, so the mail engine's
/// model reads (MailSense) obey it as the app does.
///
/// - On: as Yab always was.
/// - When Asked: only what you call up yourself (⌘J, selected text, the
///   chat column, a task asked of an agent). No Ask or Task rows under the
///   words, ⇥ asks nothing, and nothing runs in the background: While You
///   Browse, mail sorted by the Mac's model, routines, Know Me, the
///   morning look and replies written ahead.
/// - Off: no AI anywhere and nothing sent to a model, the Mac's included.
///
/// Agents driving Yab, outside ones through `yab` and MCP and Yab's own
/// tasks through the same socket, are their own switch (Let agents use Yab,
/// `bench`), untouched by this one.
public enum AIUse {
    public enum Level: String, CaseIterable, Sendable {
        case on, asked, off

        /// As the switch in Settings › AI says it.
        public var title: String {
            switch self {
            case .on: return "On"
            case .asked: return "When Asked"
            case .off: return "Off"
            }
        }
    }

    /// What a surface is, for the gate.
    public enum Use: CaseIterable, Sendable {
        /// The Ask and Task rows under the words in ⌘T and ⌘L, and ⇥ asking.
        case field
        /// Model work nobody asked for just now: While You Browse, mail
        /// sorting and summaries, routines, Know Me, the morning look.
        case background
        /// What you call up yourself: ⌘J, Ask About This on a selection,
        /// selection commands, the chat column, a task, site buttons.
        case asked
    }

    public static let key = "ai.use"
    /// Hide AI Rows in Field: the Ask and Task rows and ⇥ asking put away
    /// without touching the switch (⌘T's command, ⌘K on an Ask row).
    public static let rowsKey = "ai.field.rows.hidden"
    public static let changed = Notification.Name("YabAIUseChanged")

    /// The one rule every surface asks.
    public static func allows(_ use: Use, level: Level, rowsHidden: Bool = false) -> Bool {
        switch level {
        case .off: return false
        case .asked: return use == .asked
        case .on: return use != .field || !rowsHidden
        }
    }

    public static func allows(_ use: Use, in defaults: UserDefaults = Store.settings) -> Bool {
        allows(use, level: level(in: defaults), rowsHidden: rowsHidden(in: defaults))
    }

    /// `allows`, and not for a space hidden from AI (Settings › Spaces ›
    /// Privacy), by the id a visit's space is written with.
    public static func allows(_ use: Use, space: String?, in defaults: UserDefaults = Store.settings) -> Bool {
        !hides(space) && allows(use, in: defaults)
    }

    private static let hiddenLock = NSLock()
    nonisolated(unsafe) private static var hidden: Set<String> = []

    /// The spaces hidden from AI, set by the app as it reads and writes its
    /// spaces; read on the diary's queue and the agents' too.
    public static var hiddenSpaces: Set<String> {
        get { hiddenLock.lock(); defer { hiddenLock.unlock() }; return hidden }
        set { hiddenLock.lock(); hidden = newValue; hiddenLock.unlock() }
    }

    public static func hides(_ space: String?) -> Bool {
        guard let space, !space.isEmpty else { return false }
        return hiddenSpaces.contains(space)
    }

    public static func level(in defaults: UserDefaults = Store.settings) -> Level {
        defaults.string(forKey: key).flatMap(Level.init) ?? .on
    }

    public static func rowsHidden(in defaults: UserDefaults = Store.settings) -> Bool {
        defaults.bool(forKey: rowsKey)
    }

    /// Kept, and told: AppleModelAccess's listeners too, since the Mac's
    /// model goes with the switch (Writing Tools, the selection's hint).
    public static func set(_ level: Level, in defaults: UserDefaults = Store.settings) {
        let before = self.level(in: defaults)
        defaults.set(level.rawValue, forKey: key)
        guard before != level else { return }
        NotificationCenter.default.post(name: changed, object: nil)
        NotificationCenter.default.post(name: AppleModelAccess.changed, object: nil)
    }

    public static func setRowsHidden(_ hidden: Bool, in defaults: UserDefaults = Store.settings) {
        let before = rowsHidden(in: defaults)
        defaults.set(hidden, forKey: rowsKey)
        if before != hidden { NotificationCenter.default.post(name: changed, object: nil) }
    }
}
