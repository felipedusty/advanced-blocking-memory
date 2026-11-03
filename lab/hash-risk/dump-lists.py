#!/usr/bin/env python3
"""Write the block domains of a lab checkout for the risk lab: one file per list and union.txt.

    python3 lab/hash-risk/dump-lists.py <lab-checkout> <out-dir>    (out-dir absolute)

<lab-checkout> is a checkout of advanced-blocking-memory after lab/fetch-lists.sh.
The domains are the ones lab/exhaustive.py extracts, so they follow the app's
parse rules and exclude names an allow list covers. union.txt holds the unique
entries across the lists.
"""
import os
import sys

root, out = sys.argv[1], sys.argv[2]
os.chdir(root)
sys.path.insert(0, "lab")
import exhaustive as ex

per_list, _covered = ex.extract_block_domains()
os.makedirs(out, exist_ok=True)
for index, (_path, domains) in enumerate(sorted(per_list.items())):
    with open(os.path.join(out, f"{index:02d}.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(domains)) + "\n")

union = set().union(*per_list.values())
with open(os.path.join(out, "union.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(sorted(union)) + "\n")

print(f"{len(per_list)} lists, {sum(len(d) for d in per_list.values())} entries, {len(union)} unique")
