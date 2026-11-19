import Foundation
import WebKit

// Where the user is signed in to a site, space by space.
//
// A space with sign-ins of its own keeps cookies of its own, so a site can
// be signed in there and signed out on screen. An agent that opened the
// site where it landed would tell the user "you're not signed in" when they
// are, one space over. So yab looks for it, not the model: the cookies of
// each store (a skill's `signed-in:` names, or anything that reads like a
// session and isn't analytics) and the user's own tabs there. `open`
// without a space goes where the site is signed in, and a page that asks
// for a sign-in says where it already is. Only about the one site asked
// for: the list of every site someone is signed in to isn't the model's to
// read.

@MainActor
enum SignIns {
    enum Seen: String {
        case signedIn = "signed in"
        case likely = "likely signed in"
        case out = "signed out"
    }

    /// One store and the spaces signed in with it: the first space and every
    /// shared one are a single place.
    struct Place {
        let spaces: [Space]
        let store: WKWebsiteDataStore
        var seen: Seen = .out

        var names: String { spaces.map(\.name).joined(separator: ", ") }
        func holds(_ id: UUID) -> Bool { spaces.contains { $0.id == id } }
    }

    /// The widest a Sign-ins picker's face grows in Settings: a place shared
    /// by many spaces names them all, and the name is cut short past this
    /// instead of widening the page.
    static let pickerWidth: CGFloat = 260

    /// Whether there is anywhere else to be signed in: some space with
    /// sign-ins of its own. Without one, nothing to find and nothing spent.
    static func split(_ browser: Browser) -> Bool {
        browser.spaces.contains(where: \.ownSignIns)
    }

    /// Every store, in the spaces' order.
    static func places(_ browser: Browser) -> [Place] {
        var out: [Place] = []
        for space in browser.spaces {
            let store = Spaces.store(for: space.id)
            if let at = out.firstIndex(where: { $0.store === store }) {
                out[at] = Place(spaces: out[at].spaces + [space], store: store)
            } else {
                out.append(Place(spaces: [space], store: store))
            }
        }
        return out
    }

    /// Each place, as signed in to the host as it looks.
    static func check(_ host: String, in browser: Browser, allowed: @escaping @MainActor () -> Bool = { true }, _ done: @escaping @MainActor ([Place]) -> Void) {
        guard allowed() else { return done([]) }
        let site = site(host)
        let names = Array(Set(Skills.for(URL(string: "https://\(site)/")).flatMap(\.signedIn)))
        let people = BrowserWindows.shared.browsers.isEmpty ? [browser] : BrowserWindows.shared.browsers
        let tabs = people.flatMap { $0.tabs + $0.parkedTabs }.filter { tab in
            guard !tab.shy, !tab.bench, tab.agent == nil, let url = tab.address, let there = url.host()
            else { return false }
            return SignIns.same(SignIns.site(there), site) && !SignIns.loginPage(url)
        }
        // A space hidden from AI is no place an agent signs in from; a
        // store it shares with others is still theirs.
        let all = places(browser).compactMap { place -> Place? in
            let open = place.spaces.filter { !browser.hidesFromAI(space: $0.id) }
            return open.isEmpty ? nil : Place(spaces: open, store: place.store)
        }
        Task { @MainActor in
            var out: [Place] = []
            for var place in all {
                guard allowed() else { return done([]) }
                let cookies = await place.store.httpCookieStore.allCookies()
                    .filter { SignIns.covers($0.domain, site) }
                    .map { Crumb(name: $0.name, value: $0.value, expires: $0.expiresDate) }
                guard allowed() else { return done([]) }
                let working = tabs.contains { $0.store === place.store }
                place.seen = SignIns.seen(cookies, names: names, working: working)
                out.append(place)
            }
            done(out)
        }
    }

