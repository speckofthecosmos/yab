import Foundation
import SQLite3

// The diary's side of day threads (docs/day-threads.md): a `threads` table
// beside `visits`, each visit pointing at its thread, and `acts`, what you
// did on a page that Yab saw itself (copied, downloaded). Everything here
// runs on the diary's queue; the main thread only hands work to it.
//
// A day is grouped again whole after it changes (`rethread`): a few hundred
// visits are milliseconds of word sets, and a pass over the whole day is
// simpler and steadier than patching. Each new group takes the id of the
// old thread it shares the most visits with, so a name a model or you gave
// stays with what it named.

extension Diary {
    /// What grouping has cost, for the bench and the perf note: passes run,
    /// their time on the diary's queue, and any on the main thread, which
    /// should stay none.
    struct ThreadStats: Sendable {
        var passes = 0
        var visits = 0
        var milliseconds = 0.0
        var longest = 0.0
        var onMain = 0
    }

    /// The tables, added to a diary that had none.
    func makeThreads() {
        let columns = Set(query("PRAGMA table_info(visits)", []).compactMap { $0[1] as? String })
        if !columns.contains("space") { exec("ALTER TABLE visits ADD COLUMN space TEXT") }
        if !columns.contains("quiet") { exec("ALTER TABLE visits ADD COLUMN quiet INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("thread") { exec("ALTER TABLE visits ADD COLUMN thread INTEGER") }
        exec("""
        CREATE INDEX IF NOT EXISTS visits_thread ON visits(thread);
        CREATE TABLE IF NOT EXISTS threads(
          id INTEGER PRIMARY KEY, day TEXT NOT NULL, space TEXT NOT NULL DEFAULT '', start REAL NOT NULL, end REAL NOT NULL,
          topic TEXT NOT NULL DEFAULT '', name TEXT NOT NULL DEFAULT '', done TEXT NOT NULL DEFAULT '',
          summary TEXT NOT NULL DEFAULT '', named INTEGER NOT NULL DEFAULT 0, hue INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS threads_day ON threads(day);
        CREATE TABLE IF NOT EXISTS acts(id INTEGER PRIMARY KEY, key TEXT NOT NULL, at REAL NOT NULL, kind TEXT NOT NULL, words TEXT NOT NULL DEFAULT '');
        CREATE INDEX IF NOT EXISTS acts_key ON acts(key);
        """)
        if !Set(query("PRAGMA table_info(threads)", []).compactMap { $0[1] as? String }).contains("hue") {
            exec("ALTER TABLE threads ADD COLUMN hue INTEGER NOT NULL DEFAULT 0")
        }
    }

    static func dayName(_ date: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        return format.string(from: date)
    }

    static func day(named name: String, calendar: Calendar = .current) -> Date? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd"
        return format.date(from: name)
    }

    // MARK: - grouping

    /// A visit landed: today grouped again a moment later, once the
    /// browsing has paused, on the queue.
    func threadSoon() {
        threadLock.lock()
        threadPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rethreadNow(Date())
            self.nameSoon()
        }
        threadPending = work
        threadLock.unlock()
        queue.asyncAfter(deadline: .now() + Diary.threadDelay, execute: work)
    }

    /// How long after the last visit a pass runs: long enough that a run of
    /// pages is one pass, short enough that ⌘T knows the last half hour.
    static var threadDelay: TimeInterval { Store.testing ? 2 : 45 }

