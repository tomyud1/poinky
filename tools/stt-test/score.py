#!/usr/bin/env python3
"""Scores speech-recognition results from tools/stt-test (bench run … out.jsonl) against the sentences.

  tools/stt-test/score.py <manifest.jsonl> <name>=<results.jsonl> [<name>=<results.jsonl> …] [--by voice|cond|kind]
                          [--md] [--show N] [--only cond1,cond2]

Prints word error rate (WER, %) per condition for each engine, plus the share of key terms heard right ("terms"),
and for Hebrew the character error rate too. Numbers, contractions and hyphens are normalized on both sides
("10" = "ten", "what's" = "what is", "Navier-Stokes" = "navier stokes"), so only real mistakes count.
"""
import json, re, sys, unicodedata
from collections import defaultdict

NUM = {"0": "zero", "1": "one", "2": "two", "3": "three", "4": "four", "5": "five", "6": "six", "7": "seven",
       "8": "eight", "9": "nine", "10": "ten", "11": "eleven", "12": "twelve", "20": "twenty", "100": "hundred"}
CONTRACT = {"what's": "what is", "how's": "how is", "don't": "do not", "it's": "it is", "that's": "that is",
            "i'm": "i am", "can't": "cannot", "won't": "will not", "isn't": "is not", "doesn't": "does not",
            "where's": "where is", "there's": "there is", "let's": "let us", "you're": "you are", "i've": "i have"}
SAME = {"ok": "okay", "cm": "centimeters", "centimetres": "centimeters", "litres": "liters", "l": "liters",
        "per": "per", "reg": "reg", "e-mail": "email", "whiteboard": "whiteboard", "white": "white"}


def norm_en(s):
    s = unicodedata.normalize("NFKC", s).lower().replace("’", "'")
    s = re.sub(r"(\d+)\s*cm\b", r"\1 centimeters", s)
    s = re.sub(r"(\d+)\s*l/s\b", r"\1 liters per second", s)
    s = re.sub(r"[-–—/]", " ", s)
    s = re.sub(r"[^\w\s']", " ", s)
    words = []
    for w in s.split():
        w = w.strip("'")
        if not w:
            continue
        if w in CONTRACT:
            words += CONTRACT[w].split(); continue
        if w.endswith("'s") and w[:-2] in ("bernoulli", "reynold"):
            w = w[:-2] + "s"
        w = NUM.get(w, SAME.get(w, w))
        words.append(w)
    # "white board" = "whiteboard", "pull request" ok; "user count" vs "usercount"
    out = " ".join(words)
    out = out.replace("white board", "whiteboard").replace("reg ex", "regex").replace("in viscid", "inviscid")
    return out.split()


NIQQUD = re.compile(r"[֑-ׇ]")


def norm_he(s):
    s = unicodedata.normalize("NFKC", s)
    s = NIQQUD.sub("", s).lower()
    s = re.sub(r"[-–—־/]", " ", s)
    s = re.sub(r"[^\w\s]", " ", s)
    return [NUM.get(w, w) for w in s.split()]


def edits(a, b):
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
            prev = cur
    return d[len(b)]


def score_one(item, hyp):
    he = item["lang"] == "he"
    n = norm_he if he else norm_en
    r, h = n(item["ref"]), n(hyp)
    rc, hc = "".join(r), "".join(h)
    terms = item.get("terms") or []
    hit = 0
    hj = " ".join(h)
    for t in terms:
        tn = " ".join(n(t))
        hit += tn in hj or tn.replace(" ", "") in hj.replace(" ", "")
    return {"we": edits(r, h), "wn": len(r), "ce": edits(rc, hc), "cn": len(rc), "th": hit, "tn": len(terms),
            "exact": r == h}


def main():
    args = [a for a in sys.argv[1:]]
    by = "cond"
    show = 0
    only = None
    md = False
    if "--by" in args:
        i = args.index("--by"); by = args[i + 1]; del args[i:i + 2]
    if "--show" in args:
        i = args.index("--show"); show = int(args[i + 1]); del args[i:i + 2]
    if "--only" in args:
        i = args.index("--only"); only = set(args[i + 1].split(",")); del args[i:i + 2]
    if "--md" in args:
        args.remove("--md"); md = True
    manifest = {}
    for line in open(args[0]):
        m = json.loads(line)
        manifest[m.get("key", m["id"])] = m
    engines = []
    for spec in args[1:]:
        name, path = spec.split("=", 1)
        res = {}
        for line in open(path):
            r = json.loads(line)
            res[r.get("key", r.get("id"))] = r
        engines.append((name, res))
    groups = defaultdict(lambda: defaultdict(lambda: defaultdict(float)))
    times = defaultdict(list)
    misses = defaultdict(list)
    for key, item in manifest.items():
        cond = item.get("cond", "clean")
        if only and cond not in only:
            continue
        lang = item["lang"]
        kind = item["kind"]
        g = {"cond": f"{cond}", "voice": f"{item['voice']}", "kind": kind}[by]
        g = ("he " if lang == "he" else "") + g
        for name, res in engines:
            if key not in res:
                continue
            s = score_one(item, res[key]["hyp"])
            acc = groups[g][name]
            for k, v in s.items():
                acc[k] += v
            acc["n"] += 1
            if "ms" in res[key]:
                times[name].append(res[key]["ms"])
            if not s["exact"]:
                misses[name].append((s["we"], key, item["ref"], res[key]["hyp"]))
    names = [n for n, _ in engines]
    if md:
        print("| " + by + " | " + " | ".join(names) + " |")
        print("|---|" + "---|" * len(names))
    else:
        print(f"{by:<18}" + "".join(f"{n:>22}" for n in names))
    for g in sorted(groups, key=lambda x: (x.startswith("he "), x)):
        cells = []
        for n in names:
            a = groups[g].get(n)
            if not a or not a["wn"]:
                cells.append("-"); continue
            wer = 100 * a["we"] / a["wn"]
            cell = f"{wer:.1f}"
            if a["tn"]:
                cell += f" t{100 * a['th'] / a['tn']:.0f}"
            if g.startswith("he "):
                cell += f" c{100 * a['ce'] / a['cn']:.0f}"
            cells.append(cell)
        if md:
            print(f"| {g} | " + " | ".join(cells) + " |")
        else:
            print(f"{g:<18}" + "".join(f"{c:>22}" for c in cells))
    print("(WER %; t = key terms right %; c = Hebrew character error %)")
    for n in names:
        t = sorted(times[n])
        if t:
            print(f"{n}: finalize median {t[len(t) // 2]:.0f} ms, p90 {t[int(len(t) * 0.9)]:.0f} ms over {len(t)} clips")
    if show:
        for n in names:
            print(f"\n— {n}: worst")
            for we, key, ref, hyp in sorted(misses[n], reverse=True)[:show]:
                print(f"  {key}: {ref!r} → {hyp!r}")


if __name__ == "__main__":
    main()
