import AppKit
import SwiftUI
import SyncKit

// Settings › Spaces: turned on and off in the toolbar, as a feature is.
// The page is the list, in the order ⌃1 to ⌃9 follow, a space's place
// changed by its grip; a row opens that space's own page. Add Space opens
// the same page for one not made yet: nothing is made until Create Space,
// so going back leaves no empty space behind.

/// Spaces off: not a form but a way in, in the middle of the pane, as
/// Extensions is before there is one. What they are, a few of them drawn,
/// and the one button; the toolbar's switch does the same.
struct SpacesArrival: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @Environment(\.colorScheme) private var scheme

    /// Kept from before, or three to show what they are.
    private var shown: [(icon: String, name: String, color: NSColor)] {
        let dark = scheme == .dark
        if browser.spaces.count > 1 {
            return browser.spaces.prefix(4).map { ($0.icon, $0.name, ($0.paint ?? SpacePaint(prefs)).color(dark: dark)) }
        }
        return [("🏠", "Personal", Swatch.lavender.color(dark: dark, custom: prefs.backdropColor)),
                ("💼", "Work", Swatch.sky.color(dark: dark, custom: prefs.backdropColor)),
                ("✈️", "Travel", Swatch.sage.color(dark: dark, custom: prefs.backdropColor))]
    }

    var body: some View {
        ArrivalPage(page: .spaces, title: "Spaces",
                    blurb: browser.spaces.count > 1
                           ? "Your \(browser.spaces.count) spaces are kept, with their tabs, for when they are on again."
                           : "Sets of tabs in the one window, work and home say, each with its pins, its color and, if you want, sign-ins of its own.") {
            HStack(spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, space in
                    HStack(spacing: 6) {
                        SpaceMark(icon: space.icon, size: 11).fixedSize()
                        Text(space.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Door.side)
                    .background(Color(nsColor: space.color), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .environment(\.colorScheme, Tone(space.color, lifted: true).scheme)
                }
            }
            .padding(.top, 16)
            .accessibilityHidden(true)
            Button("Turn On Spaces") { prefs.usesSpaces = true }
                .settingsButton(.primary)
                .padding(.top, 20)
            SettingsText(browser.spaces.count > 1
                 ? "⌃1 to ⌃9 switch, and the name beside the tabs opens them all."
                 : "Your tabs now become the first space. ⌃1 to ⌃9 switch, and the name beside the tabs opens them all.", size: 11)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
                .padding(.top, 12)
        }
    }
}

/// The opened place of a space not made yet.
enum SpacePlace {
    static let new = "+space"
}

struct SpacesPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let opened = model.opened {
            // Its own state for each space's page, never the last one's.
            SpacePage(browser: browser, prefs: prefs, model: model, id: UUID(uuidString: opened))
                .id(opened)
        } else {
            PageHero(page: .spaces)
                .settingsAnchor("spaces")
            if prefs.usesSpaces {
                // One cell, its own hairlines drawn as the form draws its
                // own: a row in the hand moves over the others, and the
                // form's cells would clip it.
                Section {
                    SpaceList(browser: browser, model: model)
                        // The form's inset round a cell traded for the
                        // list's own air (a grouped form on macOS ignores
                        // listRowInsets).
                        .padding(.vertical, SettingsList.air - 10) // design: the form's own inset round a cell, traded for the list's air
                        .settingsAnchor("space-list")
                }
                .task { BrowserLookFinder.shared.load() }
                // Another browser's looks for the spaces brought from it:
                // with spaces, Appearance sets no look, it sends you here.
                if browser.spaces.count > 1 {
                    SpacesBrowserLook(browser: browser, prefs: prefs)
                }
                // One row of pins every space shares, as Arc's Favorites,
                // or a row in each (docs/shared-pins.md).
                Section {
                    SettingsRow("Pins", detail: "Spaces with separate sign-ins have separate pins.") {
                        MenuCell(title: "Pins", options: [("In Every Space", true), ("In Each Space", false)], selection: $prefs.pinsEverySpace, trailing: true)
                    }
                    .settingsAnchor("pins")
                }
                if browser.spaces.count > 1 {
                    LinkRouteSettings(browser: browser)
                }
            }
        }
    }
}

