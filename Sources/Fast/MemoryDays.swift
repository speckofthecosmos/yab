import AppKit
import SwiftUI

// Memory › Days with the day's threads (docs/day-threads.md, variant A): a
// day's page opens with what you did as a timeline, times down the side, a
// dot in the thread's color on a hairline, its name, one line of what
// happened and its pages as chips; then what tasks noticed. Edit as
// Markdown ⌘E opens the note as text, as before. In the note itself the
// threads are a "## What you did" section, one line each, so agents read
// what the page shows; a line corrected there is kept, and the section is
// not written over again.

enum DayNotes {
    static let heading = "## What you did"

    /// One thread as the note says it: "- 10:20 to 11:40 AM · Compared Arc
    /// and Dia pricing. Dia Pro is $20 a month billed yearly."
    static func line(_ thread: DayThread) -> String {
        "- \(thread.when) · \(thread.told)" + (thread.summary.isEmpty ? " (\(DayThreads.pages(thread.pages.count)))" : ". " + thread.summary)
    }

    /// The section as written, heading and lines.
    static func section(_ lines: [String]) -> String {
        ([heading] + lines).joined(separator: "\n")
    }

    /// Where the section is in a note: from its heading to the next heading,
    /// the first blank line after its lines, or the end.
    static func range(in body: String) -> Range<String.Index>? {
        guard let start = body.range(of: heading + "\n") ?? (body.hasSuffix(heading) ? body.range(of: heading, options: .backwards) : nil)
        else { return nil }
        var end = body.endIndex
        var cursor = start.upperBound
        while cursor < body.endIndex {
            let lineEnd = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
            let line = body[cursor..<lineEnd]
            if line.hasPrefix("#") || (line.trimmingCharacters(in: .whitespaces).isEmpty && cursor > start.upperBound) { end = cursor; break }
            cursor = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return start.lowerBound..<end
    }

    /// The note with the section put in, or in place of the one there:
    /// nil when there is nothing to change, or when the one there isn't
    /// the one last written (`last`), a correction of yours.
    static func written(_ body: String, day: String, lines: [String], last: String?) -> String? {
        let new = section(lines)
        if let range = range(in: body) {
            let there = body[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if let last, there != last.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
            if there == new { return nil }
            var out = body
            out.replaceSubrange(range, with: lines.isEmpty ? "" : new + "\n\n")
            return out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        guard !lines.isEmpty else { return nil }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "# \(day)\n\n\(new)\n" }
        // After the day's own heading, ahead of what tasks noticed.
        if body.hasPrefix("# "), let lineEnd = body.firstIndex(of: "\n") {
            let rest = body[body.index(after: lineEnd)...].drop { $0 == "\n" }
            return String(body[..<lineEnd]) + "\n\n" + new + "\n\n" + rest
        }
        return new + "\n\n" + body
    }

    /// What tasks noticed: the note's list lines outside the section.
    static func noticed(_ body: String) -> [String] {
        var text = body
        if let range = range(in: text) { text.removeSubrange(range) }
        return text.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
            let words = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return words.isEmpty || words.hasPrefix("<!--") ? nil : words
        }
    }
}

extension Diary {
    /// The day's note given its "## What you did", when agents may remember
    /// (Settings › Agents › Memory) and you haven't corrected it there.
    /// On the diary's queue.
    func writeDayNote(_ day: String) {
        // The browser's own diary only: a test's scratch one writes no notes.
        guard self === Diary.shared, Store.settings.object(forKey: "agents.forget") as? Bool != true, let date = Diary.day(named: day),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return }
        // Agents read the note (Diary.Reader).
        let lines = threadsNow(from: date, to: next, for: .ai).filter { $0.day == day }.map(DayNotes.line)
        Memory.prepare()
        let url = Memory.folder.appendingPathComponent("episodic/\(day).md")
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let last = meta("daynote." + day)
        guard let out = DayNotes.written(body, day: day, lines: lines, last: last), out.utf8.count <= Memory.fileLimit else { return }
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            setMeta("daynote." + day, DayNotes.section(lines))
            // Memory's list reads its notes again as it comes up: nothing
            // is read on the main thread while you browse.
        } catch {}
    }

    /// A space hidden from AI or let back (Browser.setPrivacy): the notes of
    /// the days with a thread holding a page seen in it, written again.
    func rewriteDayNotes(of space: String) {
        queue.async {
            guard self.db != nil else { return }
            for day in self.strings("""
            SELECT DISTINCT t.day FROM threads t JOIN visits v ON v.thread = t.id
            WHERE v.key IN (SELECT key FROM visits WHERE space = ?)
            """, [space]) {
                self.writeDayNote(day)
            }
        }
    }
}