    /// The day `at` is in grouped again, and done called on the main
    /// thread.
    func rethread(_ at: Date, then done: (() -> Void)? = nil) {
        queue.async {
            self.rethreadNow(at)
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    /// The days of the last `days` not grouped yet, once: a diary from
    /// before threads, or a month seeded for a test.
    func backfillThreads(days: Int = 30, then done: (() -> Void)? = nil) {
        queue.async {
            guard self.db != nil else { if let done { DispatchQueue.main.async(execute: done) }; return }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            for back in 0..<days {
                guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
                let name = Diary.dayName(day)
                if back > 0, self.meta("threads." + name) != nil { continue }
                self.rethreadNow(day)
            }
            self.nameSoon()
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    func rethreadNow(_ at: Date) {
        if Thread.isMainThread { threadStats.onMain += 1 }
        guard db != nil else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: at)
        guard let to = calendar.date(byAdding: .day, value: 1, to: from) else { return }
        let day = Diary.dayName(from)
        let rows = query("""
        SELECT v.id, v.key, v.at, COALESCE(v.space, ''), p.title, p.host, v.thread,
          (SELECT body FROM words w WHERE w.key = v.key AND w.kind = 1 LIMIT 1)
        FROM visits v JOIN pages p ON p.key = v.key
        WHERE v.at >= ? AND v.at < ? AND v.quiet = 0 ORDER BY v.at
        """, [from.timeIntervalSince1970, to.timeIntervalSince1970])
        var said: [String: Set<String>] = [:]
        let visits: [DayThreads.Visit] = rows.map { row in
            let key = row[1] as? String ?? ""
            let title = row[4] as? String ?? ""
            let host = row[5] as? String ?? ""
            if said[key] == nil { said[key] = DayThreads.words(title: title, host: host, text: row[7] as? String ?? "") }
            return DayThreads.Visit(id: row[0] as? Int64 ?? 0, key: key, at: Date(timeIntervalSince1970: row.double(2) ?? 0),
                                    host: host, title: title, space: row[3] as? String ?? "", words: said[key] ?? [])
        }
        var was: [Int64: Set<Int64>] = [:]
        for row in rows {
            if let thread = row[6] as? Int64, let id = row[0] as? Int64 { was[thread, default: []].insert(id) }
        }
        let old = query("SELECT id, named FROM threads WHERE day = ?", [day])
        let named = Dictionary(uniqueKeysWithValues: old.compactMap { row -> (Int64, Int64)? in
            guard let id = row[0] as? Int64 else { return nil }
            return (id, row[1] as? Int64 ?? 0)
        })
        let groups = DayThreads.group(visits)
        exec("BEGIN")
        run("UPDATE visits SET thread = NULL WHERE at >= ? AND at < ?", [from.timeIntervalSince1970, to.timeIntervalSince1970])
        var used = Set<Int64>()
        for group in groups {
            let ids = Set(group.map { visits[$0].id })
            // The old thread this one is most of, a named one first.
            var match: (id: Int64, shared: Int)?
            for (id, members) in was where !used.contains(id) {
                let shared = members.intersection(ids).count
                guard shared > 0 else { continue }
                if let best = match {
                    let better = shared != best.shared ? shared > best.shared : (named[id] ?? 0) > (named[best.id] ?? 0)
                    if !better { continue }
                }
                match = (id, shared)
            }
            let first = visits[group[0]], last = visits[group[group.count - 1]]
            let fallback = DayThreads.fallbackName(group.map { (visits[$0].title, visits[$0].host) })
            let thread: Int64
            if let match {
                thread = match.id
                used.insert(thread)
                run("UPDATE threads SET space = ?, start = ?, end = ? WHERE id = ?",
                    [first.space, first.at.timeIntervalSince1970, last.at.timeIntervalSince1970, thread])
                if (named[thread] ?? 0) == 0 {
                    run("UPDATE threads SET topic = ?, name = ?, done = ? WHERE id = ?", [fallback, fallback, fallback, thread])
                }
            } else {
                // Its color for good, the next of the day's: forgetting one
                // leaves the others' as they were.
                let hue = int("SELECT COALESCE(MAX(hue) + 1, 0) FROM threads WHERE day = ?", [day]) ?? 0
                run("INSERT INTO threads(day, space, start, end, topic, name, done, hue) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                    [day, first.space, first.at.timeIntervalSince1970, last.at.timeIntervalSince1970, fallback, fallback, fallback, hue])
                thread = lastRow()
                used.insert(thread)
            }
            for id in ids { run("UPDATE visits SET thread = ? WHERE id = ?", [thread, id]) }
        }
        for row in old {
            guard let id = row[0] as? Int64, !used.contains(id) else { continue }
            run("DELETE FROM threads WHERE id = ?", [id])
        }
        setMeta("threads." + day, "\(Date().timeIntervalSince1970)")
        exec("COMMIT")
        if !groups.isEmpty || !old.isEmpty { writeDayNote(day) }
        let spent = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        threadStats.passes += 1
        threadStats.visits += visits.count
        threadStats.milliseconds += spent
        threadStats.longest = max(threadStats.longest, spent)
    }

    // MARK: - naming

    /// Threads that have a name of their pages' titles only, done or long
    /// enough to say what they are, handed to the namer a few at a time:
    /// the last two days' as you browse, an older day's when its page is
    /// opened (`day`). A month grouped at once never asks for a month of names.
    func nameSoon(day: String? = nil) {
        guard db != nil else { return }
        let wanted = waitingForNames(day: day).filter { !threadAsked.contains($0) }.prefix(day == nil ? 6 : 12)
        guard !wanted.isEmpty else { return }
        var asks: [(Int64, String)] = []
        for id in wanted {
            threadAsked.insert(id)
            guard let thread = threadNow(id) else { continue }
            let passages = Dictionary(uniqueKeysWithValues: thread.pages.prefix(6).map { page in
                (page.key, string("SELECT body FROM words WHERE key = ? AND kind = 1 LIMIT 1", [page.key]) ?? "")
            })
            let prompt = DayThreads.prompt(pages: thread.pages.map { ($0.title, $0.host, passages[$0.key] ?? "") },
                                           acts: thread.did.map { $0.words })
            asks.append((id, prompt))
        }
        guard !asks.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for (id, prompt) in asks {
                    ThreadNamer.shared.name(prompt) { [weak self] naming in
                        guard let self, let naming else { return }
                        self.queue.async { self.named(id, naming, by: 1) }
                    }
                }
            }
        }
    }

    /// The threads a name could be asked for, newest first: a model names
    /// them, so a thread hidden from AI keeps the name its titles give.
    func waitingForNames(day: String? = nil, now: Date = Date(), for reader: Reader = .ai) -> [Int64] {
        let now = now.timeIntervalSince1970
        let scope = day == nil ? "t.start >= ?" : "t.day = ?"
        return query("""
        SELECT t.id FROM threads t WHERE t.named = 0 AND \(scope) AND \(reader.thread("t.id"))
          AND (t.end < ? OR (SELECT COUNT(DISTINCT key) FROM visits v WHERE v.thread = t.id) >= 4)
        ORDER BY t.end DESC LIMIT 40
        """, [day ?? (now - 2 * 86_400), now - DayThreads.gap] as [Any]).compactMap { $0[0] as? Int64 }
    }

    /// A day's page opened: its threads named, if they aren't yet.
    func nameDay(_ day: String) {
        queue.async { self.nameSoon(day: day) }
    }

    /// A model's name kept, unless you named it meanwhile.
    func named(_ id: Int64, _ naming: DayThreads.Naming, by: Int) {
        run("UPDATE threads SET topic = ?, name = ?, done = ?, summary = ?, named = ? WHERE id = ? AND named <= ?",
            [naming.topic, naming.doing, naming.done, naming.line, by, id, by == 2 ? 2 : 0])
        if let day = string("SELECT day FROM threads WHERE id = ?", [id]) { writeDayNote(day) }
        if by == 1 { DispatchQueue.main.async { NotificationCenter.default.post(name: Diary.threadsChanged, object: nil) } }
    }

    static let threadsChanged = Notification.Name("yab.diary.threads")

    /// Rename… : your words, kept over any model's.
    func rename(thread id: Int64, to name: String, then done: (() -> Void)? = nil) {
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            if !words.isEmpty {
                self.run("UPDATE threads SET topic = ?, name = ?, done = ?, named = 2 WHERE id = ?", [words, words, words, id])
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Diary.threadsChanged, object: nil)
                done?()
            }
        }
    }

