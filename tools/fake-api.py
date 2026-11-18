#!/usr/bin/env python3
"""A stand-in for the Anthropic Messages API (streaming), for tests of Poinky's API brain without a key or
tokens: `tools/fake-api.py PORT`, then run Poinky with POINKY_API_URL=http://127.0.0.1:PORT/v1/messages.

Every talker question streams FAKE_API_REPLY (default "<say>Fake answer.</say>"; FAKE_API_REPLIES: a JSON list
used in order) word by word, FAKE_API_WORD_SECS
apart (default 0.05), so a long reply takes a while: tests can interrupt it and ask again. Each request is
logged to FAKE_API_LOG (start / done / dropped) if set.
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("FAKE_API_LOG")


def note(s):
    if LOG:
        with open(LOG, "a") as f: f.write(f"{time.time():.3f} {s}\n")


count = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a): pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))) or b"{}")
        last = body.get("messages", [{}])[-1].get("content", [])
        text = " ".join(c.get("text", "") for c in last if isinstance(c, dict) and c.get("type") == "text")
        note("start " + json.dumps(text[:60]))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("transfer-encoding", "chunked")
        self.end_headers()

        def send(ev):
            data = f"event: {ev['type']}\ndata: {json.dumps(ev)}\n\n".encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data)); self.wfile.flush()

        global count
        replies = json.loads(os.environ["FAKE_API_REPLIES"]) if os.environ.get("FAKE_API_REPLIES") else [os.environ.get("FAKE_API_REPLY", "<say>Fake answer.</say>")]
        # (Only the talker's questions count: they're the ones that say "User said".)
        reply = replies[min(count, len(replies) - 1)] if "User said" in text else "<say>Noted.</say>"
        if "User said" in text: count += 1
        gap = float(os.environ.get("FAKE_API_WORD_SECS", "0.05"))
        try:
            send({"type": "message_start", "message": {"id": "m", "role": "assistant", "content": []}})
            words = reply.split(" ")
            for i, w in enumerate(words):
                send({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": w + (" " if i < len(words) - 1 else "")}})
                time.sleep(gap)
            send({"type": "message_delta", "delta": {"stop_reason": "end_turn"}})
            send({"type": "message_stop"})
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            note("done")
        except (BrokenPipeError, ConnectionResetError, OSError):
            note("dropped")


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address): pass   # a client that went away is expected


Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