/// The days' threads Memory shows, read from the diary as its pages open.
@MainActor
final class DaysModel: ObservableObject {
    static let shared = DaysModel()

    @Published private(set) var threads: [String: [DayThread]] = [:]
    /// The day's note open as text, by its path: Edit as Markdown (⌘E).
    @Published var editing: String?
    private var watching: Any?

    private init() {
        watching = NotificationCenter.default.addObserver(forName: Diary.threadsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private var asked: [String] = []

    /// These days' threads, "2026-10-20", read off the main thread.
    func load(_ days: [String]) {
        asked = days
        let dates = days.compactMap { Diary.day(named: $0) }
        guard let first = dates.min(), let last = dates.max(),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        Diary.shared.threads(from: first, to: end) { [weak self] found in
            guard let self else { return }
            let grouped = Dictionary(grouping: found, by: \.day)
            var out: [String: [DayThread]] = [:]
            for day in days { out[day] = grouped[day] ?? [] }
            if out != self.threads { self.threads = out }
        }
    }

    func reload() { if !asked.isEmpty { load(asked) } }

    /// A day's row in Memory: its threads in a line.
    func summary(_ note: MemoryNote) -> String? { DaysModel.summary(threads[note.day] ?? []) }

    /// "4 threads · Show HN draft, SFO flights, Arc and Dia pricing, tax forms".
    static func summary(_ threads: [DayThread]) -> String? {
        guard !threads.isEmpty else { return nil }
        let names = threads.sorted { $0.start > $1.start }.map(\.topic)
        return "\(threads.count) thread\(threads.count == 1 ? "" : "s") · " + names.joined(separator: ", ")
    }

    /// "4 threads · 19 pages · 9:10 AM to now".
    static func head(_ threads: [DayThread]) -> String {
        guard let first = threads.min(by: { $0.start < $1.start }), let last = threads.max(by: { $0.end < $1.end }) else { return "" }
        let pages = threads.reduce(0) { $0 + $1.pages.count }
        let span = DayThreads.time(first.start) + " to " + (last.open ? "now" : DayThreads.time(last.end))
        return "\(threads.count) thread\(threads.count == 1 ? "" : "s") · \(DayThreads.pages(pages)) · \(span)"
    }

    /// Each thread's dot, by its place in the day.
    static let colors: [NSColor] = [.systemPurple, .systemGreen, .systemBlue, .systemOrange, .systemPink, .systemTeal, .systemIndigo, .systemRed]

    static func color(_ thread: DayThread) -> Color { Color(nsColor: colors[thread.order % colors.count]) }
}

/// A day's page in Memory: its head, its threads as a timeline, what tasks
/// noticed; Edit as Markdown ⌘E for the note as text.
struct DayPage: View {
    let note: MemoryNote
    let body_: String
    let browser: Browser?
    let editAsText: () -> Void
    @ObservedObject private var days = DaysModel.shared

    init(note: MemoryNote, text: String, browser: Browser?, editAsText: @escaping () -> Void) {
        self.note = note
        body_ = text
        self.browser = browser
        self.editAsText = editAsText
    }

    private var day: String { ((note.path as NSString).lastPathComponent as NSString).deletingPathExtension }

    var body: some View {
        let threads = days.threads[day] ?? []
        let noticed = DayNotes.noticed(body_)
        Section {} header: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) { // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
                        Text(note.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        if !threads.isEmpty {
                            Text(DaysModel.head(threads))
                                .font(.system(size: 12.5).monospacedDigit())
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(action: editAsText) {
                        HStack(spacing: 6) {
                            Text("Edit as Markdown")
                            KeyGlyphs(keys: "⌘E", size: 11.5, tint: nil).opacity(0.6)
                                .transaction { $0.animation = nil }
                        }
                    }
                    .buttonStyle(.yab(.secondary, .small))
                    .keyboardShortcut("e", modifiers: .command)
                    .padding(.top, 2)
                }
                .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                        DayThreadRow(thread: thread, last: index == threads.count - 1, browser: browser)
                    }
                }
                if !noticed.isEmpty {
                    Text("What tasks noticed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.top, 14) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
                        .padding(.bottom, 6)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(noticed.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .center, spacing: 8) {
                                AgentFaceMark(size: 16)
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .onAppear {
                days.load([day])
                Diary.shared.nameDay(day)
            }
        }
    }
}

/// The agent's face, small, beside a line a task noticed.
private struct AgentFaceMark: View {
    let size: CGFloat
    var body: some View {
        Symbol("agent.face", size: size / Glyphs.scale)
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
    }
}

/// One thread on a day's timeline: its start and end down the side, its
/// dot on the hairline, its name, a line of what happened, its pages.
/// Right-click: Open in History, Reopen as Folder, Rename…, Forget This
/// Thread.
struct DayThreadRow: View {
    let thread: DayThread
    let last: Bool
    let browser: Browser?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(DayThreadRow.start(thread))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Text(thread.open ? "now" : DayThreadRow.bare(thread.end))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Palette.muted)
            }
            .frame(width: 52, alignment: .trailing)
            .padding(.top, 1)
            Circle()
                .fill(DaysModel.color(thread))
                .frame(width: 8, height: 8)
                .padding(.leading, 3) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
                .padding(.trailing, 3) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
                .padding(.top, 3) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.told)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if !thread.summary.isEmpty {
                    Text(thread.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                PageChips(pages: thread.pages)
                    .padding(.top, 7) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.top, 9) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
        .padding(.bottom, 11) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
        .overlay(alignment: .topLeading) {
            if !last {
                // From under its dot down to the next one's, as the prototype draws the timeline.
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 24) // design: the dot's top (9) and its height and air (15)
                    .padding(.bottom, -3) // design: on past the row's foot to the next row
                    .offset(x: 78.5) // design: the times' column, the gap and the dot's middle (10 + 52 + 10 + 6.5)
            }
        }
        .padding(.horizontal, -10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open in History") { open { $0.showThreadInHistory(thread.id) } }
            Button("Reopen as Folder") { open { $0.reopenAsFolder(thread.pages.compactMap { URL(string: $0.url) }, named: thread.name) } }
            Button("Rename…") { browser?.renameThread(thread.id, was: thread.name, place: .settings) }
            Divider()
            Button("Forget This Thread") { browser?.forgetThread(thread.id, inSettings: true) }
        }
        .accessibilityElement(children: .combine)
    }

    /// The browser's window in front, over Settings, for what opens there.
    private func open(_ act: (Browser) -> Void) {
        guard let browser else { return }
        browser.tuning = false
        NSApp.activate()
        BrowserWindows.shared.window(for: browser)?.makeKeyAndOrderFront(nil)
        act(browser)
    }

    /// "9:10", the meridiem said once the day turns past noon: "2:00 PM".
    static func start(_ thread: DayThread) -> String {
        let hour = Calendar.current.component(.hour, from: thread.start)
        let past = hour >= 13 && thread.order > 0
        return bare(thread.start) + (past && firstAfternoon(thread) ? " PM" : "")
    }

    /// Whether this is the day's first thread after one o'clock.
    private static func firstAfternoon(_ thread: DayThread) -> Bool {
        guard let all = DaysModel.shared.threads[thread.day] else { return false }
        return all.first { Calendar.current.component(.hour, from: $0.start) >= 13 }?.id == thread.id
    }

    static func bare(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "h:mm"
        return format.string(from: date)
    }
}

/// A thread's pages as chips, its icon and title each, the first two and
/// "+N" for the rest.
struct PageChips: View {
    let pages: [DayThread.Page]

    var body: some View {
        HStack(spacing: 5) { // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
            ForEach(Array(pages.prefix(2).enumerated()), id: \.offset) { _, page in
                HStack(spacing: 5) { // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
                    let bare = page.host.hasPrefix("www.") ? String(page.host.dropFirst(4)) : page.host
                    Mark(icon: Favicons.shared.cached(page.host) ?? Favicons.shared.cached(bare),
                         letter: bare.first.map { String($0).uppercased() } ?? "", size: 14)
                    Text(MarkdownLink.title(page.title, host: page.host))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // As wide as its words, up to the chip's 190 less its mark and insets.
                        .frame(maxWidth: 153, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 4)
                .padding(.trailing, 8) // design: the picked day timeline's measure (day-threads/prototype.html, .tl .pchip .dh)
                .frame(height: 22)
                .background(Capsule().fill(Palette.ink.opacity(0.05)))
            }
            if pages.count > 2 {
                Text("+\(pages.count - 2)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}
