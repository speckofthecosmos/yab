import AppKit
import SwiftUI
import WebKit

// A form filled box by box: the box the caret is in shows, pale, what Yab
// would put in it, and Tab takes it and goes on to the next. Nothing hangs
// over the page; ⌥↩ from any of the form's boxes takes them all at once.
// Only your own boxes on a form about you (FormRules.notYours).
//
// What goes in comes from what yab already has, and the frequent path
// needs no model at all: the Wallet's address for its boxes, the Profile
// for a company, a title, a LinkedIn or an X in the shape each box asks,
// and what you answered the same question before (FormAnswers). A
// question only words answer gets a draft from Claude (FormDraft),
// started the moment the list shows, so it is there by the time it is
// taken. Money, bank details, ids, a yes to terms stay yours, and the
// caret goes to the first of them. ⌘Z puts the whole form back, until
// you type in it.

/// What a tab knows of the form the caret is in.
struct FormWatch {
    /// The frame the form is in; nil for the page itself.
    var frame: PageFrame?
    var plan: FormPlan?
    /// When the plan was read, so a list and a fill a moment apart share it.
    var planned = Date.distantPast
    /// Drafts, by the question's plain words.
    var drafts: [String: String] = [:]
    /// Questions asked of Claude and not yet answered: asked once, however
    /// often the list is worked out again meanwhile.
    var drafting: Set<String> = []
    /// Filled and not yet typed in: ⌘Z puts it back.
    var filledAt: Date?
    /// How long the last fill took, from the press to the boxes, for the bench.
    var took: Double?
    /// Filled: the page takes Tab through the boxes left, then to the
    /// button that sends it, until the form is sent or put back, or ten
    /// minutes pass (the page script's `guide`).
    var guided: Date?
    var guiding: Bool { guided.map { Date().timeIntervalSince($0) < 600 } ?? false }
    /// What the box the caret is in shows, pale, for Tab to take; empty
    /// when nothing (the page script's word, for the bench).
    var ghost = ""
    /// The form's box the caret was last said to be in, by its kind and
    /// place across: the caret speaks on every frame of a scroll.
    var box = ""
}

/// The row's words: how many boxes of how many, and what is left to you.
struct FormOffer: Equatable {
    var filling: Int
    var boxes: Int
    var yours: Int
    var drafting: Int
    var ready: Int

    init(_ plan: FormPlan, drafts: [String: String]) {
        filling = plan.filling
        boxes = plan.boxes
        yours = plan.yours
        let asked = plan.drafts
        drafting = asked.count
        ready = asked.filter { drafts[FormAnswers.normal($0.field.label)] != nil }.count
    }

    var detail: String {
        // Short enough for the list's width with ⌥↩ beside it.
        var parts = ["\(filling) of \(boxes)"]
        if yours > 0 { parts.append("\(yours) stay yours") }
        if drafting > 0 { parts.append(ready == drafting ? (drafting == 1 ? "draft ready" : "drafts ready") : "writing \(drafting == 1 ? "a draft" : "drafts")") }
        return parts.joined(separator: " · ")
    }
}

extension FormSource {
    /// Profile keys as the dot's words say them.
    static let keyWords: [String: String] = [
        "name": "Name", "headline": "Headline", "company": "Company", "role": "Title", "location": "Location",
        "linkedin": "LinkedIn", "x": "X", "github": "GitHub", "website": "Website", "telegram": "Telegram",
        "instagram": "Instagram", "bio": "Bio", "about": "About", "working": "Working on", "languages": "Languages",
        "timezone": "Time zone", "pronouns": "Pronouns",
    ]

    /// The dot a box yab filled shows inside its right edge, and the words
    /// under the pointer: green for the Wallet, the accent for the profile and
    /// Claude's drafts, gray for an answer given before. Nil for what
    /// isn't filled.
    /// `writer`: who writes drafts, "Claude" or "ChatGPT" (PlanText.writer).
    func dot(address: StreetAddress? = nil, writer: String = "Claude") -> (color: String, words: String)? {
        switch self {
        case .wallet:
            let line = address?.line1 ?? ""
            return ("green", line.isEmpty ? "Wallet" : "Wallet · \(line)")
        case .profile(let key): return ("accent", "Profile · " + (Self.keyWords[key] ?? key.capitalized))
        case .draft: return ("accent", "Draft · \(writer)")
        case .answer: return ("gray", "As last time")
        default: return nil
        }
    }
}