    /// Where to open the host when the agent named no space: on screen if
    /// it is signed in there or nowhere, else the first place that is. With
    /// a line to tell the agent, when there is something to tell.
    static func pick(_ host: String, in browser: Browser, allowed: @escaping @MainActor () -> Bool = { true }, _ done: @escaping @MainActor (UUID?, String?) -> Void) {
        guard allowed(), split(browser) else { return done(nil, nil) }
        check(host, in: browser, allowed: allowed) { places in
            let here = browser.spaceID
            let site = site(host)
            let signed = places.filter { $0.seen != .out }
            let others = signed.filter { !$0.holds(here) }
            if signed.contains(where: { $0.holds(here) }) {
                guard !others.isEmpty else { return done(nil, nil) }
                return done(nil, "space: on screen; also signed in to \(site) in \(others.map { "“\($0.names)”" }.joined(separator: ", "))")
            }
            guard let best = others.first(where: { $0.seen == .signedIn }) ?? others.first, let space = best.spaces.first else {
                return done(nil, nil)
            }
            let screen = browser.spaces.first { $0.id == here }?.name ?? "the space on screen"
            var line = "space: “\(space.name)”, \(best.seen.rawValue) to \(site) there; “\(screen)”, on screen, is signed out"
            let rest = others.filter { $0.store !== best.store }
            if !rest.isEmpty { line += "; also signed in in \(rest.map { "“\($0.names)”" }.joined(separator: ", "))" }
            done(space.id, line)
        }
    }

    /// For a page that asks for a sign-in, or an answer that was refused:
    /// the other places signed in to its site, as a line for the agent, or
    /// nil when there are none.
    static func elsewhere(_ url: URL?, from store: WKWebsiteDataStore, in browser: Browser, allowed: @escaping @MainActor () -> Bool = { true }, _ done: @escaping @MainActor (String?) -> Void) {
        guard allowed(), split(browser), let host = url?.host() else { return done(nil) }
        check(host, in: browser, allowed: allowed) { places in
            let signed = places.filter { $0.seen != .out && $0.store !== store }
            guard let first = signed.first?.spaces.first else { return done(nil) }
            let site = site(host)
            let list = signed.map { "“\($0.names)” (\($0.seen.rawValue))" }.joined(separator: ", ")
            done("signed out here, but signed in to \(site) in space \(list): open it again with space “\(first.name)” rather than sign_in or handoff, and never tell the user they are signed out")
        }
    }

    /// The providers a sign-in page offers (Continue with Google), and
    /// the ones this tab's store is signed in to: a line for the agent, so
    /// it clicks its way in instead of handing the tab over. Nil when none
    /// of them is.
    static func ways(_ offered: [String], store: WKWebsiteDataStore, allowed: @escaping @MainActor () -> Bool = { true }, _ done: @escaping @MainActor (String?) -> Void) {
        let sites = ["Google": "google.com", "GitHub": "github.com", "Apple": "apple.com", "Microsoft": "live.com", "GitLab": "gitlab.com", "Slack": "slack.com"]
        let wanted = offered.compactMap { name in sites[name].map { (name, $0) } }
        guard allowed(), !wanted.isEmpty else { return done(nil) }
        Task { @MainActor in
            guard allowed() else { return done(nil) }
            let cookies = await store.httpCookieStore.allCookies()
            guard allowed() else { return done(nil) }
            let signed = wanted.filter { name, site in
                let names = Array(Set(Skills.for(URL(string: "https://\(site)/")).flatMap(\.signedIn)))
                let crumbs = cookies.filter { covers($0.domain, site) }.map { Crumb(name: $0.name, value: $0.value, expires: $0.expiresDate) }
                return seen(crumbs, names: names, working: false) != .out
            }.map { $0.0 }
            guard !signed.isEmpty else { return done(nil) }
            done(line(signed))
        }
    }

    /// Back on the site a sign-in was asked on, past its sign-in pages: a
    /// Google or GitHub page on the way is another site, and signing up, a
    /// second factor or a code are still on the way in.
    nonisolated static func back(from: URL, at now: URL) -> Bool {
        guard site(now.host() ?? "") == site(from.host() ?? ""), !loginPage(now) else { return false }
        let path = now.path.lowercased()
        let steps = ["signup", "sign-up", "register", "verify", "2fa", "mfa", "otp", "challenge", "confirm", "callback", "oauth"]
        return !steps.contains { path.contains($0) }
    }

