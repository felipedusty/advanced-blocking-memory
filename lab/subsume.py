"""How many list entries have a parent in the same list (or in the union of the lists).

Run from the repository root after lab/fetch-lists.sh:

    python3 lab/subsume.py

An entry such as ads.example.com is redundant for blocking when example.com is in the same
set, because a lookup walks the parent labels. Dropping those entries would not change any
blocking decision. The parser follows the Advanced Blocking app for the ||domain^ lists (the
only kind in the lab configuration): domains accepted by the rule forms and a conservative
domain-name check; it is not byte for byte the app's DnsClient.IsDomainNameValid.
"""

import hashlib
import json
import os
import re

CONFIG = os.environ.get("LAB_CONFIG", "lab/config/dnsApp.config")
valid = re.compile(r"^[A-Za-z0-9_/*-]+(\.[A-Za-z0-9_/*-]+)*$")


def parse(path):
    blocked, allowed = [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\r\n").lstrip(" \t")
            if not line or line.startswith("!"):
                continue
            for prefix, dest in (("||", blocked), ("@@||", allowed)):
                if line.startswith(prefix):
                    rest = line[len(prefix) :]
                    i = rest.find("^")
                    if i > -1:
                        dom, opt = rest[:i], rest[i + 1 :]
                        ok = opt == "" or (
                            opt.startswith("$") and ("doc" in opt or "all" in opt)
                        )
                    else:
                        dom, ok = rest, True
                    if ok and len(dom) <= 255 and valid.match(dom):
                        dest.append(dom)
                    break
    return blocked, allowed


def subsumed(names):
    unique = set(names)
    count = 0
    for domain in unique:
        parent = domain
        while "." in parent:
            parent = parent.split(".", 1)[1]
            if parent in unique:
                count += 1
                break
    return len(unique), count


with open(CONFIG) as f:
    cfg = json.load(f)
rows = []
union = set()
totals = [0, 0, 0]
for group in cfg["groups"]:
    for key in ("adblockListUrls", "allowListUrls"):
        for url in group.get(key, []):
            if isinstance(url, dict):
                url = url["url"]
            path = "lab/lists/" + hashlib.sha256(url.encode()).hexdigest()
            blocked, allowed = parse(path)
            unique_b, subsumed_b = subsumed(blocked)
            unique_a, subsumed_a = subsumed(allowed)
            rows.append(
                (
                    url.rsplit("/", 1)[1],
                    len(blocked),
                    unique_b,
                    subsumed_b,
                    len(allowed),
                    unique_a,
                    subsumed_a,
                )
            )
            totals[0] += len(blocked)
            totals[1] += unique_b
            totals[2] += subsumed_b
            if key == "adblockListUrls":
                union.update(blocked)

print(
    f"{'list':44s} {'blocked':>9s} {'unique':>9s} {'subsumed':>9s} {'%':>6s}  allowed/unique/subsumed"
)
for r in sorted(rows, key=lambda r: -r[1]):
    pct = 100.0 * r[3] / r[2] if r[2] else 0
    print(f"{r[0]:44s} {r[1]:9d} {r[2]:9d} {r[3]:9d} {pct:5.1f}%  {r[4]}/{r[5]}/{r[6]}")
print(
    f"TOTAL entries {totals[0]}  unique per list {totals[1]}  subsumed in their own list {totals[2]} ({100.0 * totals[2] / totals[1]:.1f}%)"
)
unique_union, subsumed_union = subsumed(union)
print(
    f"UNION of the block lists: {unique_union} unique, {subsumed_union} with a parent in the union ({100.0 * subsumed_union / unique_union:.1f}%)"
)
