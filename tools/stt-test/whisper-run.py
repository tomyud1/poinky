#!/usr/bin/env python3
"""Runs whisper.cpp (whisper-server, model loaded once) over a bench manifest, for comparing engines.

  tools/stt-test/whisper-run.py <model.bin> <manifest.jsonl> <out.jsonl> [--lang en|he|auto] [--prompt-terms]

Needs whisper.cpp's whisper-server on PATH (e.g. `brew install whisper-cpp`) and ffmpeg (it converts each clip).
Each result line: key, hyp, ms (the request's time: the encoder runs on the GPU), lang (the detected language).
"""
import json, os, socket, subprocess, sys, time, urllib.request, uuid

model, manifest, out = sys.argv[1:4]
lang = sys.argv[sys.argv.index("--lang") + 1] if "--lang" in sys.argv else "en"
terms = "--prompt-terms" in sys.argv
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
srv = subprocess.Popen(["whisper-server", "-m", model, "--port", str(port), "--convert", "-t", "4", "--no-timestamps",
                        "-l", lang], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(120):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1); break
        except Exception:
            time.sleep(0.5)

    def ask(path, prompt=""):
        b = uuid.uuid4().hex
        body = b""
        fields = {"response_format": "verbose_json", "temperature": "0.0", "language": lang}
        if prompt:
            fields["prompt"] = prompt
        for k, v in fields.items():
            body += f"--{b}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
        body += f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode()
        body += open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}/inference", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={b}"})
        t = time.time()
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())
        return r, (time.time() - t) * 1000

    items = [json.loads(l) for l in open(manifest)]
    ask(items[0]["wav"])   # warm-up
    with open(out, "w") as o:
        for i, it in enumerate(items):
            prompt = ""
            if terms:
                prompt = "Poinky, Mint, Coral, " + ", ".join(it.get("terms") or [])
            r, ms = ask(it["wav"], prompt)
            o.write(json.dumps({"key": it.get("key", it.get("id")), "hyp": r.get("text", "").strip(), "ms": ms,
                                "lang": r.get("language", "")}, ensure_ascii=False) + "\n")
            if i % 50 == 0:
                print(i, it.get("key"), r.get("text", "").strip()[:60], int(ms), "ms", flush=True)
finally:
    srv.terminate()
