# Wide-fingerprint approximate-membership filters as the per-list block-list set

Research note, 2026-11-02. Read-only investigation of the Technitium Advanced Blocking
problem; every number below is either measured in this note (with the command shown),
quoted from a source I opened (URL given), or labelled **[INFERENCE]** / **UNVERIFIED**.

---

## 0. Bottom line

1. **The idea is sound.** A 3-wise *binary fuse filter* with 64-bit fingerprints stores
   **72.1 bits per key** (9.02 bytes) and answers a membership probe with
   **false-positive probability exactly `2^-b` = 5.42e-20, independent of the set size**.
   Measured here: 2,460,000 random 64-bit keys → 22,151,168 bytes (9.0045 B/key),
   0 false positives in 20,000,000 negative probes, 0 false negatives in 2,460,000
   positive probes, 0.23 s single-threaded build.
2. Applied to the real 23-list config in this repository (2,455,832 list entries), the
   whole block-list storage becomes **21.44 MiB**, versus **89.4 MiB `anon`** for the
   accepted compact exact `DomainSet` and **269.4 MiB** for the original
   `HashSet<string>` (`docs/analysis.md` §2). That is 4.2x smaller than the structure
   already accepted upstream-facing work, and 12.6x smaller than the original.
3. **The reason a filter wins at all** is not that it compresses harder than a hash
   table per stored bit; it is that its space is proportional to the *fingerprint*
   width while its error is `2^-b` **independent of N**. A hash table storing
   `H`-bit hashes has error ≈ `N/2^H`, so holding the error at `2^-64` for
   N = 2.46 M forces an 85.2-bit hash per key, i.e. `85.2/0.75 = 113.6` bits per key
   of storage (14.2 B/key) at 0.75 load. The filter reaches the same error with
   72.1 bits/key. The saving *grows* with N and
   with the error target.
4. **The one thing that must be written from scratch is the 64-bit variant.** Every
   reference implementation I found — C (`FastFilter/xor_singleheader`, Apache-2.0),
   Rust (`xorf`, MIT), C# (`Dissimilis/BinaryFuseFilter`, MIT), Go — stops at
   8/16/32-bit fingerprints. A 64-bit fingerprint also needs a *second, independent*
   64-bit mix, because the index and the fingerprint may not be derived from the same
   64 bits. Both changes are small (my C port of the whole algorithm is ~150 lines).
5. **Two properties do not change:** the structure is still probabilistic (error is
   5.42e-20 per probe, not zero), and it **cannot be built incrementally** — the whole
   key set must be known at construction time, which happens to match the app's
   "parse a list, then swap it in" update path.
6. **Wide fingerprints are where binary fuse is uniquely good.** Its probe cost is
   *3 slot reads regardless of b*. Ribbon's probe reads one w-bit window **per
   fingerprint bit** (b·w/8 bytes: 512 B at b=64,w=64; 2 KB at w=256), and the
   published Ribbon evaluation only covers `r ∈ [1,16]`. Cuckoo needs
   `f = b + log2(2·bucket)` bits and a non-power-of-two table to stay competitive;
   quotient needs ≈`b + log2 N + 3` bits/slot.

---

## 1. The claim under test, stated precisely

For a set `S` of `N` keys, a filter with `b`-bit fingerprints gives

- space `≈ (1+ε)·b` bits per key, where `ε` is the *structural* overhead of the
  construction (0.125 for a binary fuse, 0.23 for an XOR filter);
- false-positive probability `≈ 2^-b` per membership probe, **for every probe**,
  independent of `N` and of how full the filter is.

A hash set that stores an `H`-bit hash per key uses `H/α` bits per key (α = load
factor) and answers a probe by comparing the query's hash against the stored one.
Its false-positive probability is the chance that *some* stored key hashes to the
query's hash:

```
P(FP) ≈ N / 2^H          (a hash table cannot distinguish a collision from a member)
```

Solving for equal error `f`: `H = log2 N + log2(1/f)`.

At `N = 2,460,000` and `f = 2^-64`:

| structure | bits/key | bytes/key | notes |
|---|---|---|---|
| hash table of `H`-bit hashes, α = 0.75 | `(64 + log2 N)/0.75` = **113.6** | 14.20 | exact except for hash collisions |
| binary fuse, `b = 64` | `1.127·64` = **72.1** | **9.02** | measured 9.0045 |

That is the whole argument in one line: **the filter is 37% smaller than the hash
table at the same error, and the gap widens as N grows.** At `N = 2^32` the hash table
would need 128 bits/key while the filter still needs 72.

The inverse view is what matters for the upstream proposal: for a *fixed* budget of
~9 bytes per domain, the filter's error is 2^-64 while a hash table's is
`2.46e6/2^72 ≈ 5e-16` — and, more importantly, the filter's error does not silently
degrade if the list grows.

---

## 2. Sources and method

Opened and read in full (PDF or HTML, not search snippets):

