import AppKit
import Foundation
import Testing
import YabStore
@testable import Fast

// Settings › Spaces › Privacy (SpacePrivacy). Fixture data only: a diary of
// its own in a temporary folder, never this Mac's.
struct SpaceHiddenFromAIDiaryTests {
    static let hidden = "8E1C0D7A-1D2B-4C3D-8E4F-5A6B7C8D9E0F"
    static let ai = Diary.Reader(hidden: [hidden])

    /// An afternoon in a space hidden from AI, beside the prototype's
    /// morning in an ordinary one (DayThreadsTests.morning).
    static let afternoon: [Diary.Planted] = [
        DayThreadsTests.page("https://shop.example/cart", "Cart · Shop", DayThreadsTests.at(15, 0), space: hidden),
        DayThreadsTests.page("https://shop.example/orders", "Orders · Shop", DayThreadsTests.at(15, 5), space: hidden),
        DayThreadsTests.page("https://shop.example/returns", "Returns · Shop", DayThreadsTests.at(15, 10), space: hidden),
    ]

    static func onQueue<T: Sendable>(_ diary: Diary, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in diary.queue.async { done.resume(returning: work()) } }
    }

    static func threads(_ diary: Diary, for reader: Diary.Reader) async -> [DayThread] {
        let from = Calendar.current.startOfDay(for: DayThreadsTests.at(9, 0))
        return await diary.threads(from: from, to: from.addingTimeInterval(86_400), for: reader)
    }

    @Test func aHiddenSpacesThreadsAreKeptForYouButNotReadByAI() async {
        let (diary, folder) = DayThreadsTests.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(DayThreadsTests.morning + Self.afternoon)
        await diary.rethread(DayThreadsTests.at(9, 0))
        // Yours: every thread, the hidden space's too, as Memory shows them.
        let all = await Self.threads(diary, for: .person)
        #expect(all.count == 4)
        #expect(all.contains { $0.space == Self.hidden })
        // Read by AI: the hidden space's thread is gone, the others stay.
        let told = await Self.threads(diary, for: Self.ai)
        #expect(told.count == 3)
        #expect(!told.contains { $0.space == Self.hidden })
        // Nothing hidden, nothing left out.
        let open = await Self.threads(diary, for: Diary.Reader(hidden: []))
        #expect(open.count == 4)
    }

    @Test func aHiddenSpacesThreadsAreNeverSentToBeNamed() async {
        let (diary, folder) = DayThreadsTests.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(DayThreadsTests.morning + Self.afternoon)
        await diary.rethread(DayThreadsTests.at(9, 0))
        let held = await Self.threads(diary, for: .person).first { $0.space == Self.hidden }
        #expect(held != nil)
        let id = held?.id ?? -1
        let day = Diary.dayName(DayThreadsTests.at(9, 0))
        let asked = await Self.onQueue(diary) { diary.waitingForNames(day: day, for: Self.ai) }
        #expect(asked.count == 3)
        #expect(!asked.contains(id))
        // With the switch off, it is named as any thread.
        let before = await Self.onQueue(diary) { diary.waitingForNames(day: day, for: .person) }
        #expect(before.contains(id))
        // Meanwhile it keeps the name its titles give, made on this Mac.
        #expect(held?.named == 0)
        #expect(held?.name.isEmpty == false)
    }

    @Test func aPageAlsoOpenedInAHiddenSpaceKeepsItsOtherThreadFromAI() async {
        let (diary, folder) = DayThreadsTests.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The same page read in the hidden space at three, and again in an
        // ordinary one at five, with another page beside it.
        await diary.plant(Self.afternoon + [
            DayThreadsTests.page("https://shop.example/cart", "Cart · Shop", DayThreadsTests.at(17, 0)),
            DayThreadsTests.page("https://shop.example/help", "Help · Shop", DayThreadsTests.at(17, 4)),
        ])
        await diary.rethread(DayThreadsTests.at(9, 0))
        #expect(await Self.threads(diary, for: .person).contains { $0.space == "s1" })
        #expect(await Self.threads(diary, for: Self.ai).isEmpty)
    }

    @Test func dayNoteLinesLeaveOutAHiddenSpace() async {
        let (diary, folder) = DayThreadsTests.diary()
        defer { try? FileManager.default.removeItem(at: folder) }
        await diary.plant(DayThreadsTests.morning + Self.afternoon)
        await diary.rethread(DayThreadsTests.at(9, 0))
        // The lines writeDayNote writes; it writes them for the Mac's own
        // diary only, never a scratch one.
        let lines = await Self.threads(diary, for: Self.ai).map(DayNotes.line)
        #expect(lines.count == 3)
        #expect(!lines.joined().contains("Shop"))
    }

    @Test func theReadersSQLHoldsOutEveryHiddenSpaceAndOnlyThem() {
        #expect(Diary.Reader.person.page("p.key") == "1")
        #expect(Diary.Reader.person.thread("t.id") == "1")
        let two = Diary.Reader(hidden: ["B", "A"])
        #expect(two.page("p.key") == "p.key NOT IN (SELECT key FROM visits WHERE space IN ('A', 'B'))")
        #expect(two.thread("t.id").hasPrefix("t.id NOT IN (SELECT thread FROM visits WHERE thread IS NOT NULL AND key IN"))
        // An id is quoted as SQL quotes it, whatever it holds.
        #expect(Diary.Reader(hidden: ["it's"]).page("k").contains("'it''s'"))
    }

    @Test func aModelAskedForAHiddenSpaceIsRefusedWhateverTheSwitch() {
        let defaults = UserDefaults(suiteName: "space-privacy-" + UUID().uuidString)!
        let other = UUID().uuidString
        let before = AIUse.hiddenSpaces
        AIUse.hiddenSpaces = [Self.hidden]
        defer { AIUse.hiddenSpaces = before }
        #expect(!AIUse.allows(.asked, space: Self.hidden, in: defaults))
        #expect(!AIUse.allows(.background, space: Self.hidden, in: defaults))
        #expect(AIUse.allows(.background, space: other, in: defaults))
        #expect(AIUse.allows(.background, space: nil, in: defaults))
        // Off is still off for every other space.
        AIUse.set(.off, in: defaults)
        #expect(!AIUse.allows(.asked, space: other, in: defaults))
    }
}