/// "From Arc · Match Arc" in a group of its own, only once there is
/// another browser's look to match, and only until it is matched.
private struct SpacesBrowserLook: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject private var finder = BrowserLookFinder.shared
    @AppStorage("browserLookMatched", store: Store.settings) private var matched = false

    var body: some View {
        if finder.found != nil, !matched {
            Section { BrowserLook(browser: browser, prefs: prefs) }
        }
    }
}

// MARK: - the list

/// Every space, a row each: its grip, its emoji on its color, its name,
/// how many tabs, its key.
private struct SpaceList: View {
    @ObservedObject var browser: Browser
    @ObservedObject var model: SettingsModel

    /// The row in the hand, and how far it has come.
    @State private var lifted: UUID?
    @State private var lift: CGFloat = 0

    static let row = SettingsList.row
    private var pitch: CGFloat { Self.row }

    var body: some View {
        let list = browser.spaces
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, space in
                SpaceListRow(space: space, index: index, place: browser.turnOrder.firstIndex { $0.id == space.id } ?? index,
                             tabs: browser.pageCount(in: space.id),
                             profile: list.count > 1 ? profileNote(space, in: list) : nil,
                             paint: space.paint ?? SpacePaint(browser.prefs),
                             lifted: lifted == space.id, made: model.madeSpace == space.id, rule: index > 0 && lifted != space.id,
                             grip: list.count > 1 ? reorder(space, list: list) : nil) {
                    model.open(space: space.id.uuidString)
                }
                .offset(y: shift(index, list))
                .zIndex(lifted == space.id ? 1 : 0)
                // The others make way while a row is in the hand; let go,
                // the new order stands at once, as in the tray.
                .animation(lifted == nil || lifted == space.id ? nil : Motion.settle, value: shift(index, list))
            }
            AddSpaceRow { model.open(space: SpacePlace.new) }
                // From the mark on, as the rows' hairlines.
                .overlay(alignment: .top) { Divider().padding(.leading, 22).offset(y: -0.5) } // design: the grip's 14 and the row's gap of 8
                .settingsAnchor("add-space")
        }
    }

    private func profileNote(_ space: Space, in list: [Space]) -> (title: String, linked: Bool) {
        let store = space.profileID
        if let peer = list.first(where: { $0.id != space.id && $0.profileID == store }) {
            return ("Same sign-ins as \(peer.name)", true)
        }
        return ("Its own sign-ins", false)
    }

    /// Where the row in the hand would land.
    private func landing(_ from: Int, _ count: Int) -> Int {
        min(count - 1, max(0, from + Int((lift / pitch).rounded())))
    }

    private func shift(_ index: Int, _ list: [Space]) -> CGFloat {
        guard let lifted, let from = list.firstIndex(where: { $0.id == lifted }) else { return 0 }
        if index == from { return lift }
        let to = landing(from, list.count)
        if from < to, index > from, index <= to { return -pitch }
        if from > to, index < from, index >= to { return pitch }
        return 0
    }

    private func reorder(_ space: Space, list: [Space]) -> AnyGesture<Void> {
        AnyGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { drag in
                if lifted != space.id { NSCursor.closedHand.push() }
                lifted = space.id
                lift = drag.translation.height
            }
            .onEnded { _ in
                NSCursor.pop()
                guard lifted == space.id, let from = list.firstIndex(where: { $0.id == space.id }) else { return }
                let to = landing(from, list.count)
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    browser.moveSpace(space.id, to: to)
                    lifted = nil
                    lift = 0
                }
            }
            .map { _ in () })
    }
}