| source | URL |
|---|---|
| Graf & Lemire, *Xor Filters* (JEA 25, 2020) | <https://arxiv.org/abs/1912.08258>, <https://ar5iv.labs.arxiv.org/html/1912.08258>, PDF `arXiv:1912.08258v2` |
| Graf & Lemire, *Binary Fuse Filters* (2022) | <https://arxiv.org/abs/2201.01174>, PDF `arXiv:2201.01174v1` |
| Dillinger & Walzer, *Ribbon filter* (2021) | <https://arxiv.org/abs/2103.02515>, PDF `arXiv:2103.02515v2` |
| RocksDB, *Ribbon Filter* blog (2021) | <http://rocksdb.org/blog/2021/12/29/ribbon-filter.html> |
| CRLite paper (IEEE S&P 2017) | <https://obj.umiacs.umd.edu/papers_for_stories/crlite_oakland17.pdf> |
| Mozilla, *The End-to-End Design of CRLite* | <https://blog.mozilla.org/security/2020/01/09/crlite-part-2-end-to-end-design/> |
| Fan et al., *Cuckoo Filter* (CoNEXT 2014) | <https://www.cs.cmu.edu/~dga/papers/cuckoo-conext2014.pdf> |
| Bender et al., *Don't Thrash* (VLDB 2012, quotient filter) | <https://arxiv.org/pdf/1208.0290> |
| BIP 158, *Compact Block Filters* (Golomb-coded sets) | <https://raw.githubusercontent.com/bitcoin/bips/master/bip-0158.mediawiki> |
| Wuille, *Minimizing the redundancy in Golomb Coded Sets* | <https://wuille.net/posts/minimizing-golomb-filters> |
| Chromium, `safebrowsing.proto` (Safe Browsing wire format) | <https://chromium.googlesource.com/chromium/src/+/main/components/safe_browsing/core/browser/db/safebrowsing.proto> |
| Chromium, `v4_rice.h`, `hash_prefix_map.cc`, `v4_store.cc` | same tree, `.../core/browser/db/` |
| `FastFilter/xor_singleheader` (C reference, Apache-2.0) | <https://github.com/FastFilter/xor_singleheader> |
| `FastFilter/fastfilter_cpp` (C++ benchmark suite, Apache-2.0) | <https://github.com/FastFilter/fastfilter_cpp> |
| `ayazhafiz/xorf` (Rust, MIT) | <https://github.com/ayazhafiz/xorf> |
| `Dissimilis/BinaryFuseFilter` (C#, MIT) | <https://github.com/Dissimilis/BinaryFuseFilter> |
| `asarnaout/XORFilter.Net` (C#, MIT) | <https://github.com/asarnaout/XORFilter.Net> |
| `jonmat/FastIndex` (C#, MIT) | <https://github.com/jonmat/FastIndex> |

Benchmarks in §6 were built and run by me under `/tmp/WideFingerprintFilters/`
(gcc 13.3.0). Commands and full output are in §12. Nothing was written to the
repository except this file.

---

## 3. The families, one by one

### 3.1 XOR filters (Graf & Lemire 2020)

*Construction* — peeling (Botelho/Pagh/Ziviani). The array is split into three
consecutive segments of size ≈ `c/3` with `c = ⌊1.23·N⌋ + 32`; each key hashes to one
location in each segment; the algorithm repeatedly removes keys that are alone in a
location and pushes them on a stack (paper Algorithms 2–4). It then walks the stack in
**reverse** peel order and sets one slot per key so that the XOR of the key's three
slots equals its fingerprint. Complexity is linear.

*Space* — `1.23·b` bits/key (23% over the `log2(1/ε)` bound). The `xor+` compression
variant reaches `1.0824·b + 0.5125` bits/key at a significant query-time cost
(formula quoted in the binary fuse paper, §3).

*Failure* — "we experimentally found that the estimated probability [of the mapping
step succeeding] is always greater than 0.8 with c = 1.23·|S| + 32", approaching 1 for
large sets; each failure is handled by picking a new random seed. Expected number of
trials ≤ ~1.1 (binary fuse paper, §3, using a 90% success bound).

*Query* — 3 random slot reads, independent (memory-level parallelism applies), then a
compare against `fingerprint(x)`; `P(FP) = 2^-b` exactly, per the paper's §3
("This probability ε = 1/2^k determines the false-positive probability").

*Verdict for us* — strictly dominated by binary fuse (1.23 vs 1.125) with the same
query cost; the paper itself says binary fuse "renders xor filters practically
obsolete". Useful only as the conceptual base.

### 3.2 Binary fuse filters (Graf & Lemire 2022) — the candidate

Same peeling idea, but the array is divided into *many* small segments (hundreds) and
a key maps to three **consecutive** segments. Consecutive mapping is what buys both the
smaller array and the faster build:

- array size: `⌊1.125·N⌋` slots for 3-wise, `⌊1.075·N⌋` for 4-wise (Table 1);
  measured 1.1256–1.1272 for a single filter and 1.1444 across the 23-list split;
- segment length: `2^floor(log(N)/log(3.33) + 2.25)` (3-wise);
  for N = 2.46 M → 16,384 slots;
- construction: one partial sort of the keys by starting segment (linear, few hundred
  buckets), then a forward pass over the counters and a backward unwind — cache
  friendly, unlike XOR's fully random probe;
- failure: "the failure probability, when using these formulas for sets ranging from a
  few keys to hundreds of millions, are less than 1% — typically far lower than 1%"
  (paper §3). The reference retries with a new seed, capped at 100 iterations;
- query: 3 slot reads, `P(FP) = 2^-b`;
- measured: 9 bits/key at b=8, 8.6 at b=8/4-wise (paper Fig. 3b).

The 4-wise variant (`1.075`) costs a fourth slot read; I did not benchmark it. At b=64
it would save 0.45 B/key (≈1.1 MiB) for a 33% higher probe count — not worth it.

**Measured (this note): 9.0045 B/key at b=64, N=2.46 M; 9.155 B/key across the real
23-list split; 0 false negatives; 0 false positives in 20 M negative probes.**

### 3.3 Ribbon filters (Dillinger & Walzer 2021; RocksDB)

*Construction* — Gaussian elimination, not peeling. Each key gets a random start
position `s(x)` and a random `w`-bit coefficient vector `c(x)`; the row `h(x)` is a
`w`-bit window at `s(x)`. Rows are sorted by `s`, the matrix is banded (all ones inside
a diagonal ribbon of width `w`), and "Rapid Incremental Boolean Banding ON the fly"
inserts equations with a scan-forward/back-substitute loop that never produces fill-in
outside the ribbon. `Z` is `m × r` bits with `m = (1+ε)n`; `r` is the fingerprint width.

*Space* — `(1+ε)·r` bits/key, with `ε ≈ (4 + r/4)/w` (paper Eq. 7). Standard Ribbon's
overhead depends on `n`; Balanced Ribbon reaches "1.005λ + 0.008 bits per key"
(experimental). The RocksDB blog reports ~30% savings vs Bloom at 100 k keys and 27% at
100 M keys, at 3–4x the CPU, and **~230 bits per key of temporary memory during
construction for 128-bit Ribbon vs ~75 bits per key for Bloom**.

*Failure* — Standard Ribbon can fail to solve and needs a retry; the paper's
Homogeneous variant states "construction success is guaranteed".

*The problem at b = 64.* The paper's own experiments use only `r ∈ [1,16]` ("we turn to
simulations ... `w ∈ {16,32,64,128}`, and `r ∈ [1,16]`", §4.2), and Fig. 5 plots FP
rates only down to `2^-16`. Two structural reasons:

1. the guarantee requires `ε·w > C·max(log w, r)`, so `w` must be several times `r`;
2. a query reads a `w`-bit window **per result bit**, i.e. `r·w/8` bytes. At
   `r = 64, w = 256` that is **2 KB of contiguous reads per probe** (32 cache lines),
   against 3 slot reads for a binary fuse. At `r = 8, w = 64` it is 64 B — which is why
   Ribbon is excellent for the low-FP-bit regime RocksDB targets and poor for ours.

*Verdict for us* — Ribbon would land at ≈`1.08–1.16 × 64` = 8.6–9.3 B/key, i.e. **no
space win over binary fuse**, with a Gaussian solver, a much larger constant, and a
probe that touches 8–32 cache lines. Rejected for b=64. (It is the right answer for
`b ≤ 8` in LSM filters.)

### 3.4 Golomb-coded sets, and what Chrome actually does

*Construction* — none of the above. Hash every key to `[0, N·M)`, **sort**, take
successive differences, and Golomb-Rice encode each difference with parameter `P`.
`M = 1/FP`; there is no array of slots and no peeling.

*Space* — exact formula from Wuille: `B + 1/(1 - e^{-2^B/M})` bits per element, minimised
at `M = 1.497137·2^B`, giving `B + 2.05` bits/key and a redundancy of 0.12% over the
entropy `log2(eM)` (for B = 20). BIP 158 uses `P` = bit length of the remainder and
`M = 2^P`, with the filter "matching items in the set with probability 1, and other
items with probability `1/M`".

*For b = 64* — with `M = 2^64` (exactly FP `2^-64`) Wuille's rule gives
`B = floor(log2 M - 0.0553) = 63`, and the size is
`63 + 1/(1 - e^{-1/2}) = 65.5` bits/key = **8.19 B/key**, *smaller than any slot-based
filter*, and 65.05 bits/key (8.13 B/key) if you accept FP `1.34e-19` at the optimal
`M = 1.497·2^63`. GCS is the space winner by ~9%.

*Why it is still the wrong choice for us* — a query is a binary search into a sorted
hash space plus a variable-length decode, not a constant 3 reads: BIP 158's reference
implementation keeps a skip-list of bit positions and the lookup does
`O(log N)` bitstream seeks (≈21 for our N) with unaligned bit reads. Wuille's own
summary: "harder to update or query". The xor filter paper measures GCS as the
space-competitive but *slow* alternative ("difficult to achieve competitive speed"),
and the cuckoo paper declines to evaluate it ("static and requires non-constant lookup
time"). At 2.46 M keys and 3 label probes per query, the 21-seek search is the wrong
shape for a DNS hot path.

*What Chrome does (and what the premise gets right and wrong).* The Safe Browsing v4
**wire format** really does store sorted hash prefixes Golomb-Rice encoded — from
`safebrowsing.proto`:

> `// The encoded 4-byte prefixes of SHA256-formatted entries, using a Golomb-Rice encoding.`
> `optional RiceDeltaEncoding rice_hashes = 4;`

and the uncompressed form is

> `// The hashes, all concatenated into one long string. ... Hashes are sorted in lexicographic order.`

with prefixes lengthened beyond 4 bytes for hot URLs:

> `// Hashes can be anywhere from 4 to 32 bytes in size. A large majority are 4 bytes, but some hashes are lengthened if they collide with the hash of a popular URL.`

The **client store** is not a filter at all: `hash_prefix_map.cc` writes the decoded
prefixes as fixed-size records into per-prefix-size memory-mapped files
(`HashPrefixMap::Append`, `ReadFromDisk`), and `v4_store.cc` uses `V4RiceDecoder` only
for the *update* payload ("Rice-Golomb decoder for blocklist updates", `v4_rice.h`).
So: Rice coding on the wire, sorted byte arrays in memory, plus a *targeted* prefix
lengthening to kill the collisions that matter. **What the premise gets wrong** is only
where the Rice coding lives — it is the transport encoding of the update payload, not
the in-memory index — and what it gets right is the important part: the stored form is
a sorted array of SHA-256 prefixes, i.e. the GCS family, not a Bloom/cuckoo/xor filter.
A 4-byte prefix gives `2^-32` per lookup, 12 orders of magnitude worse than our target;
lengthening is the manual patch for that.

*Verdict* — the best space (8.13 B/key at b=64) but the wrong query shape, and its
"exactness" tricks are per-key hacks, not a construction.

### 3.5 Filter cascades (CRLite) — and why exactness does not transfer

CRLite's contribution is not a filter; it is the observation that if **every query is
known in advance to come from a finite universe U**, then the residual false positives
of a Bloom filter on `U` form a finite set that can itself be filtered, recursively,
until the set is empty. From the paper (§III.A):

> "suppose we knew that all set membership queries were going to come from a finite set
> U. In that case, if R ⊆ U ... were stored in BF, then the expected number of false
> positives would be p·|U \ R|. ... The key insight is that this small set of false
> positives can be stored in another Bloom filter, and so on, until the number of false
> positives is zero."

Lookups then walk the levels and answer definitively: "If i is odd, then u is
definitively not in R. If i is even, then u is definitively in R." Mozilla's
description: "a series of cascading Bloom filters, with each filter layer adding data to
the one before it ... using Certificate Transparency as an oracle". Sizes: 100 M
certificates, ~750 k revoked, 16 GB of serial numbers compressing to **~1.3 MB**.

**Why this does not fit DNS.** The oracle is the whole point: `U` must be enumerable at
build time (all unexpired certificates, discoverable from CT logs). For a DNS block
list, `U` is "every name that will ever be queried" — unbounded and adversary-chosen.
There is no oracle to enumerate the false positives against, so the cascade collapses
to a single level and you are back to a plain filter with whatever FP rate you paid
for. A cascade buys exactness *for a known universe*, at the cost of a build-time
`|U|`-sized scan; we have neither.

The transferable lesson is different and useful: CRLite shows that the *only* way to get
zero error from a probabilistic structure is to know the query universe. For us the
equivalent is to make `2^-b` so small that it is below the noise floor of everything
else in the system (see §9).

### 3.6 Cuckoo filters (Fan et al. 2014)

*Construction* — incremental insertion into a 2-bucket partial-key cuckoo table, with
random eviction ("e.g. 500 times in our implementation") and failure when a relocation
chain does not terminate. No peeling, no global solve.

*Space* — `C ≈ (log2(1/ε) + log2(2b))/α` bits per item; with bucket size `b = 4`,
`α = 0.955`, and the semi-sorted variant saving one more bit, the paper's Table 2 gives
`(log2(1/ε) + 3)/0.955` (and `+2` semi-sorted).

*Error* — exactly `1 - (1 - 1/2^f)^{2b} ≈ 2b/2^f`: 8 comparisons for `b = 4`, so
`8/2^f`.

*At our target* — to get `2^-64` the fingerprint must be `f = 67` bits;
`67/0.955 = 70.2` bits/key = **8.77 B/key**, marginally *better* than binary fuse
(9.02). But: the table size must be a power of two buckets (partial-key cuckoo needs a
mask to compute the alternate bucket), so for `N = 2.46 M` with 4-entry buckets you need
`2^20` buckets = 4.19 M slots, i.e. load 0.59, and the real cost becomes
`64/0.59 = 109` bits/key = **13.6 B/key**. The binary fuse paper's authors had to
"lift the restriction to a power-of-two capacity" to benchmark cuckoo fairly. Their
Fig. 1 also notes that at very low FP "a cuckoo filter becomes slightly smaller" —
consistent with the 8.77 vs 9.02 above — but that comparison already assumes the
non-power-of-two table.

*Verdict* — the right structure if you need incremental insert/delete; wrong here,
because we replace whole lists and would pay the power-of-two rounding on 21 lists,
many of them small.

### 3.7 Quotient filters (Bender et al. 2012)

*Construction* — insertion into a compact hash table that stores the fingerprint split
into a quotient (which selects the run) and a remainder, plus 2–3 metadata bits per
slot; runs shift on insert and delete. No filter-level failure, but "the QF is supposed
to be used when it is at most 75% full" and "performance deteriorates as it fills"
because clusters lengthen.

*Space* — 2–3 bits metadata per slot at load 0.75–0.9; the paper measures "about 20%
more space than a BF" at 1% FP, and notes 10–25% overhead vs Bloom in the cuckoo
paper's survey.

*Error* — governed by the remainder width `r`: each comparison is `1/2^r`, and a query
compares against the entries in the run for its quotient, so
`P(FP) ≈ (run length)/2^r`.

*At our target* — `r = 64` forces a slot of `64 + log2(slots) + 2 ≈ 87` bits, i.e.
`87/0.75 = 116` bits/key = **14.5 B/key** at 0.75 load. The bit-per-key comparison is
lost because the quotient is stored per slot rather than implied by a perfect hash.

*Verdict* — dynamic, cache-friendly, and 60% larger than binary fuse at our error
target. Out.

### 3.8 Summary table of the families

| family | bits/key (as a function of b) | FP per probe | construction | peak build mem | failure/retry | slot reads/probe | wide b supported? |
|---|---|---|---|---|---|---|---|
| Bloom | `1.44·b` | `(1-e^{-kn/m})^k` | streaming | 0 | none | `b` bit tests | yes (but FP floor) |
| XOR | `1.23·b`; xor+ `1.0824b+0.5125` | `2^-b` | peeling, 3-partite | ~2·output + keys | ≥0.8 success, new seed | 3 | reference: 8/16 (32 in Rust) |
| **binary fuse** | `1.125·b` (3-wise), `1.075·b` (4-wise) | `2^-b` | peeling over consecutive segments + partial sort | ≈2.6·output* | <1%, new seed | 3 (4) | reference: 8/16; Rust/C#: 32 |
| Ribbon (std/homog.) | `(1+ε)·b`, `ε≈(4+b/4)/w` | `2^-b·(1+ε²)` | banded Gaussian elimination | 230 bits/key (128-bit, RocksDB) | std may fail; homog. guaranteed | `b` windows of `w/8` B | experiments only `b ≤ 16` |
| GCS | `b + 2.05…2.54` | `1/M = 2^-b` | sort + Rice | N·b bits + sort | none | `O(log N)` seeks + decode | yes (just bits) |
| cascade | `n_levels × Bloom` | 0 on known U | Bloom layers + oracle | | | `n_levels` | yes |
| cuckoo | `(f + log2 2k)/α` | `2k/2^f` | incremental + relocations | 0 (grows) | chain fails at high load | 2 cache lines | 8/16/32/64 |
| quotient | `(b + log2 N + 2)/α` | `~run/2^b` | run shifting | 0 | none, degrades | 1–2 | 64 possible but 14.5 B/key |

\* binary fuse peak build memory = 23.65 B/key of scratch plus 8 B/key of key hashes,
measured below; the "output" is 9.02 B/key at b=64, so ≈2.6x the output.

---

## 4. Wide fingerprints: what actually changes at b > 32

This is the part of the idea that has no reference implementation and therefore the
part that needs care.

**(a) The fingerprint must be independent of the index.** All these constructions derive
*three slot indices* and *one fingerprint* from a key's hash. With `b ≤ 32`, one 64-bit
hash suffices: the reference uses `mulhi(hash, ...)` plus bits 0…35 for the three
segment offsets and `hash ^ (hash >> 32)` for a 32-bit fingerprint. With `b = 64` the
fingerprint has nothing left to draw on: the index already consumes the whole 64-bit
hash (the `mulhi` reduction depends on all 64 bits, and bits 0…35 are reused for the
in-segment offsets). You need a second, independent 64-bit hash of the key — 128 bits in total. Two clean
options:

- two independent seeds over the key: `h = H(key + seed1)` for the three indices,
  `fp = H(key + seed2)` for the fingerprint (two passes, ~2x the hash cost); or
- one 128-bit hash (XxHash128, MurmurHash3 x64_128, SHA-256/128) split into the index
  half and the fingerprint half (one pass, ~1x).

A third, cheaper variant is what I used in the benchmark: `fp = murmur64(hash)`, a
second 6-instruction mix of the *same* 64-bit hash. It measured correctly (`2^-b` at
b = 16/20/24, no false positives at b = 32, no false negatives), but it leaves a
deterministic — if well-diffused — relation between the index and the fingerprint. The
two-seed form removes that relation for ~2 ns and is the one to put in the proposal.

Either way **this is the only real change.** I
verified it empirically: with the second mix, in-set queries are 100% correct and the
measured FP rate matches `2^-b` at b = 16, 20 and 24 (§6.3). Deriving the fingerprint
from the *same* bits as the index (e.g. `fp = hash` with no re-mix) is the one thing
that would break: the slot XOR and the fingerprint would then be functions of the same
bits, and the construction's error analysis no longer applies.

**(b) Only four widths are worth having.** The slot must be a machine word, so 33…64
bits all cost the same 8-byte slot:

| b | bytes/key (1.127·b/8) | 2.46 M keys | FP/probe |
|---|---|---|---|
| 8 | 1.127 | 2.64 MiB | 3.9e-3 |
| 16 | 2.254 | 5.29 MiB | 1.5e-5 |
| 32 | 4.509 | 10.58 MiB | 2.3e-10 |
| 40 (5-byte slot) | 5.636 | 13.22 MiB | 9.1e-13 |
| 48 (6-byte slot) | 6.763 | 15.87 MiB | 3.6e-15 |
| 56 (7-byte slot) | 7.891 | 18.51 MiB | 1.4e-17 |
| 64 | 9.018 | **21.16 MiB** | **5.4e-20** |

Byte-packed widths (40/48/56) need unaligned reads; 64 bits with a `ulong[]` is both
the simplest and the strongest, and the extra 7.9 MiB over b=40 does not cost probe
time (§6.4). **Recommendation: b = 64.**

**(c) The probe cost does not grow with b** — the only family where that is true.
A binary fuse query loads 3 slots of `b` bits each. Measured median probe:
69.2 ns at b=16 (5.5 MB array) vs 79.6 ns at b=64 (22.2 MB array) on a 16 MB-L3
machine — 15%, all of it cache/TLB, none of it algorithmic.

**(d) What breaks in the existing code if you just change the type.** In the C
reference, `binary_fuse8_t` and `binary_fuse16_t` are two hand-copied blocks whose only
differences are the slot type and the fingerprint function. The construction itself
never touches a fingerprint: it operates on 64-bit hashes in `t2hash`, `reverseOrder`
and `reverseH`, and only the final assign loop writes slots. So a 64-bit variant is
mechanically: `uint8_t *Fingerprints` → `uint64_t *`, the 8/16-bit fingerprint function
`hash ^ (hash >> 32)` → the second 64-bit hash, and the masking code for narrow widths
removed. That is the entire change — ~15 lines against the reference, as my port shows (§12).

---

## 5. Existing C#/.NET implementations (read, not used)

| package / repo | license | core lines | API | widths | notes |
|---|---|---|---|---|---|
| `Dissimilis/BinaryFuseFilter` (NuGet `BinaryFuseFilter`) | MIT | **1,395** (`BinaryFuseCore.cs` 403, three width files 135 each, layout/hash/serialize/ops ≈ 480) | `BinaryFuseFilter.Create(ReadOnlySpan<ulong> keys, FingerprintWidth)`, `IBinaryFuseFilter.Contains(ulong)`, `SizeInBytes`, `BitsPerKey`, `Serialize`/`TryDeserialize`; generic `BinaryFuseFilter<T>` with pluggable hasher, XxHash64 default | **8/16/32** | netstandard2.0/net8/net9/net10, unsafe, `ArrayPool` scratch, `MaxIterations = 1024`, `ArrayPool<ulong>` for `t2hash` and `reverseOrder` — i.e. the same construction and the same scratch arrays as the reference. The core is **generic over the slot type** (`IFingerprintOps<TFp>` with `Fingerprint/Xor/IsZero`), so a 64-bit variant is one 10-line ops struct plus a factory arm and a `FingerprintWidth.Bits64` value. |
| `asarnaout/XORFilter.Net` | MIT | **399** (`BaseXorFilter.cs` 267 + 3 width classes + CRC32) | `XorFilter8/16/32.Create(...)`, `Contains(byte[])` | **8/16/32** | classic XOR filter, `c = 1.23n + 32`, byte-array keys, per-width subclasses duplicating the same body. |
| `jonmat/FastIndex` | MIT | 920 (5 files) | builds an index (minimal perfect hash), not a membership filter | derives from XOR | shows the "store 2 bits of `found` in a side array" trick; not a filter. |

Outside C#: `FastFilter/xor_singleheader` (C, Apache-2.0, 999-line `binaryfusefilter.h`
with **8- and 16-bit variants only**, plus a separate `xorfilter.h`), `ayazhafiz/xorf`
(Rust, MIT, 2,299 lines, `Xor8/16/32`, `Fuse8/16/32`, `BinaryFuse8/16/32`, 7.37 M
downloads), `FastFilter/xorfilter` (Go), `FastFilter/fastfilter_java` (Java).

**No implementation anywhere supports > 32-bit fingerprints**, and I found no issue
tracker entry requesting it. The reason is visible in the code: every port is a
transcription of the 8/16-bit C reference and the fingerprint function is
`hash ^ (hash >> 32)` truncated to 32 bits — it simply has no more bits to give. The
absence is not a limitation of the algorithm.

**Do not take a dependency.** Our proposal should stay dependency-free
(`System.IO.Hashing`, which holds `XxHash64`, is a separate NuGet package rather than
part of the base class library), so the portable form is a single ~200-line file in the
app.

---

## 6. Benchmark

Environment: WSL2 guest on an AMD Ryzen 5 3600X, 4 vCPU, 16 MB L3, 16 GB RAM,
gcc 13.3.0, `-O3 -march=native`, single-threaded, keys from a splitmix64 stream
(distinct by construction), queries from an independent xorshift64 stream. The guest is
shared, so run-to-run spread is ±20–30%; medians are reported where it matters.

The harness is `/tmp/WideFingerprintFilters/bench.c` (336 lines): a faithful port of the
reference 3-wise construction with the slot width selectable (4-byte slots for
b ≤ 32 with a mask, 8-byte for b > 32), plus `ref.c`, which builds the **unmodified**
reference `binary_fuse8_t`/`binary_fuse16_t` from `FastFilter/xor_singleheader` on the
same keys.

### 6.1 Single filter, N = 2,460,000 (the assignment's N)

```
./bench single 2460000 64     # abridged; build/probe figures are medians of 6 and 10 runs
n=2460000 bits=64 bytes=22151168 bytes_per_key=9.0045 arraylen=2768896
seglen=16384 segcount=167 build_s=0.226 build_ns_per_key=91.9
fp_measured=0.000e+00 fp_expected=5.421e-20 lookup_ns=79.6
in_set_fn=2460000/2460000 fp_rate_1=0/20000000 hwm_kb=90760 hwm_delta_kb=69688
```

| quantity | value |
|---|---|
| fingerprint bytes | 22,151,168 (21.13 MiB) |
| bytes per key | **9.0045** (72.04 bits) |
| slots / segment length / segments | 2,768,896 / 16,384 / 167 |
| build time | 0.185–0.299 s (median 0.226 s), **77–121 ns/key** |
| negative probes | 20,000,000 → **0 false positives** |
| positive probes | 2,460,000 → **2,460,000 true (0 false negatives)** |
| probe latency | median 79.6 ns (range 78–212 ns) |
| process peak RSS during build | 90.7 MiB total, of which 69.7 MiB was allocated after the key array |

Width sweep on the same N (my harness; b ≤ 32 uses 4-byte slots so the byte column is
only meaningful for b = 64; the "natural slot" column is arithmetic from the measured
slot count):

| b | slots | measured B/key (slot width my harness used) | natural B/key | MiB @ natural | build ns/key | probe ns (median) | FP measured |
|---|---|---|---|---|---|---|---|
| 8 | 2,768,896 | 4.509 (32-bit slot) | 1.127 | 2.64 | 80–91 | 70–78 | 3.94e-3 (=2^-8) |
| 16 | 2,768,896 | 4.509 (32-bit slot) | 2.254 | 5.29 | 91 | 69.2 | 1.51e-5 (=2^-16) |
| 32 | 2,768,896 | 4.509 (32-bit slot) | 4.509 | 10.58 | 84 | 65–95 | 0 in 20 M (expected 2.3e-10) |
| 64 | 2,768,896 | 9.018 (64-bit slot) | 9.018 | 21.16 | 92 | 79.6 | 0 in 20 M (expected 5.4e-20) |

Only the b = 64 row uses its natural slot width; b = 8/16 ran through the 32-bit slot
path so that one code path could serve every width, which is why their measured bytes
column is 4.509. The construction never reads a fingerprint (it works on 64-bit hashes),
so build time is width-independent; only the output-array writes scale with b.

### 6.2 The real 23-list split (this repository's config, 2,455,832 entries)

The list counts are the ones in `newrepo/results/ci-amd64/original-exhaustive.exhaustive.json`
(`.list_counts`): tif.txt 1,851,038; pro.plus 225,088; pro 211,739; nsfw 92,428;
popupads 50,944; fake 17,553; plus 16 small lists and one empty one.

```
./bench lists 64
lists=23 keys=2455832 bits=64 total_bytes=22482944 total_mib=21.44
bytes_per_key=9.1549 build_s=0.294 vmhwm_mib=77.6 (baseline 1.9)
  list[21] n=1851038 bytes=16777216 b/key=9.06 arraylen=2097152 seglen=16384
  list[16] n= 225088 bytes= 2097152 b/key=9.32 arraylen= 262144 seglen= 4096
  list[17] n= 211739 bytes= 1966080 b/key=9.29 arraylen= 245760 seglen= 4096
  list[14] n=  92428 bytes=  884736 b/key=9.57 arraylen= 110592 seglen= 2048
  …
  list[07] n=     57 bytes=    1024 b/key=17.96 arraylen=    128 seglen=   32
```

| quantity | b = 64 | b = 32 |
|---|---|---|
| total fingerprint bytes | 22,482,944 (21.44 MiB) | 11,241,472 (10.72 MiB) |
| bytes per key | 9.155 | 4.578 |
| build time | 0.294 s | 0.388 s (single runs; width-independent within noise) |
| peak RSS of the whole build (VmHWM) | **77.6 MiB** | 66.8 MiB |
| worst per-list overhead | 17.96 B/key (57-key list) | 8.98 |
| largest-list overhead | 9.06 B/key | 4.53 |

Two observations that matter for the app:

- **Rounding is the only penalty for splitting into lists.** 9.155 vs 9.005 B/key is
  +1.7% for 23 separate filters; almost all of it comes from the lists under ~1,000
  keys, where the minimum array (3 segments × 32 slots) dominates. A single filter for
  the whole union would be 1.7% smaller but would lose per-list attribution.
- **Peak build memory is 3.5x the final structure** because the largest list (1.85 M
  keys, 77% of the data) needs its own scratch: 23.65 B/key × 1.85 M ≈ 44 MiB, plus
  18.7 MiB of 64-bit key hashes for all lists, plus the 21.4 MiB of finished filters.
  Measured 77.6 MiB against an analytic 82 MiB (untouched `calloc` pages explain the
  difference).

### 6.3 False-positive validation (the formula, not the theory)

`./bench fp <b> 200000000` on N = 2.5 M:

| b | negative probes | hits | measured | 2^-b | ratio |
|---|---|---|---|---|---|
| 16 | 200,000,000 | 3,062 | 1.531e-5 | 1.526e-5 | 1.003 |
| 20 | 200,000,000 | 195 | 9.750e-7 | 9.537e-7 | 1.022 |
| 24 | 200,000,000 | 11 | 5.500e-8 | 5.963e-8 | 0.922 (Poisson ±30%) |

And the **unmodified reference** on the same keys (`./ref`, 20 M probes):

| reference | bits/key | build ns/key | in-set | FP measured | 2^-b |
|---|---|---|---|---|---|
| `binary_fuse8` | 9.0178 | 71.2 | 2,500,000/2,500,000 | 3.8997e-3 | 3.9062e-3 |
| `binary_fuse16` | 18.0355 | 63.3 | 2,500,000/2,500,000 | 1.5350e-5 | 1.5259e-5 |

My port reproduces the reference's layout exactly (same 2,818,048 slots, same 16,384
segment length, same bits/key) and its 8/16-bit error rates, which is the evidence that
the 64-bit variant is the same algorithm and not a lookalike. At b = 64 the true rate is
1.1e-19 hits per probe, so a direct measurement would need ~10^19 queries; the claim
rests on (i) the construction being width-independent, (ii) the measured agreement at
b = 8…24 over 600 M probes, and (iii) the count of 0 hits at b = 32/64 in 20 M probes
which is consistent with any rate below 1.5e-7 and therefore not evidence on its own.

### 6.4 Does 64 bits cost lookup time?

Interleaved 5x2 runs at N = 2.46 M, same process shape:

| b | array size | probe median | probe range |
|---|---|---|---|
| 16 | 5.5 MiB | **69.2 ns** | 66.3–124.0 |
| 64 | 22.2 MiB | **79.6 ns** | 78.0–212.1 |

15% slower, and the difference is cache residency (5.5 MiB sits in the 16 MB L3; 22.2
MiB does not), not the fingerprint width. On the target A53 (512 KB L2, no L3) both
arrays miss, both probes fetch three 64-byte lines, and the per-probe cost should be
the same **[INFERENCE from the cache geometry, not measured on the device]**.

### 6.5 Construction scratch, by allocation

For the reference algorithm (and therefore for any faithful port):

| array | bytes per key | for 1.85 M-key list |
|---|---|---|
| `reverseOrder` (`uint64`, n) | 8.0 | 14.8 MB |
| `t2hash` (`uint64`, capacity = 1.127 n) | 9.02 | 16.7 MB |
| `alone` (`uint32`, capacity) | 4.51 | 8.4 MB |
| `t2count` (`uint8`, capacity) | 1.13 | 2.1 MB |
| `reverseH` (`uint8`, n) | 1.0 | 1.9 MB |
| `startPos` | ~0 | — |
| **scratch subtotal** | **23.65** | **43.9 MB** |
| caller's key hashes (`uint64`, n) | 8.0 | 14.8 MB |
| output fingerprints (`uint64`, capacity) | 9.02 | 16.7 MB |

`reverseOrder` can be halved by storing `uint32` indices into the key array instead of
the 64-bit hash (recomputing the hash on unwind), and `t2hash` cannot shrink because
the peeling set stores the XOR of the 64-bit hashes. Neither is needed at our scale.

---

## 7. Comparison for the actual decision (N = 2.46 M, 21 lists)

FP per query is given for **3 label probes** (the assignment's basis) and, in the last
column, for the app's real scan of ~23 lists × ~3 labels ≈ **70 probes**, at 1,000 qps
(86.4 M queries/day). The exhaustive figure in `docs/analysis.md` is that a query
touches **44 sets** (allow + block per adblock list), i.e. up to ~130 probes on the
worst-case all-miss path; 70 is the central case and both error columns double at 130.

| structure | bytes per entry | total MiB | bits/key | FP per probe | FP per query (3) | FP/query (70 probes) | FP/day @1k qps | lookups per probe | build peak (per key) | C# lines |
|---|---|---|---|---|---|---|---|---|---|---|
| original `HashSet<string>` (measured) | 105.8 | 269.4 | — | 0 | 0 | 0 | 0 | 1 | ~2x | — |
| accepted compact `DomainSet` (measured) | 35.1 | 89.4 | — | 0 | 0 | 0 | 0 | ~21 byte compares | 1x | ~200 |
| exact sorted `ulong[]` (derived) | 8.00 | 18.7 | 64 | `N/2^64` = 1.3e-13 | 4.0e-13 | 9.4e-12 | 8.1e-4 | ~4–6 misses | 1x + sort | ~60 |
| 64-bit open-addressing hash table (derived; 41.0 MiB measured for the 21 sets) | 10.67 @0.75 | 25.0 | 85.3 (64 stored) | 1.3e-13 | 4.0e-13 | 9.4e-12 | 8.1e-4 | 1–2 | 2x | ~120 |
| XOR filter, b=64 (derived) | 9.84 | 23.1 | 78.7 | 5.4e-20 | 1.6e-19 | 3.8e-18 | 3.3e-10 | 3 | 2x | ~150 |
| **binary fuse, b=64** (measured) | **9.005** (9.155 split) | **21.13** (21.44 split) | **72.1** | **5.4e-20** | **1.6e-19** | **3.8e-18** | **3.3e-10** | **3** | **2.6x + 8 B/key hashes** | **~200** |
| binary fuse, b=32 (measured) | 4.509 | 10.58 | 36.1 | 2.3e-10 | 7.0e-10 | 1.6e-8 | **1.4** | 3 | 2.6x | same |
| binary fuse, b=48 (derived) | 6.763 | 15.87 | 54.1 | 3.6e-15 | 1.1e-14 | 2.5e-13 | 2.2e-5 | 3 | 2.6x | same |
| Ribbon, b=64, w=64 (derived) | ≈10.5 | 24.6 | 84 | 5.4e-20 | 1.6e-19 | 3.8e-18 | 3.3e-10 | 64 × 8 B (≈8 lines) | 3.2x (28.8 B/key) | ~450 |
| GCS, b=64 (derived) | 8.19 | 19.2 | 65.5 | 5.4e-20 | 1.6e-19 | 3.8e-18 | 3.3e-10 | ~21 seeks + decode | 8 B/key + sort | ~350 |
| cuckoo, b=67, non-pow2 (derived) | 8.77 | 20.6 | 70.2 | 8/2^67 = 5.4e-20 | 1.6e-19 | 3.8e-18 | 3.3e-10 | 2 | 0 (in-place) | ~400 |
| cuckoo, b=64, pow-2 table (derived) | 13.6 | 31.9 | 109 | 4.3e-19 | 1.3e-18 | 3.0e-17 | 2.6e-9 | 2 | 0 | ~400 |
| quotient, r=64 (derived) | 14.5 | 34.0 | 116 | 2^-64 × run | — | — | — | 1–2 | 0 | ~500 |

"Derived" rows are arithmetic from the formulas in §3 (bits/key × 2.46 M / 8, load
factors as stated), not measurements. The `DomainSet` and `HashSet` rows are the
measured `anon` figures at 2,670,703 per-list entries from `docs/analysis.md` §2.

**Reading the table.** At `b = 64` the binary fuse is the smallest structure that also
has a 3-access probe; GCS is ~9% smaller but pays 21 seeks; cuckoo is 2.6% smaller only
if you forgo the power-of-two table; Ribbon and quotient are larger *and* slower. Going
to `b = 32` halves the memory but buys ~1.4 false block decisions per day at 1,000 qps,
which is exactly the kind of thing a DNS maintainer will be asked about. `b = 48` (6-byte
slots) is a real option if 5.3 MiB matters more than unaligned reads.

---

## 8. Fit to the Advanced Blocking app

**The app already has exactly the right interface.** The accepted compact set in
`bench/structures/DomainSet.cs` exposes

```csharp
public void Add(string domain);
public void Sort();               // build barrier
public bool Contains(string domain);
public int RawCount { get; }
```

and the app's call sites (`IsZoneBlocked`, `IsZoneFound`) only ever use the boolean plus
the set identity. A filter-backed class keeps that API verbatim and drops `_buffer`,
`_offsets` and `_filter` — the diff is one class body plus one new ~200-line filter file.

**Per-list attribution is free.** The app scans lists in config order and reports the
list it hit; with one filter per list that is unchanged.

**The `domain=` field of the TXT report is the probe key, not a stored string.** The
recorded artifacts show `1win-sl101.top → domain=top` and
`sub.edge-hosts.example.com → domain=edge-hosts.example.com`
(`results/ci-amd64/*-run3.reports.txt`, `*-edge.edge.txt`), i.e. the field is the
*suffix that matched*, which the app already has in hand when it probes. The accepted
compact set proves this independently: its `Contains` returns only a `bool`, yet its
differential run reproduced every report byte-for-byte (`docs/analysis.md` §6,
digests `81817805df6f35cd` / `484d84857aa6767b` / `191737ebd76058b9`). **So a
membership-only structure is sufficient for the current behavior** — no key retrieval,
no change to the report format.

**The update path already matches the immutability.** Lists are fetched, parsed, built
into a new set, and swapped in atomically; `Add`/`Sort` is already a
build-then-freeze API. A filter cannot be extended after `Sort()`, which costs nothing
here but must be documented in the class comment (today `Add` after `Sort` throws
`InvalidOperationException`, so the contract is already there).

**Memory during a 24 h reload.** Today: 229.3 MiB `cgroup memory.peak` for the accepted
candidate, 543.0 MiB for the original (`docs/analysis.md`, reload table). With filters:
old 21.4 + new 21.4 + the largest list's scratch (1.85 M keys × 23.65 B = 44 MiB) +
that list's 14.8 MiB of key hashes ≈ **99 MiB**, or ≈51 MiB if the largest list is
built in shards of 256 k keys (see below). That is the number to put in the upstream
issue.

**Sharding caps the scratch.** Split each list's keys by `hash(key) % S` into `S`
independent filters of ~256 k keys. A query computes the same shard index and probes
exactly one shard, so it is still 3 slot reads, the FP is still `2^-b`, and the space
grows only by per-shard segment rounding (~1%). The scratch then peaks at 256 k ×
23.65 B ≈ 6 MiB instead of 44 MiB. `oschonrock/binfuse` is described as a binary fuse
library "including a sharded filter" (repo description, **UNVERIFIED** — I did not read
its code), so this is a known pattern rather than an invention.

**Seed from a CSPRNG.** The reference seeds from a fixed constant
(`uint64_t rng_counter = 0x726b2b9d438b9d4d`), so every build of the same list produces
the same filter; anyone with the list and the code can then compute which names are
false positives. At `2^-64` that is not a practical attack, but the fix is one line
(`RandomNumberGenerator.GetBytes`) and removes the argument entirely.

**Cost of the probe in the app's loop.** The app pays one or two 64-bit hashes of the
UTF-8 suffix per probe (one if a 128-bit hash is split, two if the two-seed form is
used). The compact set today pays a 7-hash Bloom test plus, on a Bloom hit, a binary
search; the filter pays the hash (~20–30 cycles per pass for a 20-byte name) plus 3
loads. On the A53 the 3 loads dominate.

---

## 9. Caveats, stated plainly (these belong in the upstream issue)

1. **It is still probabilistic.** 5.4e-20 per probe, not zero. At 1,000 qps with ~70
   probes per query that is 3.8e-18 per query, i.e. **1.2e-7 expected false blocks per
   year** of continuous load (2.2e-7 at the 44-set worst case) — but it is not "exact",
   and the structure must not be described as exact.
2. **It cannot be built incrementally.** `Add` after `Sort` must throw; a list update is
   a full rebuild. Build cost measured 77–121 ns/key in C (0.23 s for 2.46 M keys);
   a C# port will be slower **[INFERENCE: 2–4x, unmeasured — no .NET SDK on this
   machine]**, i.e. ~0.5–1 s, which is noise against the 62.9 s reload dominated by
   parsing.
3. **A 64-bit fingerprint needs its own hash.** Deriving it from the same 64 bits as the
   index silently breaks the error analysis. Budget a second hash of the key, or a
   128-bit hash split in two.
4. **The filter answers membership, not "which entry".** Fine for this app (§8), fatal
   for any future feature that needs to return the stored string.
5. **Duplicates must be removed before construction.** The reference handles them by
   sorting the 64-bit hashes and dropping equal neighbours; two distinct names that
   collide in 64 bits would then be merged into one — harmless (both are members) and a
   ~2.5e-13 chance per list.
6. **Sizing is a build-time decision.** Unlike Bloom, you cannot add capacity later, and
   the array size is fixed by `N` at `Sort()`.
7. **Do not describe Ribbon or GCS as worse in general.** Ribbon is the best choice at
   `b ≤ 8` and GCS is ~9% smaller at `b = 64`; the choice here is driven by the probe
   shape, and the note should say so.
8. **Only 8/16/32-bit code exists to copy from.** The 64-bit variant is new code that
   needs its own differential test (the existing exhaustive A+TXT pass is exactly that
   test, and it must be re-run).

---

## 10. What is most promising, and the smallest C# form

**Recommendation: 3-wise binary fuse filter, 64-bit fingerprints, one per list,
`ulong[]` slots, two-seed fingerprint (index from one hash, fingerprint from another),
sharded at 256 k keys only if the reload peak matters.**

Numbers to quote: **9.005 B/key**, **21.1 MiB for 2.46 M domains** (21.44 MiB as the
real 23-list split), **FP 5.4e-20 per probe**, **3 slot reads**, **0.23 s build in C**,
**77.6 MiB measured peak for the full 23-list build**.

The from-scratch C# file, in the shape the app needs:

```csharp
sealed class Fuse64Set            // sketch, bodies elided; ~200 lines; same API as DomainSet
{
    ulong[] _slots;               // ArrayLength = (SegmentCount + 2) * SegmentLength
    ulong _seed;
    uint _size, _segLen, _segMask, _segCount, _segCountLen, _arrayLen;
    ulong[]? _keys;               // Add(): the 64-bit hashes, 8 B/entry
    int _count;

    public void Add(string domain)        // hash once, keep the ulong
    public void Sort()                    // sort + dedup, build, drop _keys
    public bool Contains(string domain)   // 3 loads + compare
}
```

Concretely the port is: murmur64 finalizer (6 lines), splitmix64 (5), `MulHi`
(`Math.BigMul(ulong,ulong,out ulong)` on .NET 10 — 1 line), layout math copied from
Table 1 (15), `SegmentLength`/size-factor (10), the build loop (~90: partial sort by
segment via a count-and-scatter pass, counter/XOR pass, peel stack, reverse assign),
`Contains` (~15), plus the class plumbing. My C implementation of exactly this is
**~150 lines** (`bench.c` lines 43–205, including the layout code and the 4-byte-slot
generality it does not need); the equivalent minimal C# is **~200 lines**. For
comparison, `Dissimilis/BinaryFuseFilter` is 1,395 lines for three widths *with*
serialization, `ArrayPool` scratch, SIMD-free pooling and a generic hasher layer — all of
which we do not need.

If 21 MiB is judged too much for a 1 GiB device, the same code with `Bits = 32` and a
`uint[]` slot array is 10.58 MiB and `2.3e-10` per probe — a one-constant change, at
the cost of ~1.4 expected false block decisions per day at 1,000 qps.

---

## 11. What I could not verify

- **No .NET SDK on this machine**, so the C# numbers (build time, exact byte counts of
  a managed `ulong[]`, JIT probe latency) are not measured. The C numbers are given as
  the algorithm's cost; the C# multiplier (2–4x on build) is **[INFERENCE]** from the
  constant factor you would expect for the same loops with bounds checks.
