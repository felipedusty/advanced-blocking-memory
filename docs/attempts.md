# Everything tried, with numbers

Living log of every change tried on the Advanced Blocking list memory, what it did, how it was
built and measured, and what came out. **Lines** are `git apply --numstat` of the patch against
upstream `master` `0dd592a` (added / removed, `App.cs` only). **Ratios** are original over
candidate, higher is better. Every number below comes from a record in `results/` (named per
row); a number without a record is marked *unverified*. Update this file with every new attempt.

Setup common to all rows: official `technitium/dns-server:15.6.2` image (.NET 10.0.13), 23 public
lists, memory is cgroup `anon` after the last list is parsed (20 s settle), peaks are cgroup
`memory.peak`, reload = lists touched on disk so the app rebuilds them. Each candidate replaces only
`AdvancedBlockingApp.dll`. Correctness: A and TXT query for every listed name, allow-covered names,
500 sampled reports, near-miss names, edge cases (see `README.md` and `lab/`).

**Container memory limit.** There is none, anywhere, except in the small-container checks (2.5) where the limit is the
variable: `lab/run-lab.sh` and `lab/run-reload.sh` run without one unless `MEM` is set, and `lab/compare-ci.py` expects
none. A limit is a property of one deployment, not of the software. An earlier setup of the lab used a 640 MiB limit;
none of its records is used here. The memory depends on the machine it ran on (2.4), so every figure is paired with an
original on the same machine.

Lists: **MiB do not compare across list sets, ratios do.** The CI legs download the lists of the day (2026-11-03: 2.54 M
entries, 2,159,642 distinct listed names; each leg records `lists.sha256`); the local runs use the lists of 2026-10-28
(2.67 M entries, 2,292,180 listed names, original 269-277 MiB).

## 1. The problem and where the memory goes

| piece | MiB | how measured |
|---|---|---|
| original `HashSet<string>`, 2.67 M entries | 276.9, 269.2 anon (reload peak 535.4) | `lab/decompose.sh`; `session-amd64-12` |
| server with no lists | 22.0, 21.4 | `lab/config/dnsApp.empty.config` (`no-lists` in `lab/decompose.sh`) |
| parse only, hashes thrown away | 28.4, 28.6 | `parse-only` patch |
| 2.67 M hashes of 8 bytes | 20.4 | arithmetic |