    // MARK: - what you did

    /// Something done on a page Yab saw itself: copied, downloaded. Kept
    /// only for a page in the diary seen in the last half hour, so a
    /// private tab's, a sign-in's or an agent's leaves nothing.
    func act(_ kind: DayThread.Act.Kind, on url: URL, words: String = "", at: Date = Date()) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let key = Diary.key(url)
        let text = String(words.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(80))
        queue.async {
            guard self.db != nil,
                  self.int("SELECT 1 FROM visits WHERE key = ? AND quiet = 0 AND at >= ?", [key, at.timeIntervalSince1970 - 1800]) != nil
            else { return }
            self.run("INSERT INTO acts(key, at, kind, words) VALUES(?, ?, ?, ?)", [key, at.timeIntervalSince1970, kind.rawValue, text])
        }
    }

    // MARK: - reading back

    /// The threads of these days, oldest first, each with its pages and
    /// what you did, on the main thread.
    func threads(from: Date, to: Date, done: @escaping ([DayThread]) -> Void) {
        queue.async {
            let found = self.threadsNow(from: from, to: to)
            DispatchQueue.main.async { done(found) }
        }
    }

    func threads(from: Date, to: Date, for reader: Reader = .person) async -> [DayThread] {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: self.threadsNow(from: from, to: to, for: reader)) }
        }
    }

    func thread(_ id: Int64) async -> DayThread? {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: self.threadNow(id)) }
        }
    }

    /// What grouping has cost so far.
    func threadCost() async -> ThreadStats {
        await withCheckedContinuation { done in queue.async { done.resume(returning: self.threadStats) } }
    }

    func threadsNow(from: Date, to: Date, for reader: Reader = .person) -> [DayThread] {
        guard db != nil else { return [] }
        let rows = query("SELECT id FROM threads WHERE end >= ? AND start < ? AND \(reader.thread("id")) ORDER BY start",
                         [from.timeIntervalSince1970, to.timeIntervalSince1970])
        return rows.compactMap { ($0[0] as? Int64).flatMap(threadNow) }
    }

    func threadNow(_ id: Int64) -> DayThread? {
        guard db != nil,
              let row = query("SELECT id, day, space, start, end, topic, name, done, summary, named FROM threads WHERE id = ?", [id]).first
        else { return nil }
        let day = row[1] as? String ?? ""
        let visits = query("""
        SELECT v.key, v.at, p.url, p.title, p.host FROM visits v JOIN pages p ON p.key = v.key
        WHERE v.thread = ? ORDER BY v.at
        """, [id])
        var pages: [DayThread.Page] = []
        for visit in visits {
            let key = visit[0] as? String ?? ""
            let seen = Date(timeIntervalSince1970: visit.double(1) ?? 0)
            if let at = pages.firstIndex(where: { $0.key == key }) {
                pages[at].visits += 1
                pages[at].last = seen
                continue
            }
            pages.append(DayThread.Page(key: key, url: visit[2] as? String ?? "", title: visit[3] as? String ?? "",
                                        host: visit[4] as? String ?? "", at: seen, visits: 1, last: seen))
        }
        guard pages.count >= DayThreads.least else { return nil }
        let start = Date(timeIntervalSince1970: row.double(3) ?? 0)
        let end = Date(timeIntervalSince1970: row.double(4) ?? 0)
        let order = Int(int("SELECT hue FROM threads WHERE id = ?", [id]) ?? 0)
        var acts: [DayThread.Act] = []
        // Read: the page stayed on longest, till the next page of the
        // thread, if that was a while. One line, the page it was about;
        // the last page's stay can't be told from a pause, so it isn't read.
        let space = row[2] as? String ?? ""
        var longest: (at: Double, key: String, stayed: Double)?
        for (index, visit) in visits.enumerated() where index + 1 < visits.count || visits.count == 1 {
            let at = visit.double(1) ?? 0
            let next = index + 1 < visits.count ? (visits[index + 1].double(1) ?? at)
                : (double("SELECT MIN(at) FROM visits WHERE at > ? AND COALESCE(space, '') = ?", [at, space]) ?? at)
            let stayed = min(next - at, DayThreads.gap)
            if stayed >= DayThreads.reading, stayed > (longest?.stayed ?? 0) { longest = (at, visit[0] as? String ?? "", stayed) }
        }
        if let longest { acts.append(DayThread.Act(kind: .read, at: Date(timeIntervalSince1970: longest.at), key: longest.key, words: "")) }
        let keys = pages.map(\.key)
        let marks = keys.map { _ in "?" }.joined(separator: ",")
        for act in query("SELECT key, at, kind, words FROM acts WHERE key IN (\(marks)) AND at >= ? AND at <= ? ORDER BY at",
                         keys + [start.timeIntervalSince1970 - 60, end.timeIntervalSince1970 + DayThreads.gap]) {
            guard let kind = (act[2] as? String).flatMap(DayThread.Act.Kind.init(rawValue:)) else { continue }
            acts.append(DayThread.Act(kind: kind, at: Date(timeIntervalSince1970: act.double(1) ?? 0), key: act[0] as? String ?? "",
                                      words: act[3] as? String ?? ""))
        }
        acts.sort { $0.at < $1.at }
        let isToday = day == Diary.dayName(Date())
        return DayThread(id: id, day: day, space: space, start: start, end: end,
                         topic: row[5] as? String ?? "", name: row[6] as? String ?? "", done: row[7] as? String ?? "",
                         summary: row[8] as? String ?? "", named: Int(row[9] as? Int64 ?? 0), order: order,
                         pages: pages, acts: acts, open: isToday && Date().timeIntervalSince(end) < DayThreads.gap)
    }

    // MARK: - forgetting

    /// A thread's visits forgotten, and a page seen only in it whole, so ⌘Z
    /// can bring them back (`giveBack`).
    func take(thread id: Int64, then done: @escaping (Taken, [String]) -> Void) {
        queue.async {
            var taken = Taken()
            var urls: [String] = []
            if self.db != nil {
                let visits = self.query("SELECT id, key, at, space, quiet, thread FROM visits WHERE thread = ?", [id])
                taken.visits = visits.map(\.values)
                taken.threads = self.query("SELECT id, day, space, start, end, topic, name, done, summary, named, hue FROM threads WHERE id = ?", [id]).map(\.values)
                var counts: [String: Int] = [:]
                for visit in visits { if let key = visit[1] as? String { counts[key, default: 0] += 1 } }
                var whole: [String] = []
                self.exec("BEGIN")
                for (key, count) in counts {
                    guard var page = self.query("SELECT key, url, title, host, count, last, read FROM pages WHERE key = ?", [key]).first?.values else { continue }
                    let left = self.int("SELECT COUNT(*) FROM visits WHERE key = ? AND (thread IS NULL OR thread != ?)", [key, id]) ?? 0
                    if left == 0 {
                        whole.append(key)
                        if let url = page[1] as? String { urls.append(url) }
                    } else {
                        // Seen outside it too: stays, without these visits.
                        page[4] = Int64(count)
                        let before = self.double("SELECT MAX(at) FROM visits WHERE key = ? AND (thread IS NULL OR thread != ?)", [key, id]) ?? 0
                        self.run("UPDATE pages SET count = MAX(1, count - ?), last = ? WHERE key = ?", [count, before, key])
                    }
                    taken.pages.append(page)
                    taken.acts += self.query("SELECT key, at, kind, words FROM acts WHERE key = ?", [key]).map(\.values)
                }
                self.run("DELETE FROM visits WHERE thread = ?", [id])
                self.run("DELETE FROM threads WHERE id = ?", [id])
                self.exec("COMMIT")
                for key in whole {
                    taken.looks += self.query("SELECT key, image FROM looks WHERE key = ?", [key]).map(\.values)
                    taken.words += self.query("SELECT key, kind, title, body FROM words WHERE key = ?", [key]).map(\.values)
                    for file in [Diary.shot(key), Diary.og(key)] {
                        if let data = try? Data(contentsOf: file) { taken.files.append((file, data)) }
                    }
                }
                self.drop(keys: whole)
            }
            DispatchQueue.main.async { done(taken, urls) }
        }
    }
}