- **No measurement on the target (Orange Pi Zero 3, Cortex-A53).** The claim that b=64
  and b=16 cost the same per probe on that device is an inference from its cache
  geometry (512 KB L2, no L3) and the measured 3-line fetch per probe; it needs the
  existing lab harness to confirm.
- **The reference implementations' author-stated failure rates** (<1% for binary fuse,
  ≥0.8 for XOR) are quoted from the papers; I did not run a 10,000-trial retry
  experiment. My runs needed no retries (0 of ~40 builds printed a failure).
- **`oschonrock/binfuse`'s sharded filter**: the repository description mentions it but
  I did not read the code (the shallow clone returned no `src/`), so the sharding
  suggestion is presented as a design, not as an adopted implementation.
- **Ribbon at b = 64**: no published evaluation exists above `r ≈ 16`. The b=64 space
  figure in §7 (`≈10.5 B/key`) is derived from the paper's Eq. 7 with `w = 64`, and the
  probe-cost claim (8 cache lines) from the paper's query description; both are
  **[INFERENCE]**, which is itself the point — there is no evidence that wide Ribbon
  has been tried.
- **GCS at b = 64**: the size (65.5 bits/key at `M = 2^64`, 65.05 at the optimal
  `M = 1.497·2^63`) follows from Wuille's closed form, but I did not build a GCS to
  confirm it or to measure the real lookup cost of a 21-seek search.