private struct SpaceListRow: View {
    let space: Space
    let index: Int
    /// Its place among them all, Mail's included: what ⌃1 to ⌃9 count.
    let place: Int
    let tabs: Int
    let profile: (title: String, linked: Bool)?
    let paint: SpacePaint
    let lifted: Bool
    /// Just made: washed as a row the search picked out is.
    let made: Bool
    /// The hairline over it: not over the first, nor while it is in the hand.
    let rule: Bool
    /// Its place changed by dragging this; nil while it is the only one.
    let grip: AnyGesture<Void>?
    let open: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = paint.color(dark: scheme == .dark)
        HStack(spacing: 8) {
            handle
            SpaceMark(icon: space.icon, size: 11)
                .frame(width: 22, height: 22)
                .background(Color(nsColor: color), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(space.name).lineLimit(1)
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let profile {
                    HStack(spacing: 4) {
                        if profile.linked { Image(systemName: "link") }
                        Text(profile.title)
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if place < 9 {
                if let action = Shortcut.numbered("space", place + 1) {
                    ShortcutGlyphs(action, size: 11, tint: .secondary)
                }
            }
            SettingsChevron()
        }
        .frame(height: SpaceList.row)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .background {
            // As SettingsAnchor washes a row the search picked out.
            RoundedRectangle(cornerRadius: 7, style: .continuous) // design: SettingsAnchor's wash, seven round inside the card's ten
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                .padding(.horizontal, -7) // design: SettingsAnchor's wash, out to the row's edges less three
                .opacity(made ? 1 : 0)
                .animation(.easeOut(duration: made ? 0.12 : 0.5), value: made)
        }
        .background {
            if lifted {
                let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                shape.fill(Color(nsColor: .controlBackgroundColor)) // design: a row lifted in the hand, as the tray's is, not a card
                    .castShadow(shape, color: .black.opacity(0.14), radius: 8, y: 3)
                    .padding(.horizontal, -6)
            }
        }
        .overlay(alignment: .top) {
            // From the mark on, not under the grip.
            if rule { Divider().padding(.leading, 22).offset(y: -0.5) } // design: the grip's 14 and the row's gap of 8
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(space.name)
        .accessibilityHint("Opens \(space.name)")
        .accessibilityAddTraits(.isButton)
    }

    private var detail: String {
        let words = tabs == 0 ? "No tabs" : tabs == 1 ? "1 tab" : "\(tabs) tabs"
        return words
    }

    /// Two columns of dots, the pointer an open hand over them.
    @ViewBuilder
    private var handle: some View {
        let dots = Symbol("circle.grid.2x3", size: 11)
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: SpaceList.row)
            .contentShape(Rectangle())
        if let grip {
            dots
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .highPriorityGesture(grip)
                .keyTip("Drag to change its place")
        } else {
            dots.hidden()
        }
    }
}

/// The way to a new one, under the last.
private struct AddSpaceRow: View {
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 14)
                Symbol("plus", size: 11)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                Text(SettingsWords.text("Add Space"))
                Spacer(minLength: 0)
            }
            .frame(height: SpaceList.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - one space

/// What a space's page edits: kept here while the page is up, written
/// through at once for a space that is there, all at Create for a new one.
@MainActor
private final class SpaceForm: ObservableObject {
    /// The space it edits, nil for a new one: every change goes to this
    /// one, whatever page SwiftUI thinks it is on as the pages change.
    let id: UUID?
    @Published var name: String
    @Published var icon: String
    @Published var swatch: Swatch
    @Published var custom: NSColor
    @Published var transparency: Double
    @Published var grain: Double
    @Published var colors: [String]
    /// What the look card adds: Shift with tabs, the site's color, drawings.
    @Published var shift: Bool
    @Published var site: Bool
    @Published var drawings: String
    @Published var strength: Double
    /// The space's own light or dark, and glass past the wave's end.
    @Published var mode: String
    @Published var glass: Bool
    @Published var profile: UUID?
    @Published var search: String?
    @Published var searchCustom: String?
    @Published var downloadFolder: URL?
    /// Picked by hand, so the name's guess leaves it alone.
    var iconByHand = false
    var swatchByHand = false
    /// The first emoji no space wears yet, for a new one whose name
    /// suggests none.
    var free = "🌱"

    init(_ space: Space, paint: SpacePaint) {
        id = space.id
        name = space.name
        icon = space.icon
        swatch = paint.picked
        custom = paint.own
        transparency = paint.transparency
        grain = paint.grain
        colors = paint.colors
        shift = paint.shift
        site = paint.site
        drawings = paint.drawings
        strength = paint.drawingsStrength
        mode = paint.mode
        glass = paint.glass
        profile = nil
        search = space.search
        searchCustom = space.searchCustom
        downloadFolder = DownloadFolder.custom(for: space.id)
        iconByHand = true
        swatchByHand = true
    }

    /// A new one: the first emoji and color no space wears yet.
    init(new browser: Browser) {
        let worn = SpacePaint(browser.prefs)
        let taken = Set(browser.spaces.compactMap { $0.paint?.picked })
        id = nil
        name = ""
        free = browser.freeIcon
        icon = free
        swatch = Swatch.presets.first { !taken.contains($0) } ?? worn.picked
        custom = worn.own
        transparency = worn.transparency
        grain = worn.grain
        colors = worn.colors
        shift = worn.shift
        site = worn.site
        drawings = worn.drawings
        strength = worn.drawingsStrength
        mode = ""
        glass = worn.glass
        profile = browser.spaces.first?.id
    }

    /// The whole look, the card's switches and drawings too: a color
    /// changed here no longer takes them off the space.
    var paint: SpacePaint {
        get {
            SpacePaint(swatch: swatch, color: custom, grain: grain, colors: colors, transparency: transparency,
                       shift: shift, site: site, drawings: drawings, drawingsStrength: strength, mode: mode, glass: glass)
        }
        set {
            if swatch != newValue.picked { swatch = newValue.picked; swatchByHand = true }
            if custom.hex != newValue.color { custom = newValue.own }
            transparency = newValue.transparency
            grain = newValue.grain
            colors = newValue.colors
            shift = newValue.shift
            site = newValue.site
            drawings = newValue.drawings
            strength = newValue.drawingsStrength
            mode = newValue.mode
            glass = newValue.glass
        }
    }

    /// A name typed: the emoji and color follow it, as in the tray, until
    /// either is picked by hand.
    func heard() {
        let guess = SpaceDraft.guess(name)
        guard !name.isEmpty else { return }
        if !iconByHand { icon = guess.icon ?? free }
        if !swatchByHand { swatch = guess.swatch }
    }
}

private struct SpacePage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: SettingsModel
    /// Nil for a new one.
    let id: UUID?

    @StateObject private var form: SpaceForm
    @FocusState private var naming: Bool
    @State private var picking = false
    @Environment(\.colorScheme) private var scheme

    init(browser: Browser, prefs: Preferences, model: SettingsModel, id: UUID?) {
        self.browser = browser
        self.prefs = prefs
        self.model = model
        self.id = id
        let space = id.flatMap { id in browser.spaces.first { $0.id == id } }
        _form = StateObject(wrappedValue: space.map { SpaceForm($0, paint: $0.paint ?? SpacePaint(browser.prefs)) } ?? SpaceForm(new: browser))
    }

    private var space: Space? { form.id.flatMap { id in browser.spaces.first { $0.id == id } } }
    private var index: Int { form.id.flatMap { id in browser.spaces.firstIndex { $0.id == id } } ?? browser.spaces.count }
    private var fresh: Bool { form.id == nil }
    private var shownName: String { form.name.isEmpty ? placeholder : form.name }
    private var placeholder: String { space?.name ?? "Space \(browser.spaces.count + 1)" }

    var body: some View {
        if !fresh, space == nil {
            // Deleted from the tray while its page was up.
            Section { SettingsNote("This space is gone.") }
        } else {
            hero
            Section {
                SettingsRow("Name") {
                    TextField(SettingsWords.text("Name"), text: $form.name, prompt: Text(placeholder))
                        .labelsHidden()
                        .frame(width: 180)
                        .focused($naming)
                        .onSubmit { if fresh { create() } }
                        // A space that is there takes its name as it is typed.
                        .onChange(of: form.name) { _, _ in if fresh { form.heard() } else { rename() } }
                }
                .settingsAnchor("space-name")
                SettingsRow("Icon") {
                    Button { picking.toggle() } label: {
                        SpaceMark(icon: form.icon, size: 14)
                            .frame(width: 30, height: 30)
                            .background(Color(nsColor: form.paint.color(dark: scheme == .dark)),
                                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityIdentifier("space-icon-well")
                    .keyTip("Choose an emoji")
                    .popover(isPresented: $picking, arrowEdge: .bottom) {
                        // Change Icon's picker, as a tab's: every emoji
                        // searched, this space's offered ones first.
                        IconPicker(mark: form.icon, space: offered, pick: { mark in
                            guard let mark else { return }
                            form.icon = mark
                            form.iconByHand = true
                            picking = false
                            if let id = form.id { browser.setSpaceIcon(id, to: mark) }
                        }, close: { picking = false })
                    }
                }
                .settingsAnchor("space-emoji")
            }
            Section {
                SettingsRow("Look", detail: "Customize this space's color and texture.") {
                    dots
                }
                .settingsAnchor("space-color")
            }
            SpaceSearchRows(browser: browser, prefs: prefs, space: space, form: form)
            Section {
                SettingsRow("Sign-ins", detail: profilePeer.map { "Shares sign-ins, extensions and history with \($0.name)." }
                            ?? "Separate sign-ins, cookies and extensions. Starts signed out of all sites.") {
                    DropMenu("Sign-ins", options: profileOptions, selection: Binding(
                        get: { profilePeer?.id.uuidString ?? "own" },
                        set: { chooseProfile(UUID(uuidString: $0)) }
                    ), trailing: true, faceTitle: profilePeer.map { "Same as \($0.name)" } ?? "Its own", showsCheck: true)
                    .fixedSize()
                }
                .settingsAnchor("space-sign-ins")
            }
            if let space {
                // This Mac's choices (SpacePrivacy), each on its own.
                Section {
                    privacyRow("Hide from AI", .hiddenFromAI, of: space).settingsAnchor("space-hide-from-ai")
                } header: {
                    Text(SettingsWords.text("Privacy"))
                }
            }
            Section {
                SettingsRow("Save downloads to", detail: "For this Space on this Mac.") {
                    DropMenu("Save downloads to", options: downloadChoices, selection: Binding(
                        get: { form.downloadFolder == nil ? "default" : "custom" },
                        set: { value in
                            if value == "default" { setDownloadFolder(nil) }
                            else if value == "choose" { chooseDownloadFolder() }
                        }
                    )).fixedSize()
                }
                .settingsAnchor("space-downloads")
                HStack {
                    Text((form.downloadFolder ?? prefs.downloads).path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                         + (form.downloadFolder == nil ? " · from General" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if form.downloadFolder != nil {
                        Button(SettingsWords.text("Change…")) { chooseDownloadFolder() }.settingsButton()
                    }
                }
            }
            if fresh {
                // On the page, not in a group: what is done with the rows.
                Section {} footer: {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(SettingsWords.text("Cancel")) { model.leaveSpace(SpacePlace.new) }
                            .settingsButton()
                            .keyboardShortcut(.cancelAction)
                            .benchSpot("space-create-cancel")
                        Button("Create Space") { create() }
                            .settingsButton(.primary)
                            .keyboardShortcut(.defaultAction)
                            .benchSpot("space-create-confirm")
                    }
                }
            } else if let space, browser.canDeleteSpace(space.id) {
                Section {
                    SettingsRow("Delete Space", detail: deleteNote(space)) {
                        // The red of what cannot be undone, on the wash, as
                        // an extension's Remove… is.
                        Button("Delete…") { delete(space) }
                            .buttonStyle(.yab(.secondary, .regular, tint: ButtonCSS.danger))
                    }
                    .settingsAnchor("space-delete")
                }
            }
        }
    }

    // MARK: the top

    private func privacyRow(_ title: String, _ choice: SpacePrivacy, of space: Space) -> some View {
        SettingsRow(title) {
            Toggle(SettingsText.plain(SettingsWords.text(title)), isOn: Binding(
                get: { space.has(choice) },
                set: { browser.setPrivacy(space.id, choice, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var hero: some View {
        let color = form.paint.color(dark: scheme == .dark)
        let tabs = form.id.map { browser.pageCount(in: $0) } ?? 0
        let words = [
            fresh ? "No tabs yet" : tabs == 0 ? "No tabs" : tabs == 1 ? "1 tab" : "\(tabs) tabs",
            index < 9 ? "⌃\(index + 1)" : nil,
            space?.id == browser.spaceID ? "on screen" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        return Section {} header: {
            VStack(spacing: 0) {
                SpaceMark(icon: form.icon, size: 26)
                    .frame(width: 56, height: 56)
                    .background {
                        BackdropFill(color: Color(nsColor: color), grain: form.grain, transparency: form.paint.wornTransparency(dark: scheme == .dark), colors: form.paint.gradient(dark: scheme == .dark))
                            .clipShape(RoundedRectangle(cornerRadius: 56 * 0.26, style: .continuous)) // design: a feature tile's corner, as FeatureTile rounds it
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 56 * 0.26, style: .continuous) // design: a feature tile's corner, as FeatureTile rounds it
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .padding(.bottom, 12)
                Text(shownName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(form.name.isEmpty && fresh ? .secondary : .primary)
                    .lineLimit(1)
                SettingsText(words, size: 13)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5) // design: PageHero's gap under the name
            }
            .textCase(nil)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 18) // design: PageHero's air above the first group
            .accessibilityElement(children: .combine)
        }
        .onAppear { if fresh { DispatchQueue.main.async { naming = true } } }
    }

    // MARK: color

    /// The space's look: a dot of its color that opens the look card's
    /// controls, as Appearance's row and the card over the window have them.
    private var dots: some View {
        LookPicker(paint: Binding(get: { form.paint }, set: { form.paint = $0; paint() }),
                   named: Spaces.isEmoji(form.icon) ? "\(form.icon) \(shownName)" : shownName,
                   forAll: browser.spaces.count > 1 && !fresh ? { browser.spaces.forEach { browser.setSpacePaint($0.id, to: form.paint) } } : nil) {
            if !form.colors.isEmpty { prefs.backdrop = .color }
        }
    }


    // MARK: what it does

    private var offered: [String] {
        var seen = Set<String>()
        let guess = SpaceDraft.guess(form.name)
        return ([form.icon] + guess.more + Spaces.icons + SpaceDraft.all).filter { seen.insert($0).inserted }.prefix(42).map { $0 }
    }

    private func paint() {
        guard let id = form.id else { return }
        browser.setSpacePaint(id, to: form.paint)
    }

    private func rename() {
        guard let id = form.id else { return }
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != browser.spaces.first(where: { $0.id == id })?.name { browser.renameSpace(id, to: name) }
    }

    private var downloadChoices: [(title: String, value: String)] {
        [("Default location", "default")]
            + (form.downloadFolder.map { [(title: $0.lastPathComponent, value: "custom")] } ?? [])
            + [("Choose folder…", "choose")]
    }

    private func setDownloadFolder(_ folder: URL?) {
        form.downloadFolder = folder
        if let id = form.id { DownloadFolder.set(folder, for: id) }
    }

    private func chooseDownloadFolder() {
        DownloadFolder.chooseFolder(starting: form.downloadFolder ?? prefs.downloads) { folder in setDownloadFolder(folder) }
    }

    private func create() {
        let name = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = profilePeer?.id
        let made = browser.addSpace(named: name.isEmpty ? placeholder : name, icon: form.icon, ownSignIns: profile == nil, paint: form.paint, show: false)
        browser.setSpaceProfile(made, with: profile)
        browser.setSpaceSearch(made, to: form.search, custom: form.searchCustom)
        DownloadFolder.set(form.downloadFolder, for: made)
        model.leaveSpace(SpacePlace.new)
        model.madeSpace = made
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak model] in
            if model?.madeSpace == made { model?.madeSpace = nil }
        }
    }

    private func deleteNote(_ space: Space) -> String {
        let goes = SpaceTray.goesWith(space, browser: browser)
        let routed = LinkRoutes.shared.count(to: space.id)
        let links = routed == 0 ? "" : routed == 1
            ? "Links to its site will open in the space on screen."
            : "Links to its \(routed) sites will open in the space on screen."
        return [goes.isEmpty ? "It has no tabs to close." : goes, links].filter { !$0.isEmpty }.joined(separator: " ")
    }


    /// Changing whose sign-ins it has signs it in or out of everything and
    /// opens its tabs again: asked first.
    private var profileOptions: [DropOption<String>] {
        var options = [DropOption(title: "Its own", value: "own")]
        for peer in browser.spaces where peer.id != form.id {
            let picture = ImageRenderer(content: SpaceMark(icon: peer.icon, size: 12)).nsImage
            picture?.isTemplate = !Spaces.isEmoji(peer.icon)
            options.append(DropOption(title: peer.name, value: peer.id.uuidString,
                picture: picture,
                head: options.count == 1 ? "Same sign-ins as" : nil))
        }
        return options
    }

    private var profilePeer: Space? {
        if fresh { return browser.spaces.first { $0.id == form.profile } }
        guard let space else { return nil }
        let peers = browser.spaces.filter { $0.id != space.id && $0.profileID == space.profileID }
        return peers.first { $0.id == form.profile } ?? peers.first
    }

    private func chooseProfile(_ peer: UUID?) {
        if fresh { form.profile = peer; return }
        guard let space else { return }
        let previous = space.profileID
        let target = peer.flatMap { id in browser.spaces.first { $0.id == id } }
        Task { @MainActor in
            let question = Question(title: "Change sign-ins for \(space.name)?",
                detail: "Tabs, pins and look stay. Sign-ins, extensions and history switch" + (target.map { " to those of \($0.name)." } ?? " to its own."),
                glyph: "person.key", space: space.well(browser.prefs), yes: "Change Sign-ins", place: .settings)
            guard await Questions.shared.ask(question) else { return }
            guard browser.spaces.first(where: { $0.id == space.id })?.profileID == previous,
                  peer == nil || browser.spaces.first(where: { $0.id == peer })?.profileID == target?.profileID else { return }
            browser.setSpaceProfile(space.id, with: peer)
            form.profile = peer
        }
    }

    private func delete(_ space: Space) {
        Task { @MainActor in
            guard await Questions.shared.ask(SpaceTray.deletion(space, browser: browser, place: .settings)) else { return }
            model.leaveSpace(space.id.uuidString)
            browser.deleteSpace(space.id, on: SettingsWindow.shared.toaster, undoable: true)
        }
    }
}

extension SpaceDraft {
    /// The Icon tab's symbols the words find: by the symbol's name, or by
    /// the words of the emoji an iPhone shows for it: "music" the note,
    /// "fire" the flame. No words, all of them.
    static func symbols(matching words: String) -> [String] {
        let needles = words.lowercased().split(separator: " ").map(String.init)
        guard !needles.isEmpty else { return symbolsOffered }
        let twins = Dictionary(SpaceSymbols.all.map { ($0.symbol, $0.emoji) }, uniquingKeysWith: { first, _ in first })
        return symbolsOffered.filter { symbol in
            let named = symbol.split(whereSeparator: { $0 == "." }).map(String.init)
            let all = named + (SpaceIconArt.catalog[symbol]?.words ?? [])
                + (twins[symbol].flatMap(Emoji.one(for:))?.words ?? [])
            return needles.allSatisfy { needle in all.contains { $0.hasPrefix(needle) } }
        }
    }
}

/// Search with, for one space: Settings › Search's engine to begin with, or
/// one of its own the field searches with while it is on screen, as Arc's
/// spaces can. Site aliases stay the same in every space.
private struct SpaceSearchRows: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let space: Space?
    @ObservedObject var form: SpaceForm

    static let usual = "default"

    private var search: String? { space == nil ? form.search : space?.search }
    private var custom: String? { space == nil ? form.searchCustom : space?.searchCustom }

    private func setSearch(_ search: String?, custom: String? = nil) {
        if let space {
            browser.setSpaceSearch(space.id, to: search, custom: custom)
        } else {
            form.search = search
            form.searchCustom = search == Engine.custom.rawValue ? custom : nil
        }
    }

    var body: some View {
        // Settings › Search's engine, named, so "Default" says which it is.
        let global = EngineChoice.global.name
        let options = [(title: "Default (\(global))", value: Self.usual)]
            + Engine.allCases.map { (title: $0.title, value: $0.rawValue) }
        Section {
            SettingsRow("Search with", detail: search == nil
                ? "The engine in Settings › Field."
                : "In this space only. Site aliases work as in every space.") {
                DropMenu("Search with", options: options, selection: Binding(
                    get: { search ?? Self.usual },
                    set: { value in
                        setSearch(value == Self.usual ? nil : value,
                                  custom: value == Engine.custom.rawValue ? custom : nil)
                    }), divideBefore: Engine.allCases.first?.rawValue)
                    .fixedSize()
            }
            .settingsAnchor("space-search")
            if search == Engine.custom.rawValue {
                EngineField(text: Binding(
                    get: { custom ?? "" },
                    set: { setSearch(Engine.custom.rawValue, custom: $0) }
                ), fallback: global, anchor: "space-search-custom")
                .benchSpot("space-create-custom")
            }
        }
    }
}