extension Diary {
    /// A visit put straight in, at its own time, for tests and a probe
    /// world's seeded month: its words too, as reading the page would.
    struct Planted: Sendable {
        var url: URL
        var title: String
        var at: Date
        var space = ""
        var quiet = false
        var text = ""
    }

    func plant(_ visits: [Planted], then done: (@Sendable () -> Void)? = nil) {
        queue.async {
            guard self.db != nil else { done?(); return }
            self.exec("BEGIN")
            for visit in visits {
                let id = self.write(visit.url, title: visit.title, at: visit.at, count: 1)
                self.run("UPDATE visits SET space = ?, quiet = ? WHERE id = ?", [visit.space, visit.quiet ? 1 : 0, id])
                let key = Diary.key(visit.url)
                if !visit.text.isEmpty, self.int("SELECT 1 FROM words WHERE key = ? AND kind = 1", [key]) == nil {
                    for body in Diary.passages(of: visit.text) {
                        self.run("INSERT INTO words(key, kind, title, body) VALUES(?, 1, '', ?)", [key, body])
                    }
                    self.run("UPDATE pages SET read = ? WHERE key = ?", [visit.at.timeIntervalSince1970, key])
                }
            }
            self.exec("COMMIT")
            done?()
        }
    }

    func plant(_ visits: [Planted]) async {
        await withCheckedContinuation { done in plant(visits) { done.resume() } }
    }

