#!/usr/bin/env python3
"""Does profile.history keep a space's visits out of Chromium's own History?

Yab's Don't Keep History (Settings › Spaces › Privacy) writes nothing of
where you went in that space; Yab's diary skips the visit, and YabCore's
profile.history sets Chrome's SavingBrowserHistoryDisabled
(history.saving_disabled) on the space's profile so Chromium's own History
database keeps none either.

Two profiles on one helper: "keep", left as it is, and "none", told
profile.history saving=false. Each opens a page from a loopback fixture,
then a second one by navigation; the helper closes cleanly, and each
profile's History database is read for the two addresses.

  history_saving.py HELPER

Passes when "keep" holds both visits and "none" holds neither, and
profile.history answered saving=false. Writes $YAB_FARM_OUT/history-saving.json
when YAB_FARM_OUT is set.
"""
import http.server
import json
import os
from pathlib import Path
import select
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

helper = Path(sys.argv[1])
out = Path(os.environ['YAB_FARM_OUT']) if os.environ.get('YAB_FARM_OUT') else None


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ('<!doctype html><meta charset=utf-8><title>%s</title><p>%s' % (self.path, self.path)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = 'http://127.0.0.1:%d' % server.server_port


class Core:
    def __init__(self, data, log):
        self.endpoint = Path(tempfile.mkdtemp(prefix='yc-hist-', dir='/tmp')) / 'core.sock'
        self.process = subprocess.Popen([str(helper), '--socket=' + str(self.endpoint), '--data-root=' + str(data),
                                         '--use-mock-keychain', '--no-sandbox'], stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while not self.endpoint.exists():
            assert self.process.poll() is None and time.monotonic() < deadline, 'Helper did not start'
            time.sleep(.1)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(self.endpoint))
        self.buffer, self.serial = b'', 0

    def line(self, until):
        while b'\n' not in self.buffer:
            left = until - time.monotonic()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.sock], [], [], left)
            if not ready:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError('helper connection ended')
            self.buffer += chunk
        raw, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(raw)

    def call(self, method, **params):
        self.serial += 1
        request = str(self.serial)
        self.sock.sendall((json.dumps(dict(v=1, id=request, method=method, params=params)) + '\n').encode())
        until = time.monotonic() + 30
        while True:
            value = self.line(until)
            assert value is not None, ('No reply', method)
            if value.get('id') == request:
                assert 'error' not in value, (method, value)
                return value.get('result')

    def pump(self, seconds):
        until = time.monotonic() + seconds
        while self.line(until) is not None:
            pass

    def loaded(self, tab, url):
        deadline = time.monotonic() + 20
        while True:
            state = self.call('tab.state', tab=tab)
            if state.get('devToolsReady'):
                try:
                    here = self.call('script.evaluate', tab=tab, world='history-saving',
                                     function='function(){return [location.href, document.readyState]}')
                    if here == [url, 'complete']:
                        return
                except AssertionError:
                    pass
            assert time.monotonic() < deadline, ('Page never loaded', url)
            self.pump(.2)

    def visit(self, profile, tag):
        first, second = BASE + '/%s-one' % tag, BASE + '/%s-two' % tag
        tab = self.call('tab.create', profile=profile, url=first)['tab']
        self.call('tab.resize', tab=tab, width=800, height=600, scale=1)
        self.call('tab.visible', tab=tab, visible=True)
        self.loaded(tab, first)
        self.call('tab.navigate', tab=tab, url=second)
        self.loaded(tab, second)
        return [first, second]

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        try:
            return self.process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return self.process.wait()


def recorded(data, urls):
    """Every History database under the data root: which of the urls it holds."""
    found = {}
    for db in data.rglob('History'):
        if not db.is_file():
            continue
        con = sqlite3.connect('file:%s?mode=ro&immutable=1' % db, uri=True)
        try:
            rows = {u for (u,) in con.execute('SELECT url FROM urls')}
        finally:
            con.close()
        found[str(db.relative_to(data))] = sorted(u for u in urls if u in rows)
    return found


result = {}
with tempfile.TemporaryDirectory(prefix='yc-hist-data-', dir='/tmp') as temporary:
    data = Path(temporary) / 'data'
    log_path = (out / 'history-saving-helper.log') if out else Path(temporary) / 'helper.log'
    with log_path.open('w') as log:
        core = Core(data, log)
        core.call('hello')
        core.call('profile.open', profile='keep', private=False)
        core.call('profile.open', profile='none', private=False)
        result['answer'] = core.call('profile.history', profile='none', saving=False)
        kept = core.visit('keep', 'keep')
        dropped = core.visit('none', 'none')
        core.pump(2)
        result['exit'] = core.close()
    result['history'] = recorded(data, kept + dropped)
server.shutdown()
if out:
    (out / 'history-saving.json').write_text(json.dumps(result, indent=1))
print(json.dumps(result, indent=1), flush=True)

everywhere = [u for urls in result['history'].values() for u in urls]
checks = [
    ('profile.history answered saving=false', result['answer'] == {'saving': False}),
    ('Chromium kept the ordinary profile\'s two visits', all(u in everywhere for u in kept)),
    ('Chromium kept none of the no-history profile\'s visits', not any(u in everywhere for u in dropped)),
]
for name, ok in checks:
    print('%s %s' % ('PASS' if ok else 'FAIL', name), flush=True)
sys.exit(0 if all(ok for _, ok in checks) else 1)
