#!/usr/bin/env python3
"""Serves the Poinky demo at http://localhost:8800 and opens it.

The code editor scene shows the real files in sample-project/ (it updates live when an agent
edits them) and its terminal really runs the tests. Only a few fixed commands can run.

    python3 demo/serve.py
"""
import http.server
import json
import os
import re
import subprocess
import sys
import threading
import urllib.parse
import webbrowser

DEMO = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.join(DEMO, "sample-project")
FILES = ["tipsplit.py", "test_tipsplit.py", "README.md"]
PORT = 8800
HOME = os.path.expanduser("~")
SHOWN_DIR = "~/" + os.path.relpath(PROJECT, HOME) if PROJECT.startswith(HOME) else PROJECT


def run(args, timeout=20):
    try:
        p = subprocess.run(args, cwd=PROJECT, capture_output=True, text=True, timeout=timeout)
        return p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired:
        return "Timed out.\n", 1
    except FileNotFoundError as e:
        return f"{e}\n", 127


def command(line):
    """The terminal's commands: run the tests, the script, ls, git status/diff. Nothing else."""
    words = line.split()
    if not words:
        return "", 0
    py = sys.executable
    if words[0] in ("python", "python3"):
        rest = words[1:]
        if rest[:2] == ["-m", "unittest"] and all(w in ("-v", "test_tipsplit") for w in rest[2:]):
            return run([py, "-m", "unittest", *rest[2:]])
        if rest[:1] == ["tipsplit.py"] and all(re.fullmatch(r"\d+(\.\d+)?", w) for w in rest[1:4]) and len(rest) == 4:
            return run([py, "tipsplit.py", *rest[1:]])
        if rest[:1] == ["test_tipsplit.py"] and len(rest) <= 2 and all(w == "-v" for w in rest[1:]):
            return run([py, "test_tipsplit.py", *rest[1:]])
        return "usage in this demo: python3 -m unittest  |  python3 tipsplit.py 87.40 18 3\n", 2
    if words == ["ls"] or words == ["ls", "-la"]:
        names = sorted(n for n in os.listdir(PROJECT) if not n.startswith(".") and n != "__pycache__")
        return "  ".join(names) + "\n", 0
    if words[:2] == ["git", "status"] or words[:2] == ["git", "diff"]:
        return run(["git", "-c", "color.ui=never", *words[1:2], "--", "."])
    return f"zsh: command not found: {words[0]}\n", 127


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=DEMO, **k)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/files":
            files = {}
            for name in FILES:
                p = os.path.join(PROJECT, name)
                try:
                    with open(p, encoding="utf-8") as f:
                        files[name] = {"mtime": os.path.getmtime(p), "text": f.read()}
                except OSError:
                    pass
            return self.json({"dir": SHOWN_DIR, "files": files})
        if path == "/":
            self.path = "/index.html"
        return super().do_GET()

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        if path == "/api/run":
            out, code = command(str(body.get("cmd", ""))[:200])
            return self.json({"out": out, "code": code})
        if path == "/api/reset":
            # Puts the bug back (the committed version of sample-project) for another take.
            out, code = run(["git", "checkout", "--", "."])
            return self.json({"out": out, "code": code})
        self.json({"error": "not found"}, 404)


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    url = f"http://localhost:{PORT}/"
    print(f"Poinky demo: {url}  (Ctrl+C to stop)")
    if "--no-open" not in sys.argv:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
