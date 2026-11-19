import AppKit
import WebKit

// The yab: scheme, what the app serves of its own: an agent task's answer
// (yab://task), the pictures of pages and the icons of sites, all from this
// Mac, so a page never fetches anything from the sites it lists. And the diary's side of
// the window: every page landed on is a visit, with what it said and what
// it looked like, for History in the box (Places.swift) to find again.
//
// History, passwords, autofill, downloads and bookmarks were pages here
// once; they are places in the box now (Places.swift).

enum DiaryPage {
    static let scheme = "yab"

    /// Every tab's configuration gets the scheme, which can't be added once
    /// a view has been made from it. The pages' handlers come and go with
    /// the pages (see `fit`).
    static func attach(_ config: WKWebViewConfiguration) {
        config.setURLSchemeHandler(DiaryScheme.shared, forURLScheme: scheme)
    }

    /// The handlers yab:// pages talk through, there only while the tab is
    /// going to one of them. They answer nothing but these pages, but a page
    /// that finds `window.webkit` at all knows it is in an app's web view
    /// rather than Safari, and sites answer that with CAPTCHAs. Put on and
    /// taken off as a main-frame navigation is allowed, before the next
    /// document's first script runs.
    static func fit(_ controller: WKUserContentController, to url: URL?) {
        MainActor.assumeIsolated { BoostApp.fit(controller, url: url) }
        let pairs: [(any WKScriptMessageHandlerWithReply, String)] = [
            (KnowRelay.shared, KnowRelay.name),
        ]
        for (_, name) in pairs { controller.removeScriptMessageHandler(forName: name, contentWorld: .page) }
        guard url?.scheme == scheme else { return }
        for (handler, name) in pairs { controller.addScriptMessageHandler(handler, contentWorld: .page, name: name) }
    }
}

/// Serves Yab's own pages, the pictures of pages and the icons of sites,
/// all from this Mac, so a page never fetches anything from the
/// sites it lists.
final class DiaryScheme: NSObject, WKURLSchemeHandler {
    static let shared = DiaryScheme()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path().split(separator: "/").map(String.init)
        var body: Data?
        var type = "text/html"
        if url.host?.hasSuffix(".boost") == true,
           let resource = MainActor.assumeIsolated({ BoostApp.resource(url, main: task.request.mainDocumentURL ?? webView.url, in: Spaces.ownSpace(of: webView.configuration.websiteDataStore)) }) {
            body = resource.0; type = resource.1
        }
        switch url.host() {
        case MailPage.host:
            body = MainActor.assumeIsolated { MailPage.page }
        case KnowPage.host:
            body = MainActor.assumeIsolated { KnowPage.page(for: url) }
        case "font" where path == ["caveat.ttf"]:
            // The update note's hand, for yab://you's pen.
            body = Bundle.main.url(forResource: "Caveat", withExtension: "ttf").flatMap { try? Data(contentsOf: $0) }
            type = "font/ttf"
        case "shot" where path.count == 1 && !path[0].contains(".."):
            body = try? Data(contentsOf: Diary.shots.appendingPathComponent(path[0]))
            type = "image/jpeg"
        case "icon" where path.count == 1 && !path[0].contains(".."):
            let icons = Store.folder.appendingPathComponent("icons", isDirectory: true)
            body = (try? Data(contentsOf: icons.appendingPathComponent(path[0] + ".png")))
                ?? (try? Data(contentsOf: icons.appendingPathComponent("www." + path[0] + ".png")))
            type = "image/png"
        default:
            break
        }
        guard let body else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // The page itself is always fresh; pictures and icons keep a while.
        let headers = [
            "Content-Type": type == "text/html" ? "text/html; charset=utf-8" : type,
            "Cache-Control": type == "text/html" ? "no-store" : "max-age=600",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: type, expectedContentLength: body.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - the window's side

extension Browser {
    /// A page has landed: a visit in the diary, then, once it has had a
    /// moment to settle, what it says and what it looks like.
    /// The address changed. If it settles there without a load finishing
    /// a page moving itself along, it is remembered as a visit too.
    func noticeMove(_ tab: Tab, to url: URL) {
        guard recording(tab).contains(.history), url.scheme == "http" || url.scheme == "https" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab, tab.address == url, tab.builtPage?.isLoading == false,
                  !DiaryPage.fresh(tab.id, url) else { return }
            remember(tab, at: url)
        }
    }

    /// A page come in and still loading a moment later, a heavy one whose
    /// pictures and ads keep coming: a visit all the same, counted
    /// when the page comes in. It was only counted once the load
    /// finished, so a page read while it loaded and left before then was in
    /// neither History nor the field. Its load finishing later gives History
    /// its title only.
    func noticeCommit(_ tab: Tab, at url: URL?) {
        DiaryPage.counted[tab.id] = nil
        guard let url, recording(tab).contains(.history), url.scheme == "http" || url.scheme == "https" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab, tab.address == url, tab.builtPage?.isLoading == true, DiaryPage.counted[tab.id] == nil else { return }
            DiaryPage.counted[tab.id] = url
            history(for: tab).record(url, title: tab.title, space: visitSpace(tab))
            remember(tab, at: url)
        }
    }