Cause in the app: one `string` (UTF-16 + header) plus one set entry per name, about 80 B, and a
reload builds the new set before the old is freed. Maintainer statements (#1435, #2030,
#2211) confirm the 2x and the cost; he keeps lists in memory on purpose (#1604) and one set per
list on purpose (#1003).

## 2. Attempts, in order, with results

### 2.1 Exact sets of names

CI columns: steady `anon` ratio amd64 / arm64, reload-peak ratio, p50 against the candidate's own original, from
`results/ci-compare/run-41660450951.md` (all candidates but the three finalists, no limit, one run each; the finalists
are in 2.9). Local column: `lab/decompose.sh` (2.3), anon MiB of two startups. Read the CI rows with 2.4: a leg that
ran on the faster runner type is marked, and arm64 p50 moves by about 5% between builds that change nothing.

| name | lines | what it is, how | CI | local anon | verdict |
|---|---|---|---|---|---|
| `exact` (`DomainSet`) | +256 / -29 | names as UTF-8 in one `byte[]` with a length byte, sorted `int[]` of offsets, binary search, a Bloom filter in front (10 bits per entry, 7 hashes); capacity reserved from the file length so it is not copied at sort | 2.43x / 2.11x, 2.10x / 2.02x, +0.6% / +6.8% | 96.0, 89.5 | exact, same responses on CI; boundary test `lab/domain-set-test.sh` (not rerun in this setup) |
| `exact-frontcoded` | +334 / -29 | the sorted names stored in blocks of 16 that drop the prefix shared with the previous name | 2.19x / 1.82x, 1.78x / 1.70x, +1.2% / +0.5% | | no gain over `exact` for +78 lines |
| `exact-frontcoded-gc` | +338 / -29 | the same plus `LargeObjectHeapCompactionMode = CompactOnce; GC.Collect()` after each list load | 2.12x / 2.51x (the amd64 leg's original held 288.8 MiB), 2.01x / 2.16x, +4.9% / -3.7% | | **dropped**: the biggest diff, and a blocking GC of the kind #2174 fixed (4) |
| `exact-csr` | +147 / -27 | names as ASCII in one `byte[]` grouped by hash bucket plus `int[]` of bucket starts; a lookup compares ~4 short names; boundary test `lab/name-set-test.sh` with a mutant that ignores the stored length (fails 4 checks) | 2.13x / 1.79x, 1.83x / 1.73x, +3.4% / +8.0% | 119.4, 114.1 | the loader garbage, not the structure, dominates (2.3) |
| `exact-csr-gc` | +151 / -27 | `exact-csr` plus the compaction step after each `Seal()` (diagnostic: is the old names buffer the garbage?) | | 112.2, 112.2 | the compaction recovers 2-7 MiB, so "the old buffer is the garbage" was **wrong**; why `exact-csr` holds ~90 MiB above the server for 45 MiB of names was not found |
| `exact-offsets` | +145 / -27 | like `exact-csr` but the names stay where they were added; `Seal()` builds an `int[]` of offsets grouped by hash bucket with a counting pass (no copy of the names, no sort); `Contains` hashes, then compares ~4 names through their offsets | 2.79x / 2.16x, 2.24x / 2.02x, +3.8% / +8.4% | | the smallest exact patch before the tags, slower on lookup than `exact` |
| `exact-tags` | +160 / -27 | `exact-offsets` plus one byte of the bucket hash per entry in a parallel `byte[]` (+2.7 MiB): `Contains` scans the bytes of one bucket and dereferences a name only when the byte matches, so a miss (the common lookup) costs the bucket start and one cache line | see 2.9 | 90.2, 89.2 | **finalist**: the exact candidate to propose if no hash is acceptable; boundary test (200,000-entry differential) and the full battery identical (2.8) |
| `exact-hashset-int` | +186 / -29 | names in a `byte[]`, a `HashSet<int>` of offsets queried through `GetAlternateLookup` | | 117.1, 117.2 | 70 lines fewer than `exact` but 20-28 MiB more (117 against 90-96) |
| `original-presize` | +16 / -29 | the original `HashSet<string>` fed from a `List<string>` with capacity `file size / 8` instead of a `Queue` | 1.08x / 1.04x, 1.03x / 1.02x, +1.2% / +5.3% | 275.1, 259.1 | **no gain**: the strings dominate |
| `control` (yardstick) | +3 / -0 | the original plus an unused constant | 1.00x / 1.00x, 1.01x / 1.00x, +0.7% / -0.1% | | the noise floor of the harness |
| `original-gc` (yardstick) | +4 / -0 | the original plus the 4-line GC step alone | 1.07x / 1.06x, 1.04x / 1.07x, +0.0% / +4.1% | | the GC step buys 7% on a heap of strings |

Rows of the first setup that are not repeated here, because their records are not kept: `exact-csr` without the
file-length pre-allocation (it was worse, 136.5 against 110.4 MiB in three local runs), and the `DomainSet` variants
sorted-only, compact-hash and open-addressing offset table (none better than `exact`).

### 2.2 Hash sets, not exact

Hash: 64-bit FNV-1a (`(h ^ c) * 1099511628211`) over the UTF-16 chars, **basis random per
process** from `RandomNumberGenerator`; wide keys add a second lane (multiplier
`0x9E3779B97F4A7C15`, own random basis). The second lane costs one bit (the two lanes share a
parity bit), hence 127 bits for 128. Same-multiplier lanes are *not* independent (joint
collisions 100x to 8,000x the ideal); an xorshift step per character was up to 19.9x worse.
Tests: `lab/hash-risk`, `results/hash-risk/`.

Columns as in 2.1: CI = anon ratio amd64 / arm64, reload-peak ratio, p50 (`results/ci-compare/run-41660450951.md`,
except where marked); local = `lab/decompose.sh` anon MiB of two startups. "Fast leg" marks an amd64 leg whose original
held 283-289 MiB instead of 253-257, the faster runner type of 2.4: the candidate holds more there too, so the ratio
is lower than the same build gets elsewhere.

| name | lines | what it is | CI | local anon | verdict |
|---|---|---|---|---|---|
| `hash64` | +55 / -18 | the 64-bit hash in a `HashSet<ulong>` (~20 B/entry), filled from the `Queue` | 2.33x / 1.90x, 1.97x / 1.90x, +0.9% / +6.0% | | the first hash version |
| `hash64-gc` | +59 / -18 | + the 4-line GC step | 2.36x / 2.04x, 2.08x / 1.99x, +2.1% / +0.4% | | the GC step buys little here too |
| `hash128` | +61 / -18 | two lanes in a `HashSet<(ulong, ulong)>` (24 B entry) | 1.82x / 1.60x, 1.55x / 1.50x, +1.4% / +2.0% | | a wide key in a `HashSet` costs more than its bytes |
| `hash96` (`hash96-tuple3`) | +61 / -18 | 64 + 32 bits in a `ValueTuple<uint,uint,uint>` (16 B in .NET) | 1.82x / 1.60x, 1.54x / 1.50x, +1.7% / +2.7% | 159.5, 168.3 | the same memory as 128 bits |
| `hash128-open` / `-gc` | +112 / -27, +116 / -27 | linear-probing table of 16-byte slots (Cloudflare `mmuniq-hash` design) | 1.64x / 1.48x, 1.69x / 1.59x, +0.5% / -1.5%; `-gc` 1.49x (fast leg) / 1.69x, 1.64x / 1.75x, -2.1% / -3.2% | | the structure is not the limit (2.3) |
| `hash64-sorted` | +59 / -26 | the hashes in a sorted `ulong[]` (`Queue<ulong>` -> `ToArray()` -> `Array.Sort`), `Span.BinarySearch` | 2.08x (fast leg) / 2.49x, 2.15x / 2.41x, +3.3% / +7.9% | 68.8, 86.0 | 8 B/entry, but the loader garbage stays (2.3) |
| `hash64-sorted-gc` | +61 / -26 | + `GC.Collect(2, Forced, true, true)` after each list | | 72.8, 72.8 | a full collection does not give it back |
| `hash64-presize` | +68 / -29 | a `List<ulong>` with `Capacity = file size / 8` (allocated once, grows if short), `CollectionsMarshal.AsSpan(list).Sort()` / `.BinarySearch` | 4.72x / 2.92x, 3.29x / 2.78x, +1.0% / +7.4% | 48.3, 50.4 | the loader was the limit (2.3) |
| `hash96-presize` | +93 / -29 | the presized list of a 12-byte `struct` (`Pack = 4`): lane A (64) + top 32 bits of lane B | 2.23x (fast leg) / 2.66x, 2.37x / 2.52x, +6.6% / +8.6% | | |
| `hash128-presize` | +73 / -29 | the presized list of `UInt128` | 3.50x / 2.46x, 2.62x / 2.32x, +3.1% / +6.7% | | |
| `hash96-list`, `hash128-list` | +103 / -29, +83 / -29 | line count instead of file size for the capacity | 4.03x / 2.67x, 2.86x / 2.54x, +3.5% / +7.5%; 2.06x (fast leg) / 2.46x, 2.12x / 2.34x, +6.4% / +12.2% | 58.7, 58.7; 68.7, 68.6 | a wider key costs about 10 MiB per 32 bits |
| `hash64-list` | +78 / -29 | capacity from the line count (a pass over the file) | | 49.1, 48.4 | same as file size / 8 |
| `hash64-buckets` | +95 / -32 | 256 small arrays by the top 8 bits of the hash | | 67.1, 67.1 | **no help** |
| `hash96-split` | +135 / -29 | the 64 bits in a sorted `ulong[]`, the other 32 in a parallel `uint[]` read only on a match (`Array.Sort(keys, items)`) | 3.98x / 2.66x, 2.88x / 2.52x, +2.7% / +5.8% | | no gain over the struct list (`hash96-list` 4.03x / 2.67x) for +32 lines: the 12-byte element was not a cost. Dropped |
| `hash80-split` | +135 / -29 | as above with 16 extra bits (`ushort[]`): 80 bits, 10 B/entry | 2.30x / 2.78x, 2.38x / 2.63x, +2.3% / +9.8% (re-run `results/ci-compare/run-41675454957.md`: the amd64 leg of the big run was lost to a runner failure; its arm64 leg gave 2.81x, +5.2%) | | false match about 6e-18 per query; a bigger diff for no clear gain |
| `hash64-index` | +124 / -29 | the sorted `ulong[]` plus a `uint[]` index of the first position of each value of the top bits (about 4 hashes per value, as Blocky's `hashSet`) | 4.48x / 2.84x, 3.17x / 2.70x, +2.7% / +3.0% | | superseded by `hash64-index2` (26 net lines fewer, 8 hashes per start) |
| `hash64-interp` | +94 / -29 | `hash64-presize` with an interpolation search (4 steps over the evenly spread hashes, then a binary search) | 4.71x / 2.93x, 3.25x / 2.83x, +4.9% / +3.7% | | no p50 gain in the app although the microbenchmark (2.6) puts it at 74 / 87 ns against 142 / 143 ns for the binary search. Dropped |
| `hash64-presize16` | +69 / -29 | `hash64-presize` with the capacity guess `file size / 16` instead of `/ 8` (a domain takes 16-25 bytes in a list file, so it is ~1.3x the need instead of 2.5x) | 4.72x / 2.91x, 3.24x / 2.77x, +1.4% / +4.4% | | the same memory; the smaller guess is the one `hash64-set` and `hash64-index2` use |
| `hash64-index2` | +101 / -32 | a `HashIndex` class: the list sorted in place plus a `uint[]` with the first position of each value of the top bits (about 8 hashes per start, 1.5 bytes per entry), `Contains` binary-searches only that slice; `LoadListZone` becomes `new HashIndex(ReadListFile())`; capacity `file size / 16` | see 2.9 | 49.1, 49.4 | **finalist**: the largest saving; the optional second step |
| `hash64-set` | +56 / -32 | the original's own shape with `HashSet<ulong>` of the 64-bit hash instead of `HashSet<string>`, filled while parsing (no `Queue`), `EnsureCapacity(file size / 16)`; `Contains(GetDomainHash(domain))`. The logged "(N domains)" becomes the distinct count (`lab/check-edge.sh` accepts 5 or 6 for the hosts fixture) | see 2.9 | 83.2, 84.7 | **finalist**: the smallest diff (net +24 lines), the proposal to lead with |
| `hash64-set-nocap` | +54 / -32 | `hash64-set` without the two `EnsureCapacity` lines (the set grows by itself) | | 130.7, 131.8 | the hint is worth 47 MiB: the "obvious" simplification costs a third of the saving. Dropped |

### 2.3 Where the memory goes (decomposition, local amd64, no limit, anon MiB)

`lab/decompose.sh` (two startups per build, `results/decomposition-amd64/`; local lists of 2026-10-28, 2.67 M entries,
so the MiB do not compare with the CI tables). Two runs of the same build differ by up to 17 MiB in this table
(`hash64-sorted`), so differences under about 10 MiB are not resolved.

| build | anon (two runs) | what it says |
|---|---|---|
| no lists (`dnsApp.empty.config`) | 22.0, 21.4 | floor of the server |
| original | 276.9, 269.2 | |
| `original-presize` | 275.1, 259.1 | the original `HashSet<string>` fed from a presized list: no clear gain, the strings dominate |
| `parse-only` (hashes thrown away) | 28.4, 28.6 | parsing garbage is ~6 MiB, not 25 |
| `hash64-sorted` | 68.8, 86.0 | 20 MiB of hashes + loader garbage (a `Queue` of hashes, then `ToArray`) |
| `hash64-sorted-gc` (+ `GC.Collect(2, Forced, true, true)` after each list) | 72.8, 72.8 | a full collection does not give it back |
| `hash64-buckets` (256 small arrays) | 67.1, 67.1 | no help |
| `hash64-list` (capacity from the line count, allocated once) | 49.1, 48.4 | the loader, not the structure, was the limit |
| `hash64-presize` (capacity `file size / 8`) | 48.3, 50.4 | slack that is never written is not resident |
| `hash64-set` | 83.2, 84.7 | a `HashSet<ulong>` of the hash: 20 B per entry |
| `hash64-set-nocap` (no `EnsureCapacity`) | 130.7, 131.8 | the hint is worth 47 MiB |
| `hash64-index2` | 49.1, 49.4 | sorted list + prefix index |
| `hash96-list`, `hash128-list` | 58.7, 58.7 and 68.7, 68.6 | a wider key costs about 10 MiB per 32 bits |
| `exact` / `exact-csr` / `exact-tags` | 96.0, 89.5 / 119.4, 114.1 / 90.2, 89.2 | |

The mechanism behind `hash64-sorted` against `hash64-list` (abandoned doubling buffers stay committed, a collection
without LOH compaction does not return them) is an **inference** from these rows; `instr-sorted` (patch kept)
logged the GC counters after each list, and its record belongs to the first setup and is not kept.

### 2.4 Noise: repeats, the yardsticks, and the runner type

**Finalists, three CI runs each** (`run-41611257103`, `run-41679672111`, `run-41679820344`, all legs on the usual runner
type, the original at 254-257 MiB on amd64 and 302-306 on arm64). Anon ratio, amd64 / arm64: `hash64-set` 2.83-2.96x /
2.20-2.23x, `hash64-index2` 4.55-4.62x / 2.87-2.89x, `exact-tags` 2.72-2.76x / 2.10-2.14x. p50 against the candidate's
own original: `hash64-set` -1.3% to +1.7% / -1.3% to +2.6%, `hash64-index2` -0.2% to +0.6% / -4.8% to +0.2%,
`exact-tags` -0.1% to +2.7% / +1.7% to +7.1%. The memory ratios repeat to within 0.13x; **p50 on arm64 moves by up to
5% between runs of the same build**, so arm64 differences of a few percent between candidates are not resolved by one
run. Medians of the three runs are in 2.9 and the README. `exact-tags` is the only finalist with a p50 above zero on
both architectures in the median (+2.6% / +4.7%, qps -2.5% / -3.5%); `hash64-set` and `hash64-index2` are flat.

**Yardsticks** (builds that change nothing or nearly nothing, one run, 2.1): `control` p50 +0.7% / -0.1%, `original-gc`
+0.0% / +4.1%, `original-presize` +1.2% / +5.3%. On arm64 a no-op build moves p50 by up to 5%.

**Runner type, amd64.** In the run of 25 candidates (`run-41660450951`) 5 of the 24 amd64 legs that completed had an
original holding 283-289 MiB (`exact-frontcoded-gc` 288.8, `hash64-sorted` 288.1, `hash128-open-gc` 288.5,
`hash96-presize` 288.5, `hash128-list` 283.2) while the other 19 held 253-257. On those legs the candidates held much
more than their equivalents elsewhere: `hash96-presize` 129.2 MiB against 63.9 for `hash96-list` and 64.5 for
`hash96-split`, `hash128-list` 137.4 against 73.4 for `hash128-presize`. The original on arm64 held 302-306 MiB on
every leg of every run. The absolute amd64 p50 ranged from 41 to 144 µs between legs, which is why every figure is
paired with an original on the same machine. The job logs that record the CPU model were not retrievable, so the
explanation (a different runner type, with the .NET GC sizing its young generation from the CPU's cache) is an
**inference**. It does mean the ratio of a build depends on where it ran.

Local sessions of this setup: `session-amd64-12` (the three finalists; the original at the start and the end 275.8 and
269.1 MiB, a 2.5% drift inside the session; the original's p50 was 260.0 µs in the rounds paired with `hash64-index2` and
238-243 µs in the others, which is where that candidate's -7.2% comes from).

### 2.5 Small containers: what the original does when the limit is low (local amd64, `results/small-limits-amd64/`)

The limit is the variable here, so this is the one test that sets one (`lab/small-limits.sh`, docker `--memory`, no extra
swap). The .NET GC takes the container limit into account (heap hard limit, documented behaviour), so below a threshold
the original does not get OOM-killed: a list **fails to load** with `OutOfMemoryException` in `HashSet.Initialize` and
the app logs it and goes on. Start: 150 names of the biggest list (the 1.85 M-name list, one in 10,000) are asked for
their TXT report; a name another list also holds counts as blocked, so a missing list is understated. Reload:
`lab/run-reload.sh` under the same limit.

| limit | original | `hash64-set` | `hash64-index2` | `exact-tags` |
|---|---|---|---|---|
| 384 MiB, start | 150 of 150 | | | |
| 320 MiB, start | **43 of 150**, 1 OutOfMemoryException | | | |
| 256 MiB, start | **43 of 150**, 1 OutOfMemoryException | | | |
| 192 MiB, start | | 150 of 150 | | 150 of 150 |
| 160 MiB, start | | 150 of 150 | | 150 of 150 |
| 128 MiB, start | | 150 of 150 | 150 of 150 | 150 of 150 |
| 112 MiB, start | | **43 of 150**, 1 OutOfMemoryException | | **0 of 150**, no exception logged |
| 96 MiB, start | | **43 of 150**, 1 OutOfMemoryException | 150 of 150 | **0 of 150**, no exception logged |
| 80 / 72 MiB, start | | | 150 of 150 | |
| 64 MiB, start | | | **0 of 150**, no exception logged | |
| 384 / 320 MiB, forced reload | does not complete (45 of 46 / 23 of 46 list reads) | | | |
| 256 MiB, forced reload | | completes, cgroup peak 217.3 MiB | | completes, 229.1 MiB |
| 192 MiB, forced reload | | completes, 192.0 MiB | completes, 150.8 MiB | completes, 192.0 MiB |
| 160 MiB, forced reload | | does not complete (45 of 46 reads) | completes, 146.2 MiB | does not complete (the container exited) |
| 128 MiB, forced reload | | | completes, 128.0 MiB | |

A peak equal to the limit (192.0, 128.0) is probably page cache filling the container rather than what the app needed
(*an inference*: the cgroup counts file cache). "0 of 150, no exception logged" means no name was blocked and the log has
no `OutOfMemoryException`; the cause was not checked (the container may have been killed). The sampled names understate
the failure of the original. This is functional, not only a memory figure: with
the original on a 256-320 MiB container the biggest list is silently absent, and a reload does not complete at
384 MiB. **Not repeated in this setup**, so no record is kept: the capacity guess `file size / 8` (instead of `/ 16`)
made a 42 MiB array that counts against the heap limit even if never written, and failed at 80 MiB where `/ 16` does
not; it is why `hash64-set` and `hash64-index2` use `/ 16`. Not measured: the same on arm64, and a real small device.

### 2.6 Lookup microbenchmark (`lab/lookup-bench`, `.github/workflows/bench.yml`, `results/lookup-bench/`)

Lookup cost in isolation, on the biggest list (1,814,363 names), query hashes precomputed, 1 M lookups in random
order, median of 9 passes. ns per lookup, hit / miss. Both are 4-cpu runners (`ubuntu-24.04`, `ubuntu-24.04-arm`),
.NET 10.0.14; the figures are in `results/lookup-bench/` (run `results/lookup-bench/RUN.txt`).

| structure | B/entry | CI amd64 | CI arm64 |
|---|---|---|---|
| `HashSet<string>` (the original) | 80 | 197 / 67 | 407 / 169 |
| `HashSet<ulong>` (`hash64-set`) | 20 | 50 / 31 | 160 / 136 |
| sorted `ulong[]`, binary search (`hash64-presize16`) | 8 | 142 / 143 | 305 / 310 |
| sorted + interpolation (`hash64-interp`) | 8 | 74 / 87 | 175 / 194 |
| sorted + prefix index, 4 hashes per start | 9 | 21 / 25 | 73 / 84 |
| sorted + prefix index, 8 hashes per start (`hash64-index2`) | 8.6 | 21 / 26 | 57 / 56 |
| open addressing `ulong[]`, load 0.5 | 18.5 | 13 / 18 | 30 / 38 |

Reading: **a binary search over a 16 MiB array costs about twice a `HashSet<string>` miss** (143 against 67 ns
on amd64, 310 against 169 on arm64; about 21 steps, the last ones cache misses, *an inference*), which is the
latency cost of the sorted list without the index; the prefix index is 4-7x faster than the binary search and
faster than the original set on misses (the common case); an open-addressing table is faster still but needs 2x
the slots (and the hashes first, which is the transient the lead avoids). Index density, hashes per start (hit ns
on amd64 / arm64, bytes per entry): 1: 10 / 55 (12.6), 2: 14 / 54 (10.3), 4: 17 / 54 (9.2), **8: 21 / 57 (8.6)**,
16: 24 / 49 (8.3), 32: 29 / 50 (8.1), 64: 35 / 56 (8.1). The hash of a name (FNV-1a over the characters) costs
13 / 19 ns, `string.GetHashCode` 14 / 20 ns: the hash is not the cost.

### 2.7 Where it stands (the frontier, one row per shape)

CI, no limit, amd64 / arm64. The finalists are the median of three runs (2.4, 2.9); `hash64-presize16` and `exact` come
from the single run of 25 candidates (`results/ci-compare/run-41660450951.md`).

| shape | lines | CI anon ratio | CI p50 | exact | patch |
|---|---|---|---|---|---|
| `HashSet<ulong>` of the hash | +56 / -32 (net +24) | 2.95x / 2.22x | -0.1% / 0.0% | no | `hash64-set` |
| sorted `List<ulong>`, no index | +69 / -29 | 4.72x / 2.91x | +1.4% / +4.4% | no | `hash64-presize16` |
| sorted `List<ulong>` + prefix index | +101 / -32 (net +69) | 4.59x / 2.87x | +0.4% / -2.1% | no | `hash64-index2` |
| names by hash bucket + one hash byte | +160 / -27 | 2.75x / 2.12x | +2.6% / +4.7% | yes | `exact-tags` |
| sorted names + Bloom (`DomainSet`) | +256 / -29 | 2.43x / 2.11x | +0.6% / +6.8% | yes | `exact` |

`hash64-set` is the proposal to lead with (smallest diff, same shape as the original, no measurable latency cost);
`hash64-index2` is the optional second step (1.6x more memory saved on amd64 and 1.3x on arm64, for +45 lines, also
flat in latency); `exact-tags` is the exact fallback if no hash is acceptable, at a small but consistent latency cost.
Everything in 2.1-2.6 not in this table was dominated or not better.

### 2.8 Correctness of the three finalists (`hash64-set`, `hash64-index2`, `exact-tags`)

Local, amd64, no container memory limit: `HOSTS=1 lab/correctness.sh patch/experiments/<name> results/correctness-amd64/<name>`
(log: `results/correctness-amd64/battery.log`). The original and the candidate answer the same queries and every
listed key is equal, with 0 errors, for each of the three:

| probe | what it covers | result (original = candidate) |
|---|---|---|
| A and TXT query for each of 2,292,180 listed names, 175 allow-covered names (`lab/exhaustive.py`) | the ad-block parser (`||domain^`, `@@||`), the allow lists | digests `81817805df6f35cd` (A), `484d84857aa6767b` (TXT), `191737ebd76058b9` (allow) |
| 240,574 near-miss names (`lab/near-miss.py`) | typos, other TLDs, parents, upper case | 58,883 blocked, digest `79962225265bc64e` |
| edge cases (`lab/check-edge.sh`) | hosts, plain, regex, ad-block fixtures, case, duplicates, a 17,576-name list that makes the capacity guess short | identical reports |
| **hosts-format differential** (`lab/make-hosts-lists.py`, `dnsApp.hosts.config`) | the `BlockList` parser (hosts / plain domain lists) with 8 lists rewritten as `0.0.0.0 name`, `127.0.0.1<tab>name`, bare, `# note`, `*.name`, upper case, padded, repeated lines, comments and loopback lines: 601,786 names | A digest `5c7dd8b2a0940e60`, TXT digest `ee373fac9d6210df`, allow digest `191737ebd76058b9` |

On CI, both architectures, the same steps ran on the lists of the run's day: 2,159,642 listed names, 192 allow-covered,
240,716 near-miss names, 12 edge cases, digests equal (`results/ci-compare/run-41611257103.md`, column `digests`).
The main lab config has only ad-block block lists, so before the hosts-format differential the `BlockList` parser of
the block lists was covered only by the edge fixture; the finalists change it too.

**Unit checks of each structure** (`results/unit-checks/`, each drives the private type of the built assembly through
reflection and compares it with a `HashSet`): `hash64-set` `lab/hash-test.sh` (FNV-1a test vectors, the random basis
per process, membership through the app's own `IsZoneFound` against a `HashSet<string>`), `hash64-index2`
`lab/hash-index-test.sh` (empty, one entry, `0` and `ulong.MaxValue`, duplicates, 95 sizes around every power of two
where the number of index bits changes, 5,000 hashes in one bucket, the first and last value of 4,000 buckets, dense
clusters, 200,000 random hashes), `exact-tags` `lab/name-set-test.sh` (a 200,000-entry differential, names the parsers
never store), `exact` `lab/domain-set-test.sh`. All four pass. The `HashIndex` test was run against two mutants of the
patch (counting into the wrong bucket slot, a slice one element short) and fails both (9 failed checks, and an
out-of-range exception), so it does separate a wrong index from a right one.

### 2.9 The finalists without a container memory limit (local, CI, a real board)

No limit anywhere. Ratios are original over candidate. Records: `results/ci-compare/run-41611257103.md`,
`run-41679672111.md`, `run-41679820344.md` (CI, three runs, the median is shown; lists of 2026-11-03),
`results/session-amd64-12` (local, amd64; the original at the start and the end of the session: 275.8 and 269.1 MiB anon),
`results/session-device` (Orange Pi Zero 3, 1 GiB, aarch64; the original at the start and the end: 262.1 and 259.1 MiB).

| shape | CI anon ratio amd64 / arm64 (MiB) | CI reload ratio | CI p50 | CI qps | local anon (ratio), reload, p50, qps | board anon (ratio), reload, p50, qps |
|---|---|---|---|---|---|---|
| `hash64-set` +56 / -32 | 2.95x / 2.22x (86.9 / 136.6) | 2.31x / 2.09x | -0.1% / 0.0% | +0.3% / +1.0% | 82.9 MiB (3.29x), 2.46x, -0.2%, +0.4% | 79.5 MiB (3.28x), 2.14x, +0.2%, -3.1% |
| `hash64-index2` +101 / -32 | 4.59x / 2.87x (55.9 / 105.4) | 3.26x / 2.76x | +0.4% / -2.1% | -0.5% / +2.3% | 49.7 MiB (5.48x), 3.58x, -7.2%, +10.6% | 46.1 MiB (5.65x), 3.15x, -0.3%, +1.8% |
| `exact-tags` +160 / -27 | 2.75x / 2.12x (93.2 / 143.2) | 2.17x / 2.01x | +2.6% / +4.7% | -2.5% / -3.5% | 89.3 MiB (3.05x), 2.35x, -0.3%, +1.6% | 84.0 MiB (3.10x), 1.99x, +3.6%, -3.2% |

- **The `hash64-index2` p50 of -7.2% locally is the original's.** In the rounds paired with it the original's p50 was
  260.0 µs against 238.8 and 238.1 in the rounds paired with the other two; the candidate's was 241.2, 236.5 and 237.3.
- **`exact-tags` costs a little latency, consistently**: p50 above zero on both architectures in the CI median and on
  the board (+3.6%); `hash64-set` and `hash64-index2` do not show a cost anywhere beyond the noise of 2.4.
- **The board is slower per query than a CI runner** (p50 about 207 µs against 87-139 on the runners in the first
  CI run) and loads the lists in 13.4 s (original), 9.3 s (`hash64-set`), 8.2 s (`hash64-index2`), 8.3 s (`exact-tags`).
- **The reload peak of the board varies between sessions.** An earlier memory-only session on the same board
  (`results/session-device-memory-only`, three startups and one reload each) gave 239.2, 197.9 and 259.7 MiB for the
  three candidates and 454.4 and 432.5 for the original, against 211.6, 143.7, 226.7 and 468.8 / 434.8 in the complete
  session. The anon figures agree within 2 MiB (original 258.3 / 257.9, candidates 78.9, 45.8, 84.1). The reload peak
  is a single cgroup `memory.peak` per build and includes page cache; read it as a range.

**What happened on the board while measuring** (`results/device-incidents`, `results/session-device-memory-only`).
The board serves nothing now (the owner stopped using it for DNS), so its `dns-server` container and watchdog timer
were stopped for the runs and left stopped (`lab/on-device.sh`). Four attempts were needed.

1. First session (`session-device-memory-only`): the original's 500-report TXT pass was cut off by a guard that
   watched `MemAvailable` and the total swap in use (it tripped at 617 MiB of swap), so there is no latency and no
   comparison of reports. The startup and reload records of all four builds are valid and are the memory-only session.
2. Second session: the board reset itself about five minutes in, during the same pass on the original. The guard
   (`MemAvailable` under 60 MiB, or swap growth above 450 MiB) had last sampled 120-167 MiB available and a swap
   growth of 388 MiB; there is no sample for the 19 s before the reset, which fits a kernel stalled in paging that the
   SoC watchdog then reset. The cause of the reset is inferred from that timing and from the same pass having cut the
   first session short; it was not isolated. On 2026-10-30 a functional pass run next to the serving container had
   ended in a reset of the same board too (load 22, 113 MiB available, 117 MiB of swap left; *no record in this repository*).
3. Third attempt: a guard on swap growth (+300 MiB) tripped twice with 177-187 MiB available and no swap traffic
   (the kernel moves idle pages of the other containers to swap without I/O), which broke two runs. The attempt was
   stopped by hand. In 925 healthy seconds the swap traffic was 0 pages/s, which set the guard that finally ran:
   `MemAvailable` under 100 MiB or more than 1000 pages/s of swap traffic for 2 s.
4. Fourth attempt (`session-device`): the original is not queried for the 500 TXT reports (the pass that drove the
   board into swap) and the latency client takes the names of the first candidate's reports. No guard trip in 2,910
   samples (minimum 123 MiB available, swap traffic 0). The 500 reports of the three candidates are identical to each
   other; the original's are not compared on the board. Its responses are compared on the CI legs and locally.

Nothing else on the board was touched. A backup of the `dns-server` configuration volume and compose project was
taken before the first run and the restore of the container was tested (it answers within 5 s of `docker start`).

## 3. Runtime settings and other knobs (no code)

`lab/runtime-options.sh` (`results/runtime-options-amd64/`, local, no limit, one startup per setting; two for the others;
the spread of two runs of the same build is up to 17 MiB in 2.3, so a single run is a hint, not a figure):

| setting | original anon MiB | `hash64-set` anon MiB | verdict |
|---|---|---|---|
| `DOTNET_GCConserveMemory` 0 / 3 / 5 / 7 / 9 | 278.0 / 277.7 / 277.6 / 268.6 / 255.6 | 82.9 / 83.2 / 85.3 / 84.2 / 84.3 | at most 8% on the original at 9, nothing on `hash64-set`: not a substitute for a smaller structure |
| `DOTNET_GCgen0MaxBudget=0x600000`, 2 runs | 278.2, 277.0 | | no change |
| `DOTNET_gcConcurrent=0`, 2 runs | 315.0, 314.8 | | worse |
| entries with a parent in the same list (`lab/subsume.py`) | 0.0% in the 21 ad-block lists; 24.1% in the union (552,439 of 2,292,355) | | only a set shared across lists could drop them; the app keeps one per list (#1003) |

## 4. Query stalls while the lists reload (`lab/stall-matrix.sh`, `results/stall/`)

Upstream issue #2174 was a forced blocking `GC.Collect()` that stalled queries by 50 to 250 ms. `lab/stall-reload.sh`
sends 200 queries per second for a blocked name from inside the container's network namespace (the server's default
limit of 600 queries per minute per client subnet would otherwise drop them from the host) and forces a reload; replies
slower than 10 ms are counted per window. Two rounds per build, no limit, nothing else running on the machine:

| build | round | queries in the reload window | replies >= 10 ms in it | >= 50 ms | worst reply in it (ms) | worst reply in the settle window (ms) | >= 100 ms anywhere |
|---|---|---|---|---|---|---|---|
| `original` | 1 | 12000 | 20 | 0 | 21.9 | 36.5 | 0 |
| `original` | 2 | 12207 | 29 | 0 | 34.9 | 16.8 | 0 |
| `original-gc` (the original plus the 4-line GC step) | 1 | 12600 | 56 | 22 | **175.7** | **302.9** | 6 |
| `original-gc` | 2 | 12156 | 49 | 21 | **256.3** | **207.2** | 9 |
| `exact-frontcoded-gc` (the GC step on a compact structure) | 1 | 12200 | 2 | 0 | 20.9 | 1.7 | 0 |
| `exact-frontcoded-gc` | 2 | 12200 | 1 | 0 | 19.4 | 2.4 | 0 |
| `hash64-set` | 1 | 12000 | 1 | 0 | 15.3 | 2.0 | 0 |
| `hash64-set` | 2 | 10505 | 2 | 0 | 18.5 | 3.1 | 0 |
| `hash64-index2` | 1 | 11800 | 1 | 0 | 15.3 | 3.3 | 0 |
| `hash64-index2` | 2 | 11800 | 0 | 0 | 3.7 | 9.3 | 0 |
| `exact-tags` | 1 | 11800 | 0 | 0 | 3.7 | 2.5 | 0 |
| `exact-tags` | 2 | 11712 | 1 | 0 | 15.1 | 2.7 | 0 |

The GC step on the original heap reproduces the stall (21-22 replies of 50 ms or more, 6-9 of 100 ms or more); on a
compact structure it does not, and the three finalists have no GC call at all. The original itself has up to 29 replies
of 10 ms or more in the reload window and none of 50 ms; the finalists have 0 to 2. The `hash64-set` round 2 sent fewer
queries (10,505) than the others; the cause was not checked.

## 5. Research that shaped, or ruled out, attempts

* **Cloudflare** (`docs/research/cloudflare*.md`): publishes no block-list
  structure. `mmuniq-hash` (a table of raw 64-bit hashes): 35.5 MiB RSS and 0.57 s on our names,
  14.6 B/key at load 0.547. `trie-hard`: 197 MiB nodes on our names (473 MiB peak), wrong tool.
  `entropy-map` MPHF: 8.34 B/key. A 2024 blog post benchmarked three perfect-hash crates and they
  lost to a branchless direct index. Bloom filters stop paying beyond L3. Not adopted: all of
  them; the useful sentence is the 1.1.1.3 post-mortem: an emergency allow list in front.
* **Exact-structure survey** (`docs/research/exact-structures.md`): per-key sizes measured on our
  lists: forward FST 9.21 B, reversed FST 8.75, marisa 5.82, front-coded B=64 12.08, LOUDS 12.4;
  `exact` 24.7 B/entry in a microbenchmark. FST and marisa are 500-700 lines or a library:
  not built.
* **Blockers** (primary sources): Blocky sorted 64-bit FNV-1a hashes with random seed (merged
  2026-10-28, #2290; credits `esp32-c3-adblock`, which uses 40-bit hashes in flash); Pi-hole
  SQLite; AdGuard Go maps; Chrome/Firefox sorted 32-bit prefixes confirmed with a full hash.
* **dnscrypt-proxy** (`plugin_block_name.go`, `pattern_matcher.go`): `critbitgo` tries over reversed names
  for suffixes and a `map[string]` for exact names; rule lists reload through a staged copy that
  replaces the old one (the same 2x). No compact structure, nothing to adopt.
* **AdGuard Home** (issues #8491, #8297; `urlfilter` read earlier, ~64 B per rule estimated in its source):
  the same failure in the same ecosystem. On a 1 GB OpenWrt router, one filter of 2,103,241 rules (the size of
  the HaGeZi threat-intelligence list used here) takes the process from 436 to 888 MB RSS during an automatic
  update and the OOM killer ends it (v0.107.78, reported 2026-07-25). Their lists are also rebuilt next to
  the old ones. Confirms the problem is not specific to Technitium's `HashSet<string>`; no compact structure
  was adopted there (the issue is closed as "waiting for data").
* **Compressed string dictionaries** (Brisaboa, Cánovas, Martínez-Prieto, Navarro, arXiv 1101.5506):
  plain front coding with a binary search over block heads, Hu-Tucker front coding and RePair
  reduce a string dictionary to as little as ~20% of the plain strings while keeping dictionary
  search fast; confirms the front-coded exact set (`exact-frontcoded`) as the literature's answer,
  at 300+ lines for us.
* **Provenance**: the C# is ours; the idea of sorted 64-bit hashes with a prefix index is not: Blocky merged it on
  2026-10-28 (#2290, credited to `esp32-c3-adblock`). No code was copied.

## 6. Considered and not built, with the reason

| idea | why not |
|---|---|
| exact set that verifies a hash hit against the cached list file | 12 B/entry index (~56 MiB, 4.8x *inferred*), needs the list parsers re-run on a hit and offsets invalidated by a replaced file |
| Elias-Fano / Golomb coding of the sorted hashes | ~5.7 B/entry vs 8: ~6 MiB of 48 (*inferred*), more code |
| reversed FST, marisa | size 22 / 15 MiB but a library-sized change |
| 6-bit packed names + TLD id | would give ~76-82 MiB (3.4-3.6x, *inferred*) for more than the 256 lines of `exact` |
| two-pass build by hash bucket (Cloudflare note N1) | 100-130 lines and temp files on an SD card; the finalists already cut the reload peak 2.0-3.3x on CI |
| `MemoryMappedFile` for the blobs (note R4) | changes memory accounting, SIGBUS risk, large diff |
| binary fuse / xor / ribbon filters | not exact either, and far more code than a sorted array |
| a shared set across lists | the maintainer keeps one set per list on purpose (#1003) |
| `exact-frontcoded` with the presized loader | the front-coded exact set predates the finding that the loader was the limit and was not rerun with a presized buffer; about 335 lines, against the maintainer's wish for a small diff |

## 7. Not measured

The responses of the original on the board (the 500-report pass drove it into swap, 2.9); the small-container checks
on arm64 and on the board; the stall probe on CI and on the board; CPU time of a load (an earlier measurement belonged
to the first setup and is not kept); a Raspberry Pi; `BlockListZoneManager` (the built-in lists) and the regex lists,
which are untouched.