- **The `domain=` semantics**: inferred from recorded report artifacts plus the fact
  that the accepted bool-only `Contains` reproduced them byte-for-byte. I could not
  read the app's current `App.cs` (it is not in this repository).

---

## 12. Appendix: exact commands and outputs

Environment: `gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`, `-O3 -march=native`,
AMD Ryzen 5 3600X (4 vCPU WSL2 guest), 16 MB L3.

```bash
mkdir -p /tmp/WideFingerprintFilters/repos && cd /tmp/WideFingerprintFilters/repos
git clone --depth 1 https://github.com/FastFilter/xor_singleheader.git
git clone --depth 1 https://github.com/FastFilter/fastfilter_cpp.git
git clone --depth 1 https://github.com/ayazhafiz/xorf.git
git clone --depth 1 https://github.com/Dissimilis/BinaryFuseFilter.git
git clone --depth 1 https://github.com/asarnaout/XORFilter.Net.git
git clone --depth 1 https://github.com/jonmat/FastIndex.git

cd /tmp/WideFingerprintFilters
gcc -O3 -march=native -o bench bench.c -lm          # my 8/16/32/64-bit harness
gcc -O3 -march=native -I repos/xor_singleheader/include -o ref ref.c -lm   # reference

./bench check                                        # no false negatives, all widths
./bench single 2460000 64                            # the table in 6.1
./bench single 2460000 32
./bench lists 64                                     # real 23-list split
./bench lists 32
./bench fp 16 200000000; ./bench fp 20 200000000; ./bench fp 24 200000000
./ref                                                # reference cross-check
```