    func remember(_ tab: Tab, at url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        // Once per arrival: a finished load and a settled address are often
        // the same thing seen twice.
        guard !DiaryPage.fresh(tab.id, url) else { return }
        DiaryPage.noted[tab.id] = (url, Date())

        // Written down once the page has stayed a moment: a page that sends
        // you straight on, a redirect, a "Redirecting…", was never a visit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab, tab.address == url else { return }
            // Its space, for the day's threads, and what it keeps of them
            // (Browser.recording).
            let space = self.tabs.contains { $0 === tab } ? self.spaceID
                : self.parked.first { $0.value.tabs.contains { $0 === tab } }?.key ?? self.spaceID
            let recording = self.recording(tab, in: space)
            guard recording.contains(.history) else { return }
            Diary.shared.visit(url, title: tab.title, tab: tab.id, space: space, quiet: !recording.contains(.threads))
            // Somewhere made in the app, a new page that never loaded one.
            QuickActions.shared.noticed(url, title: tab.title)
            // Nothing of what is on the page, its words, its picture,
            // unless that is wanted, and never from a page asking for a
            // password.
            guard self.prefs.diaryText, let web = tab.builtPage else { return }
            let seen = tab.id == self.activeID
            Diary.shared.wantsText(for: url) { [weak web, weak tab] wanted in
                guard let web, tab?.address == url else { return }
                // In a world of its own, so the page's scripts can't stand
                // in the way of reading it, or see it being read.
                web.run(DiaryPage.reading, in: .client, gesture: false) { [weak web] result in
                    guard case .success(let value) = result, let page = value as? [String: Any],
                          page["secret"] as? Bool != true else { return }
                    if wanted, let text = page["text"] as? String, text.count >= 200 {
                        Diary.shared.read(url, text: text)
                    }
                    // A picture only of a page that was on screen. One opened
                    // behind keeps the picture it offers for sharing instead.
                    if !seen, let named = page["og"] as? String, let image = URL(string: named) {
                        Diary.shared.look(key: Diary.key(url), url: url, image: image) { _ in }
                    }
                    guard seen, let web, Diary.shared.wantsShot(for: url) else { return }
                    web.snapshot(PageShot(width: 640, afterUpdates: false)) { image, _ in
                        if let image { Diary.shared.keep(image, for: url) }
                    }
                }
            }
        }
    }
}

extension DiaryPage {
    /// The last address each tab was remembered at.
    @MainActor static var noted: [UUID: (URL, Date)] = [:]
    /// The address a tab's visit was counted at in History while its page
    /// still loaded (Browser.noticeCommit), till its next navigation.
    @MainActor static var counted: [UUID: URL] = [:]

    /// Remembered at this address in the last few minutes: a reload, or the
    /// same arrival reported twice.
    @MainActor static func fresh(_ tab: UUID, _ url: URL) -> Bool {
        guard let (was, at) = noted[tab] else { return false }
        return was == url && Date().timeIntervalSince(at) < 600
    }

    /// The page's words: the part carrying the most prose, or the whole body.
    /// Nothing from a page asking for a password, a sign-in page, a bank.
    static let reading = """
    (function () {
      if (document.querySelector('input[type=password]')) return { secret: true };
      function prose(el) {
        var ps = el.querySelectorAll('p');
        if (ps.length < 2) return 0;
        var letters = 0;
        for (var i = 0; i < ps.length; i++) letters += (ps[i].innerText || '').length;
        if (letters < 400) return 0;
        return letters / (1 + el.querySelectorAll('a').length * 14);
      }
      var list = document.querySelectorAll('article, main, [role="main"], .post, .entry, .article, .content, #content, section, div');
      var top = null, mark = 0;
      for (var i = 0; i < list.length && i < 4000; i++) {
        var score = prose(list[i]);
        if (score > mark) { mark = score; top = list[i]; }
      }
      var text = ((top || document.body).innerText || '');
      var about = document.querySelector('meta[name="description"], meta[property="og:description"]');
      if (about && about.content) text = about.content + '\\n' + text;
      var og = document.querySelector('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"], meta[property="twitter:image"]');
      var image = '';
      try { if (og && og.content) image = new URL(og.content, location.href).href; } catch (e) {}
      return { text: text.slice(0, 20000), og: image };
    })()
    """
}
