# Advanced Blocking: block lists in less memory

Patches for `Apps/AdvancedBlockingApp/App.cs` of [TechnitiumSoftware/DnsServer](https://github.com/TechnitiumSoftware/DnsServer),
the Docker lab that measures them against the original, and the records behind every number.

The app keeps each block list as a `HashSet<string>`. With the 23 public lists of the lab (2.5 M entries) the
original holds about 250-300 MiB of anonymous memory once the lists are loaded and peaks at about 500-560 MiB
while it reloads them. Three changes, all inside `App.cs`, bring that down by 2x to 5x:

| patch | diff | file growth | what the list sets hold | exact |
|---|---|---|---|---|
| [`hash64-set`](patch/experiments/hash64-set/0001-hash64-set.patch) | +56 / -32 | +24 lines (1.4%) | a `HashSet<ulong>` of the 64-bit FNV-1a hash of each name, filled while the list is parsed, presized from the file size | no |
| [`hash64-index2`](patch/experiments/hash64-index2/0001-hash64-index2.patch) | +101 / -32 | +69 lines (4.0%) | the same hashes in a sorted `List<ulong>` with a `uint[]` prefix index (about 8 hashes per start) | no |
| [`exact-tags`](patch/experiments/exact-tags/0001-exact-tags.patch) | +160 / -27 | +133 lines (7.7%) | the names themselves, grouped by hash bucket, with one hash byte per entry | yes |

`App.cs` has 1,729 lines at upstream `master` `0dd592a`. The patches apply to `master` and to `develop` (`5ed3d47`).
They do not apply on top of the open upstream PR #2179, which rewrites the ad-block parsing in the same file.

## Results

No container memory limit anywhere. Ratios are original over candidate (higher is better); every figure is paired
with an original measured on the same machine. Memory is cgroup `anon` after the last list is parsed, the reload
peak is cgroup `memory.peak` after the lists are touched on disk, p50 is the candidate against its own original.

**GitHub Actions, amd64 and arm64**, median of three runs ([41611257103](results/ci-compare/run-41611257103.md),
[41679672111](results/ci-compare/run-41679672111.md), [41679820344](results/ci-compare/run-41679820344.md)); the
ratio varies by at most 0.13x between them:

| patch | anon (MiB) amd64 / arm64 | ratio | reload peak ratio | p50 | qps |
|---|---|---|---|---|---|
| `hash64-set` | 86.9 / 136.6 (original 256.6 / 303.6) | 2.95x / 2.22x | 2.31x / 2.09x | -0.1% / 0.0% | +0.3% / +1.0% |
| `hash64-index2` | 55.9 / 105.4 (256.8 / 302.6) | 4.59x / 2.87x | 3.26x / 2.76x | +0.4% / -2.1% | -0.5% / +2.3% |
| `exact-tags` | 93.2 / 143.2 (256.7 / 302.6) | 2.75x / 2.12x | 2.17x / 2.01x | +2.6% / +4.7% | -2.5% / -3.5% |

**Local, one session, amd64** (`results/session-amd64-12`; original 272.5 MiB, reload peak 535.4):

| patch | anon | ratio | reload peak ratio | p50 | qps |
|---|---|---|---|---|---|
| `hash64-set` | 82.9 | 3.29x | 2.46x | -0.2% | +0.4% |
| `hash64-index2` | 49.7 | 5.48x | 3.58x | -7.2% | +10.6% |
| `exact-tags` | 89.3 | 3.05x | 2.35x | -0.3% | +1.6% |

**Real board, Orange Pi Zero 3** (1 GiB RAM, aarch64, `lab/on-device.sh`, `results/session-device`; original 260.6 MiB,
reload peak 451.8, original p50 206.3-207.5 µs):

| patch | anon | ratio | reload peak ratio | p50 | qps |
|---|---|---|---|---|---|
| `hash64-set` | 79.5 | 3.28x | 2.14x | +0.2% | -3.1% |
| `hash64-index2` | 46.1 | 5.65x | 3.15x | -0.3% | +1.8% |
| `exact-tags` | 84.0 | 3.10x | 1.99x | +3.6% | -3.2% |

The board runs with its serving container stopped and a guard on swap traffic; the original is not queried for the 500
TXT reports there (that pass drove it into swap until the SoC watchdog reset the board once, see
`results/device-incidents`). An earlier memory-only session on the same board is in `results/session-device-memory-only`;
its reload peaks differ from this one by up to 40%, so read them as a range.

Latency differences of a few percent are inside the noise of this harness: in the local session the original's own p50
was 260.0 µs in the rounds paired with `hash64-index2` and 238-243 µs in the others, which is where its -7.2% comes
from. Lookup cost in isolation (`lab/lookup-bench`, `results/lookup-bench`, CI amd64 / arm64): a hit / miss costs
50 / 31 ns and 160 / 136 ns in a `HashSet<ulong>`, 197 / 67 ns and 407 / 169 ns in the original `HashSet<string>`, and
142 / 143 ns and 305 / 310 ns in a binary search over the sorted 16 MiB array, which is why the sorted list needs the
prefix index (21 / 26 ns and 57 / 56 ns).

## Same answers

On every CI leg the original and the candidate return the same response for: an A and a TXT query for each of the
2,159,642 listed domains, the 192 domains covered by the allow lists, 500 sampled reports, 12 edge cases (hosts and
ad-block formats, `@@` exceptions, regex, a list of 17,576 four-character names that makes the capacity guess short)
and 240,716 near-miss names (typos, other top-level domains, parents, upper case). The digests are equal and the
differences are 0. The same battery runs locally with `lab/correctness.sh` on 2,292,180 names, plus a hosts-format
differential on 601,786 (`results/correctness-amd64`), and each structure has a reflection unit check
(`results/unit-checks`).

## False matches

The hash patches are not exact. A name that is not listed is reported as listed when its 64-bit hash equals a stored
one: about 3 x N / 2^64 per query of three labels, 4e-13 with these lists. A listed name always matches. The basis
of the hash is random per process, so the names that collide change at every start. The hash was tested rather than
assumed random (`lab/hash-risk`, `results/hash-risk`). `exact-tags` has no false matches.

## Reproduce

Needs Docker, Python 3, `git` and `ss`. The lab uses ports 15353 and 15380 on 127.0.0.1 and refuses to start next to
a resolver on port 53.

```sh
lab/fetch-lists.sh                                        # 23 public lists into lab/lists/
lab/build-app.sh original                                 # clones the pinned upstream commit into lab/.work/
PATCH_DIR=patch/experiments/hash64-set lab/build-app.sh patched
RUN_TAG=-run1 lab/run-lab.sh original && RUN_TAG=-run1 lab/run-lab.sh patched
lab/session-bench.sh start                                # several candidates in one session
lab/session-bench.sh cand hash64-set patch/experiments/hash64-set
lab/session-bench.sh end && python3 lab/session-table.py results/session-local
```

`PATCH_DIR` is relative to the repository root.

| to reproduce | run |
|---|---|
| the same answers as the original | `HOSTS=1 lab/correctness.sh patch/experiments/hash64-set results/correctness-amd64/hash64-set` |
| the unit check of a structure | `lab/hash-test.sh`, `lab/hash-index-test.sh`, `lab/name-set-test.sh`, `lab/domain-set-test.sh` (after building that patch) |
| where the memory goes | `lab/decompose.sh` |
| a small container | `lab/small-limits.sh start patch/experiments/hash64-set 160m 128m` (or `reload`) |
| query stalls during a reload | `lab/stall-matrix.sh` |
| .NET runtime settings | `lab/runtime-options.sh` |
| the lookup cost of each structure | the `lookup-bench` workflow (`lab/lookup-bench`) |
| a real board | `lab/on-device.sh hash64-set=<dir with the built assembly> ...` (read its header first: it stops the serving container) |
| the CI | the `lab` workflow, manual dispatch, `only=` limits it to some candidates; per platform it runs the startup, reload, latency, exhaustive A and TXT, near-miss and edge steps and `lab/compare-ci.py` fails the leg on any difference. `gh run download` then `lab/ci-record.sh` stores a run |

## Layout

- `patch/experiments/` every candidate (`hash64-set`, `hash64-index2`, `exact-tags` and the others in the log)
- `lab/` the harness, the lookup benchmark and the unit checks
- `results/` the records behind every table (`ci-compare/run-<id>.md` is the table, `.tar.gz` the raw legs)
- `docs/attempts.md` every attempt, with line counts, numbers and the verdict; `docs/research/` the notes read for it

## Limits

- Without a container limit the memory the .NET GC leaves behind depends on the machine. In a run of 25 candidates 5
  of the 24 amd64 legs that completed had an original holding 283-289 MiB instead of 253-257, and the candidates held
  tens of MiB more there (`hash96-presize` 129 MiB against 64 for the equivalent `hash96-list` and `hash96-split` on
  other legs); none of the 9 amd64 finalist legs did. Ratios are paired per leg but differ with that (`docs/attempts.md`
  2.4); the cause (a different runner type) is inferred, not isolated.
- The board figures are one session each for latency; its reload peak varied by up to 40% between two sessions.
- `BlockListZoneManager` (the built-in lists) and the regex lists are not touched.
- The old and the new list coexist during a reload: the peak falls by 2x to 3.6x, the 2x remains in kind.
- The logged "(N domains)" of `hash64-set` becomes the number of distinct names.