Selected raw output:

```
$ ./bench check
bits= 8 n=   1000 in_set=1000/1000 ok
bits= 8 n= 400000 in_set=400000/400000 ok
bits=16 n= 400000 in_set=400000/400000 ok
bits=32 n= 400000 in_set=400000/400000 ok
bits=64 n= 400000 in_set=400000/400000 ok

$ ./ref
REF fuse8  ok=1 bytes=2818088 b/key=9.0178 arraylen=2818048 seglen=16384 build_s=0.178 build_ns/key=71.2 in_set=2500000/2500000 fp=3.8997e-03 (2^-8=3.9062e-03)
REF fuse16 ok=1 bytes=5636136 b/key=18.0355 arraylen=2818048 seglen=16384 build_s=0.158 build_ns/key=63.3 in_set=2500000/2500000 fp=1.5350e-05 (2^-16=1.5259e-05)

$ ./bench lists 64
lists=23 keys=2455832 bits=64 total_bytes=22482944 total_mib=21.44 bytes_per_key=9.1549 build_s=0.294 vmhwm_mib=77.6 (baseline 1.9)

$ ./bench fp 20 200000000
fp bits=20 n=2500000 queries=200000000 hits=195 measured=9.7500e-07 expected=9.5367e-07 ratio=1.022 bytes_per_key=4.5089 lookup_ns=97.7
```

Artifacts: `/tmp/WideFingerprintFilters/{bench.c, bench, ref.c, ref, papers/, repos/}`.
The 8-byte-slot variant is `fuse_t` in `bench.c`; its `Bits` field masks the fingerprint
so widths 16/20/24 share the 32-bit slot path used for the false-positive validation;
`Bits = 64` takes the `ulong` path.