enum FormFill {
    /// Whole forms are offered (Settings › Passwords, "Fill whole forms").
    static var on: Bool {
        get { Store.settings.object(forKey: "autofill.forms") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "autofill.forms") }
    }

    /// Your card in Contacts was looked at for the profile this launch.
    nonisolated(unsafe) static var triedCard = false

    /// Claude Code or Codex is on this Mac, as last looked.
    @MainActor static var agentsHere: Bool {
        guard let found = Shell.cached else {
            Task { _ = await Shell.find(resolvingLogin: false) }
            return false
        }
        return found.claude != nil || found.codex != nil
    }

    /// Getting to know you is under way.
    @MainActor static var knowing: Bool { Agents.shared.sessions.contains { $0.knowing && $0.state.live } }
}

extension Tab {
    /// Reads the form the caret is in and works out what each box would get.
    func formPlan(learned: (() -> Void)? = nil, _ done: @escaping (FormPlan?) -> Void) {
        guard !gone, !asleep, let web = builtPage else { return done(nil) }
        let frame = wallet.form.frame
        web.call("return window.__yabForm ? window.__yabForm.read() : null",
                                arguments: [:], in: .yab, frame: frame) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case .success(let value) = result, let read = value as? [String: Any],
                      let list = read["fields"] as? [Any] else { return done(nil) }
                let fields = list.compactMap(FormField.init)
                let site = Browser.site(self.address?.host() ?? "")
                let plan = FormRules.plan(fields, profile: Profile.load(), answers: FormAnswers.load(), site: site,
                                          hasAddress: !Wallet.addresses().isEmpty, known: FormModel.known,
                                          about: read["about"] as? String ?? "")
                // Drafts already written for these questions go in with the rest.
                var planned = plan
                for (n, step) in plan.steps.enumerated() where step.source == .draft {
                    planned.steps[n].value = self.wallet.form.drafts[FormAnswers.normal(step.field.label)]
                }
                self.wallet.form.plan = planned
                self.wallet.form.planned = Date()
                done(planned)
                // Labels no dictionary knew, and questions that might be a fact
                // after all ("Where can we find you online?" is a link).
                FormModel.look(fields.filter { field in
                    switch planned.steps.first(where: { $0.field.index == field.index })?.source {
                    case .yours("none"): return true
                    // A box of a line only: a big box is for words.
                    case .draft: return field.tag != "textarea"
                    default: return false
                    }
                }) {
                    // Something new was learned about a label: the list says so.
                    learned?()
                }
            }
        }
    }

    /// Puts the plan into the page: the address, the profile's values,
    /// the answers, the drafts that are written, and the page's own mail
    /// ticks off. Hears how many boxes took something and the steps left
    /// to the person.
    func formFill(_ plan: FormPlan, address: StreetAddress?, done: @escaping (Int, [FormStep]) -> Void) {
        guard !gone, !asleep, let web = builtPage else { return done(0, []) }
        let started = Date()
        var steps: [[String: Any]] = []
        for step in plan.steps {
            switch step.source {
            case .profile, .answer, .draft:
                guard let value = step.value, !value.isEmpty else { continue }
                var one: [String: Any] = ["i": step.field.index, "label": step.field.label, "type": step.field.type, "value": value]
                if let dot = step.source.dot(writer: PlanText.writer) { one["dot"] = ["c": dot.color, "w": dot.words] }
                steps.append(one)
            case .untick:
                steps.append(["i": step.field.index, "label": step.field.label, "type": step.field.type, "untick": true])
            default:
                continue
            }
        }
        let marked = FormSource.wallet.dot(address: address).map { ["c": $0.color, "w": $0.words] }
        let args: [String: Any] = ["steps": steps, "address": plan.address ? (address?.filling ?? [:]) : NSNull(),
                                   "marked": marked ?? [:], "accent": "#" + NSColor.controlAccentColor.hex]
        web.call("return window.__yabForm ? window.__yabForm.fill(steps, address, marked, accent) : 0",
                                arguments: args, in: .yab, frame: wallet.form.frame) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let filled = (try? result.get()) as? Int ?? 0
                self.wallet.form.took = Date().timeIntervalSince(started)
                // Tab is the page's now, to go through what is left: only
                // when something went in, which the page's script then guides.
                if filled > 0 {
                    WrappedLedger.shared.add(.formFields, Double(filled))
                    self.wallet.form.filledAt = Date()
                    self.wallet.form.guided = Date()
                }
                let left = plan.steps.filter { step in
                    if case .yours = step.source { return true }
                    return step.source == .draft && step.value == nil
                }
                done(filled, left)
            }
        }
    }

    /// What each box would take, for the box the caret is in to show, pale,
    /// with Tab to take it (the page script's `hints`): the profile's
    /// values, answers given here before, drafts written, and your own
    /// name, email and company from the Wallet. Never a street's parts,
    /// whose list the address boxes have, nor a menu or a radio.
    func formHints(_ plan: FormPlan) {
        guard let web = builtPage else { return }
        let address = plan.address ? Wallet.preferredAddress() : nil
        var hints: [[String: Any]] = []
        for step in plan.steps where step.field.tag != "select" && step.field.type != "radio" && step.field.type != "checkbox" {
            var value = step.value ?? ""
            if step.source == .wallet, let address {
                let words = address.name.split(separator: " ").map(String.init)
                switch step.field.kind {
                case "name": value = address.name
                case "given": value = words.first ?? ""
                case "family": value = words.dropFirst().joined(separator: " ")
                case "email": value = address.email
                case "org": value = address.organization
                default: continue
                }
            }
            guard step.source.fills, !value.isEmpty else { continue }
            var one: [String: Any] = ["i": step.field.index, "label": step.field.label, "value": value]
            if let dot = step.source.dot(address: address, writer: PlanText.writer) { one["dot"] = ["c": dot.color, "w": dot.words] }
            hints.append(one)
        }
        web.call("return window.__yabForm ? window.__yabForm.hints(steps) : 0",
                                arguments: ["steps": hints], in: .yab, frame: wallet.form.frame) { _ in }
    }

    /// A draft written while the caret is in the form: its box shows it too.
    func formHintArrived(_ step: FormStep, _ text: String) {
        let dot = FormSource.draft.dot(writer: PlanText.writer).map { ["c": $0.color, "w": $0.words] } ?? [:]
        builtPage?.call("return window.__yabForm ? window.__yabForm.hintOne(i, label, v, dot) : false",
                                   arguments: ["i": step.field.index, "label": step.field.label, "v": text, "dot": dot],
                                   in: .yab, frame: wallet.form.frame) { _ in }
    }

    /// A draft that came after the rest, into its box if it is still empty.
    func formDraftArrived(_ step: FormStep, _ text: String) {
        guard let web = builtPage else { return }
        let dot = FormSource.draft.dot(writer: PlanText.writer).map { ["c": $0.color, "w": $0.words] } ?? [:]
        web.call("return window.__yabForm ? window.__yabForm.fillOne(i, label, v, dot) : false",
                                arguments: ["i": step.field.index, "label": step.field.label, "v": text, "dot": dot],
                                in: .yab, frame: wallet.form.frame) { _ in }
    }

    /// The caret into the first box left to the person: a required one first.
    func formFocus(_ step: FormStep) {
        builtPage?.call("return window.__yabForm ? window.__yabForm.focus(i, label) : false",
                                   arguments: ["i": step.field.index, "label": step.field.label],
                                   in: .yab, frame: wallet.form.frame) { _ in }
    }

    /// ⌘Z after a fill: every box back as it was. False when there is
    /// nothing of a fill to put back, and the key is the page's.
    func formUndo() -> Bool {
        guard let at = wallet.form.filledAt, Date().timeIntervalSince(at) < 120, let web = builtPage else { return false }
        wallet.form.filledAt = nil
        wallet.form.guided = nil
        web.call("return window.__yabForm ? window.__yabForm.undo() : 0",
                                arguments: [:], in: .yab, frame: wallet.form.frame) { _ in }
        return true
    }

    /// A form sent with a person's own press: what it held that isn't
    /// kept yet waits for the page to show it went through, then is kept
    /// with nothing asked, for the morning look to go over. Never a private
    /// tab's, never money, a bank account, an id, a secret, a card's or
    /// the address's (FormAnswers.fresh).
    func formAnswered(_ fields: [[String: Any]], _ frame: PageFrame) {
        wallet.form.guided = nil
        guard !shy, FormFill.on, let host = address?.host() else { return }
        var sent: [(field: FormField, answer: String)] = []
        for raw in fields {
            var d = raw
            d["i"] = 0
            guard let field = FormField(d), let answer = raw["value"] as? String else { continue }
            sent.append((field, answer))
        }
        let site = Browser.site(host)
        let fresh = FormAnswers.fresh(sent, book: FormAnswers.load(), profile: Profile.load(), site: site)
        guard !fresh.isEmpty else { return }
        let at = Date()
        wallet.answered = (fresh, site, frame.isMain ? nil : frame, at)
        // Asked a few times, as a payment is: a page may take a while to
        // show the form went through, and one refused keeps its boxes.
        for delay in [1.2, 2.5, 6.0, 12.0, 25.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wallet.answered?.at == at else { return }
                self.answersSettle()
            }
        }
    }

    /// The answers sent went through when their boxes are gone from the
    /// page, or no longer hold them: a new page, the form swapped for a
    /// "You're in", or emptied. Still there, the page refused it, and a
    /// second press sends them again.
    func answersSettle() {
        guard let pending = wallet.answered else { return }
        guard Date().timeIntervalSince(pending.at) < 120 else {
            wallet.answered = nil
            return
        }
        let finish = { [weak self] in
            guard let self, let pending = self.wallet.answered else { return }
            self.wallet.answered = nil
            guard !self.shy, FormFill.on else { return }
            FormAnswers.keep(pending.fresh.map { (question: $0.label, answer: $0.answer) }, site: pending.site, fresh: true)
        }
        guard let web = builtPage else { return }
        web.call("return window.__yabForm ? window.__yabForm.holds(values) : 0",
                                arguments: ["values": pending.fresh.map(\.answer)], in: .yab, frame: pending.frame) { result in
            MainActor.assumeIsolated {
                // A frame that has gone answers with an error: its boxes went with it.
                let held = (try? result.get()) as? Int ?? 0
                if held * 2 < max(1, pending.fresh.count) { finish() }
            }
        }
    }
}