    /// What the agent reads about them.
    nonisolated static func line(_ signed: [String]) -> String {
        let list = signed.joined(separator: ", ")
        return "signs in with: \(list), and this space is signed in to \(signed.count == 1 ? "it" : "them"): "
            + "click Continue with \(signed[0]) (or the like) and pick the user's account; that is signing in, not a handoff. "
            + "With several accounts, the one used here before, else ask which. handoff only if it then wants a password Yab doesn't keep, "
            + "a second factor, a captcha, or a new app's permission"
    }

    // MARK: - telling

    /// A cookie as the reckoning needs it.
    struct Crumb {
        let name: String
        let value: String
        let expires: Date?
    }

    /// A host as sites are compared: lowercased, no www.
    nonisolated static func site(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// One site the other's own or under it, either way: mail.google.com
    /// and google.com are a sign-in apart only by the cookie's domain.
    nonisolated static func same(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    /// Whether a cookie set for `domain` goes with requests to `site`.
    nonisolated static func covers(_ domain: String, _ site: String) -> Bool {
        var domain = domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        if domain.hasPrefix("www.") { domain = String(domain.dropFirst(4)) }
        return !domain.isEmpty && (site == domain || site.hasSuffix("." + domain))
    }

    /// What the cookies and the user's own tabs say. A skill's names decide
    /// alone when it has them; otherwise a session-like cookie is a likely
    /// yes, and one with a tab of the user's working there is a yes.
    nonisolated static func seen(_ cookies: [Crumb], names: [String], working: Bool, now: Date = Date()) -> Seen {
        let live = cookies.filter { crumb in
            (crumb.expires.map { $0 > now } ?? true) && !empty.contains(crumb.value.lowercased())
        }
        if !names.isEmpty {
            let wanted = Set(names.map { $0.lowercased() })
            return live.contains { wanted.contains($0.name.lowercased()) } ? .signedIn : .out
        }
        guard live.contains(where: { session($0.name) }) else { return .out }
        return working ? .signedIn : .likely
    }

    /// Values a cookie keeps when it says nobody is there (GitHub's
    /// `logged_in=no`).
    nonisolated private static let empty: Set<String> = ["", "no", "false", "0", "null", "undefined", "deleted", "guest", "anonymous"]

    /// A name that reads like a sign-in and not like analytics, consent or
    /// the steps of signing in.
    nonisolated static func session(_ name: String) -> Bool {
        let name = name.lowercased()
        let noise = ["_ga", "_gid", "_gat", "_gcl", "_fbp", "_fbc", "__cf", "_cf", "cf_", "ajs_", "amplitude", "_hj", "mp_", "__stripe",
                     "intercom", "_uet", "optimizely", "__utm", "__hs", "hubspot", "_clck", "_clsk", "_dd", "_pk_", "_sp_", "_tt_", "_rdt",
                     "_scid", "_pin", "muid", "analytics", "tracking", "utm", "csrf", "xsrf", "consent", "optanon", "anon", "guest",
                     "visitor", "callback", "nonce", "pkce", "redirect", "return", "state", "lang", "locale", "theme", "tz", "device"]
        if noise.contains(where: { name.contains($0) }) { return false }
        let signs = ["sess", "auth", "token", "sid", "login", "logged", "user", "jwt", "remember", "sso", "account", "ident", "secure-"]
        return signs.contains { name.contains($0) }
    }

    /// Whether an address is a place to sign in, rather than a page
    /// someone signed in reads.
    nonisolated static func loginPage(_ url: URL) -> Bool {
        let host = site(url.host() ?? "")
        let path = url.path.lowercased()
        if host == "accounts.google.com", !path.hasPrefix("/b/") { return true }
        if ["login.microsoftonline.com", "login.live.com", "appleid.apple.com", "idmsa.apple.com"].contains(host) { return true }
        if ["login.", "signin.", "auth.", "sso."].contains(where: { host.hasPrefix($0) }) { return true }
        let words = ["login", "log-in", "log_in", "signin", "sign-in", "sign_in", "logon", "sso", "authenticate", "auth"]
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { words.contains($0) }) { return true }
        // Rails and friends: /session and /sessions/new.
        if parts.first == "session" || (parts.count >= 2 && parts[0] == "sessions" && parts[1] == "new") { return true }
        return false
    }
}