    /// The thread holding this page on that day, for a test or a seeded
    /// world to find what it planted.
    func threadID(holding url: URL, on day: Date) async -> Int64? {
        await withCheckedContinuation { done in
            queue.async {
                let from = Calendar.current.startOfDay(for: day).timeIntervalSince1970
                done.resume(returning: self.int("SELECT thread FROM visits WHERE key = ? AND at >= ? AND at < ? AND thread IS NOT NULL LIMIT 1",
                                                [Diary.key(url), from, from + 86_400]))
            }
        }
    }

    /// A name put on a thread as a model's would be, for a seeded world.
    func name(thread id: Int64, _ naming: DayThreads.Naming) async {
        await withCheckedContinuation { done in
            queue.async {
                self.named(id, naming, by: 1)
                done.resume()
            }
        }
    }

    func rethread(_ at: Date) async {
        await withCheckedContinuation { done in queue.async { self.rethreadNow(at); done.resume() } }
    }

    func take(thread id: Int64) async -> (Taken, [String]) {
        await withCheckedContinuation { done in take(thread: id) { done.resume(returning: ($0, $1)) } }
    }

    /// The last row put in, on the queue that put it.
    func lastRow() -> Int64 { db.map { sqlite3_last_insert_rowid($0) } ?? 0 }
}