extension Browser {
    /// The caret came into a form's box: work out what the form would get,
    /// and if it is worth it, put "Fill the form" on top of the list. Drafts
    /// start now, so they are written by the time the row is taken.
    func offerForm(_ tab: Tab, _ field: WalletField, addresses: [StreetAddress]) {
        guard FormFill.on, !tab.shy, !tab.wallet.declined(on: tab.address) else { return }
        // An empty profile takes what is at hand first: your contact card,
        // then, once, what memory already knows (docs/forms.md).
        if Profile.load().isEmpty, !FormFill.triedCard {
            FormFill.triedCard = true
            MeCard.fillProfile { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                self.offerForm(tab, field, addresses: addresses)
            }
            return
        }
        // Thin counts as empty: a card with only a name and a city filled
        // it first, and memory, asked only of an empty profile, never was.
        if Profile.load().thin, !Memory.empty, !Store.settings.bool(forKey: "profile.fromMemory"), FormFill.agentsHere {
            Store.settings.set(true, forKey: "profile.fromMemory")
            Agents.shared.profileFromMemory()
        }
        let beat = tab.wallet.beat
        tab.formPlan(learned: { [weak self, weak tab] in
            guard let self, let tab, tab.wallet.beat == beat, self.walletList?.tab == tab.id || self.walletList == nil else { return }
            self.offerForm(tab, field, addresses: addresses)
        }) { [weak self, weak tab] plan in
            guard let self, let tab, tab.wallet.beat == beat, self.offersAutofill(tab), !tab.wallet.declined(on: tab.address) else { return }
            // No row over the page: the box the caret is in shows what it
            // would take, and Tab takes it (docs/forms.md).
            if let plan {
                tab.formHints(plan)
                self.draftForm(tab, plan)
            }
            if addresses.isEmpty {
                if self.walletList?.tab == tab.id { self.walletList = nil }
                return
            }
            var list = WalletChoices(tab: tab.id, spot: field.spot, group: .address, cards: [],
                                     addresses: addresses, origin: Tab.originOf(tab.address), form: nil, dark: field.dark)
            list.box = field.box
            if self.walletList != list { self.walletList = list }
        }
    }

