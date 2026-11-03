#!/usr/bin/env python3
"""A stand-in for an ntfy server, for testing away mode without a phone or the network.

    python3 tools/fake-ntfy.py <port> <log-file> [tap]

POST /<topic> stores a notification (and logs its title, message and buttons). GET /<topic>/json streams
a topic's messages as ntfy does. With "tap", it presses a notification's first button half a second
after it arrives, the way a phone would (posting that button's body to its URL).
"""
import json, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG, TAP = int(sys.argv[1]), sys.argv[2], len(sys.argv) > 3 and sys.argv[3] == "tap"
topics, cond = {}, threading.Condition()

def log(s):
    with open(LOG, "a") as f:
        f.write(s + "\n")

def publish(topic, message):
    with cond:
        topics.setdefault(topic, []).append({"event": "message", "time": int(time.time()), "message": message})
        cond.notify_all()

def tap(actions):
    first = actions.split(";")[0].split(",")
    parts = [p.strip() for p in first]
    url = parts[2]
    body = next((p[5:] for p in parts if p.startswith("body=")), "")
    time.sleep(0.5)
    log("tapped: " + parts[1] + " -> " + body)
    urllib.request.urlopen(urllib.request.Request(url, data=body.encode(), method="POST")).read()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        topic = self.path.strip("/")
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        publish(topic, body)
        actions = self.headers.get("Actions") or ""
        if not topic.endswith("-reply"):
            log("notification on %s: title=%r message=%r actions=%r" % (topic, self.headers.get("Title"), body, actions))
            if TAP and actions:
                threading.Thread(target=tap, args=(actions,), daemon=True).start()
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self):
        topic = self.path.split("?")[0].strip("/").rsplit("/json", 1)[0]
        self.send_response(200); self.send_header("Content-Type", "application/x-ndjson"); self.end_headers()
        log("listening on " + topic)
        sent = len(topics.get(topic, []))
        try:
            while True:
                with cond:
                    cond.wait_for(lambda: len(topics.get(topic, [])) > sent, timeout=1)
                    new = topics.get(topic, [])[sent:]
                for m in new:
                    self.wfile.write((json.dumps(m) + "\n").encode()); self.wfile.flush()
                    sent += 1
        except (BrokenPipeError, ConnectionResetError):
            pass

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