// The agent's side: a tab in a space hidden from AI is refused by name,
// missing from `tabs`, and no native action reaches it; the same tab in an
// ordinary space works as before.
@MainActor @Suite(.serialized)
struct SpaceHiddenFromAIAgentTests {
    @MainActor private final class World {
        let browser = Browser(windowID: UUID())
        let bench = Bench()
        let session = Agents.shared.attach(name: "Hidden fixture")
        let user = Tab()
        let previousBench = Store.settings.object(forKey: "bench")
        let url = URL(string: "http://127.0.0.1:9/hidden")!

        init(hidden: Bool) {
            _ = NSApplication.shared
            Store.settings.set(true, forKey: "bench")
            var space = Space(id: browser.spaceID, name: "Personal", icon: "🏠", ownSignIns: false)
            space.privacy = hidden ? .hiddenFromAI : nil
            browser.spaces = [space]
            user.restore(url: url, title: "Hidden fixture page")
            browser.lay([user])
            browser.activeID = user.id
            bench.start(for: browser)
        }

        func ask(_ values: [String: Any]) async -> [String: Any] {
            var request = values
            request["session"] = session.id
            let path = Bench.socket.path
            return await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: Wire.ask(path, request)) }
            }
        }

        func dispose() {
            bench.stop()
            Store.settings.set(previousBench, forKey: "bench")
            Agents.shared.detach(session.id)
            for tab in browser.everyTab { tab.close() }
            browser.letGo()
        }
    }

    @Test func oneQuestionHidesAPrivateTabAndATabInAHiddenSpace() {
        let w = World(hidden: true); defer { w.dispose() }
        #expect(w.browser.whyHiddenFromAI(w.user) == .space)
        #expect(w.browser.hiddenFromAI(w.user))
        let own = Tab(bench: true)
        let shy = Tab(shy: true)
        defer { own.close(); shy.close() }
        // An agent's own tab is no space's row; a private tab is missing.
        #expect(w.browser.whyHiddenFromAI(own) == nil)
        #expect(w.browser.whyHiddenFromAI(shy) == .privateTab)
        #expect(w.browser.whyHiddenFromAI(nil) == nil)
    }

    @Test func aTabInAnOrdinarySpaceIsNot() {
        let w = World(hidden: false); defer { w.dispose() }
        #expect(!w.browser.hiddenFromAI(w.user))
    }

    @Test(arguments: ["text", "snapshot", "shot", "agent-go"])
    func everyVerbOnAHiddenTabIsRefusedPlainly(verb: String) async {
        let w = World(hidden: true); defer { w.dispose() }
        let got = await w.ask(["do": verb, "id": Bench.short(w.user)])
        #expect(got["error"] as? String == HiddenFromAI.refusal, "\(got)")
    }

    @Test func tabsListsAnOrdinarySpacesTab() async {
        let w = World(hidden: false); defer { w.dispose() }
        let seen = await w.ask(["do": "agent-tabs"])
        #expect("\(seen)".contains(Bench.short(w.user)), "\(seen)")
    }

    @Test func tabsListsAHiddenSpacesTabsNowhere() async {
        let w = World(hidden: true); defer { w.dispose() }
        let seen = await w.ask(["do": "agent-tabs"])
        #expect(!"\(seen)".contains(Bench.short(w.user)), "\(seen)")
    }

    @Test func noNativeActionReachesAHiddenSpace() {
        let w = World(hidden: true); defer { w.dispose() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let control = NativeControl(file: folder.appendingPathComponent("operations.json"))
        var got: [String: Any] = [:]
        control.handle("agent-native-apply", request: ["session": w.session.id, "action": "tabs.close",
                                                       "target": ["kind": "space", "id": w.browser.spaceID.uuidString],
                                                       "arguments": ["tabs": [w.user.id.uuidString]], "requestId": "close-hidden"],
                       browser: w.browser) { got = $0 }
        #expect("\(got)".contains("hidden_from_ai"), "\(got)")
        #expect(w.browser.tabs.contains { $0 === w.user })
    }
}