    /// A page finished loading: if it holds a form with a question only
    /// words answer, Claude Code is started now rather than when the caret
    /// comes in, so the first draft doesn't wait out its start (FormDraft).
    /// Looked at twice, as the page lands and once its script has drawn
    /// the form. Nothing of the page goes anywhere.
    func warmDrafts(_ tab: Tab) {
        // Not an agent's own tab: it writes its drafts itself, and reading
        // the form of every page it opens is work for nothing.
        guard FormFill.on, FormDraft.on, !tab.hiddenFromAI, tab.agent == nil, FormDraft.shared.usable, !FormDraft.shared.running else { return }
        guard let found = Shell.cached else {
            Task { _ = await Shell.find(resolvingLogin: false) }
            return
        }
        guard found.claude != nil else { return }
        let page = tab.address
        for delay in [0.4, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak tab] in
                guard let tab, tab.address == page, !tab.gone, !tab.asleep, !FormDraft.shared.running, let web = tab.builtPage else { return }
                let look = "return document.querySelectorAll('textarea, input:not([type=hidden])').length >= 3 && window.__yabForm ? window.__yabForm.read() : null"
                web.call(look, in: .yab, gesture: false) { [weak tab] result in
                    MainActor.assumeIsolated {
                        guard let tab, case .success(let value) = result, let read = value as? [String: Any],
                              let list = read["fields"] as? [Any] else { return }
                        let fields = list.compactMap(FormField.init)
                        guard fields.filter({ $0.type != "checkbox" }).count >= 3 else { return }
                        let plan = FormRules.plan(fields, profile: Profile.load(), answers: FormAnswers.load(),
                                                  site: Browser.site(tab.address?.host() ?? ""), hasAddress: true, known: FormModel.known,
                                                  about: read["about"] as? String ?? "")
                        if !plan.drafts.isEmpty { FormDraft.shared.warm() }
                    }
                }
            }
        }
    }

    /// Drafts for the form's questions, into the plan as they come, and
    /// into the page when the form was already filled.
    func draftForm(_ tab: Tab, _ plan: FormPlan) {
        let asked = plan.drafts.filter {
            let key = FormAnswers.normal($0.field.label)
            return tab.wallet.form.drafts[key] == nil && !tab.wallet.form.drafting.contains(key)
        }
        guard !asked.isEmpty, FormDraft.on, AIUse.allows(.background, for: tab) else { return }
        let keys = Set(asked.map { FormAnswers.normal($0.field.label) })
        tab.wallet.form.drafting.formUnion(keys)
        tab.builtPage?.call("return window.__yabForm ? window.__yabForm.context() : null",
                                       arguments: [:], in: .yab, frame: tab.wallet.form.frame) { [weak tab] result in
            MainActor.assumeIsolated {
                guard let tab else { return }
                let context = ((try? result.get()) as? [String: Any]) ?? [:]
                FormDraft.shared.write(asked, profile: Profile.load(), context: context, site: Browser.site(tab.address?.host() ?? "")) { [weak self, weak tab] texts in
                    guard let self, let tab else { return }
                    tab.wallet.form.drafting.subtract(keys)
                    // No drafts to be had: those boxes are the person's, and the row says so.
                    if texts.isEmpty {
                        for step in asked {
                            if let n = tab.wallet.form.plan?.steps.firstIndex(where: { $0.field.index == step.field.index && $0.source == .draft }) {
                                tab.wallet.form.plan?.steps[n].source = .yours("words")
                            }
                        }
                    }
                    for (step, text) in zip(asked, texts) where !text.isEmpty {
                        let key = FormAnswers.normal(step.field.label)
                        tab.wallet.form.drafts[key] = text
                        if let n = tab.wallet.form.plan?.steps.firstIndex(where: { $0.field.index == step.field.index && $0.source == .draft }) {
                            tab.wallet.form.plan?.steps[n].value = text
                        }
                        // Filled already: the draft goes straight into its box;
                        // otherwise its box shows it, for Tab to take.
                        if tab.wallet.form.filledAt != nil { tab.formDraftArrived(step, text) } else { tab.formHintArrived(step, text) }
                    }
                    // The row says the drafts are ready.
                    if var list = self.walletList, list.tab == tab.id, let plan = tab.wallet.form.plan, list.form != nil {
                        list.form = FormOffer(plan, drafts: tab.wallet.form.drafts)
                        self.walletList = list
                    }
                }
            }
        }
    }

    /// "Fill your profile first": an agent gets to know you, memory, the
    /// profile and your addresses, in tabs of its own.
    func getToKnowMe() {
        walletLowering?.cancel()
        walletList = nil
        ContextConsent.request()
    }

    /// "Fill the form", from the list or ⌥↩: everything yab has, at once.
    func fillForm() {
        walletLowering?.cancel()
        guard let list = walletList, list.form != nil, let tab = autofillTab(list.tab) else { return }
        walletList = nil
        guard Tab.originOf(tab.address) == list.origin else { return }
        fillForm(tab)
    }

    func fillForm(_ tab: Tab, done: ((Int, [FormStep]) -> Void)? = nil) {
        let site = Browser.site(tab.address?.host() ?? "")
        let go: (FormPlan) -> Void = { [weak tab] plan in
            guard let tab else { return }
            let address = plan.address ? Wallet.preferredAddress() : nil
            tab.formFill(plan, address: address) { [weak tab] filled, left in
                if filled > 0, let address {
                    DispatchQueue.global(qos: .utility).async { Wallet.touch(address: address.id, on: site) }
                }
                // The caret to the first box that is yours to fill, a required one first.
                let gaps = left.filter { $0.field.type != "checkbox" }
                if let first = gaps.first(where: { $0.field.required }) ?? gaps.first { tab?.formFocus(first) }
                // Drafts still being written go in as they come.
                done?(filled, left)
            }
        }
        // The plan read for the list, if it is fresh; otherwise read now.
        if let plan = tab.wallet.form.plan, Date().timeIntervalSince(tab.wallet.form.planned) < 30 {
            go(plan)
        } else {
            tab.formPlan { plan in if let plan { go(plan) } else { done?(0, []) } }
        }
    }

    /// ⌥↩ in a box of a form: the list's row if it is up, or the form the
    /// caret is in, if yab would fill enough of it. False leaves the key
    /// to the page.
    func fillFormHere() -> Bool {
        if walletList?.form != nil {
            fillForm()
            return true
        }
        guard FormFill.on, let tab = active, !tab.shy, tab.typing, let plan = tab.wallet.form.plan,
              Date().timeIntervalSince(tab.wallet.form.planned) < 600, plan.filling >= 2 else { return false }
        fillForm(tab)
        return true
    }

    /// ⌘Z: the last fill put back, while nothing has been typed since.
    func undoFormFill() -> Bool {
        guard let tab = active else { return false }
        return tab.formUndo()
    }
}

// MARK: - the rows

/// Under Fill the form while there is nothing about you: an agent gets to
/// know you once, and every form after takes it.
struct KnowMeRow: View {
    let lit: Bool
    var point: (() -> Void)? = nil
    let pick: () -> Void

    var body: some View {
        FieldListRow(title: "Fill your profile first", detail: "An agent looks you up where you're signed in", used: nil, lit: lit, point: point, pick: pick) {
            FieldListWell(glyph: "person.text.rectangle")
        }
    }
}

/// "Fill the form" on top of the list: a well with the spark, the words,
/// and ⌥↩ where a row says its key.
struct FormFillRow: View {
    let offer: FormOffer
    let lit: Bool
    var point: (() -> Void)? = nil
    let pick: () -> Void
    @ObservedObject private var fillKey = Keymap.shared.slot(.fillForm)

    var body: some View {
        FieldListRow(title: "Fill the form", detail: offer.detail, used: nil, lit: lit, keys: fillKey.keys?.text ?? "", point: point, pick: pick) {
            FieldListWell(glyph: "spark")
        }
    }
}
