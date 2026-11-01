#!/usr/bin/env python3
"""Static file server with injected faults, for the publish pipeline tests.

Serves --root over HTTP on 127.0.0.1 and writes the chosen port to
--port-file once it is listening. The query string is ignored when a path
is matched or served, the same way GitHub Pages ignores it.

Each --rule REGEX=ACTION[:COUNT] applies to request paths matching REGEX
(re.search, query stripped). ACTION is an HTTP status code to answer with,
or "truncate" to promise the full Content-Length but send only half of the
body and close the connection. COUNT limits how many requests the rule
answers (0 or missing: every request); after that the file is served
normally. The first matching rule with answers left wins.

Every request path is appended to --log, one per line.
"""

import argparse
import http.server
import os
import re
import sys
import threading
import urllib.parse


def parse_rule(text):
    pattern, _, action = text.rpartition("=")
    if not pattern:
        raise argparse.ArgumentTypeError(f"bad rule {text!r}")
    count = 0
    if ":" in action:
        action, count_text = action.split(":", 1)
        count = int(count_text)
    if action != "truncate":
        int(action)
    return {"re": re.compile(pattern), "action": action, "left": count or -1}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", default=os.devnull)
    parser.add_argument("--rule", action="append", default=[], type=parse_rule)
    args = parser.parse_args()

    lock = threading.Lock()
    rules = args.rule
    root = os.path.abspath(args.root)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=root, **kw)

        def log_message(self, *a):
            pass

        def pick_rule(self, path):
            with lock:
                for rule in rules:
                    if rule["left"] != 0 and rule["re"].search(path):
                        if rule["left"] > 0:
                            rule["left"] -= 1
                        return rule["action"]
            return None

        def handle_one(self, head_only):
            path = urllib.parse.urlsplit(self.path).path
            with lock, open(args.log, "a") as log:
                log.write(path + "\n")
            action = self.pick_rule(path)
            if action is None:
                if head_only:
                    return super().do_HEAD()
                return super().do_GET()
            if action == "truncate":
                local = self.translate_path(self.path)
                with open(local, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(body[: len(body) // 2])
                    self.wfile.flush()
                self.close_connection = True
                return None
            code = int(action)
            body = f"injected {code}\n".encode()
            self.send_response(code)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head_only:
                self.wfile.write(body)
            return None

        def do_GET(self):
            self.handle_one(False)

        def do_HEAD(self):
            self.handle_one(True)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file + ".tmp", "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(args.port_file + ".tmp", args.port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
