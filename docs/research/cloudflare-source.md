# Cloudflare's public source code, read: what is actually portable to our block-list problem

Source-level audit, 2026-11-02. Companion to `docs/research-cloudflare.md` (blog/docs sweep) —
this note is **only** about code I cloned and read, plus benchmarks I ran myself.

Everything factual is tagged:

- **[SRC]** — read from a file in a cloned repo; path given.
- **[MEASURED]** — I ran it; command given in §13.
- **[INFERENCE]** — my arithmetic/derivation, not measured.
- **UNVERIFIED** — could not open or could not confirm.

Repos cloned under `/tmp/CloudflareSourceAndTalks/`, at these commits:

| repo | commit | date |
|---|---|---|
| `cloudflare/cloudflare-blog` (contains `2020-02-mmuniq/`) | `725a86fd134e86df621b86fc89b5eee7119908e7` | |
| `cloudflare/trie-hard` | `a1687fe51410b2df9fc020e1fb0b61c8320a9ed2` | |
| `cloudflare/entropy-map` | `989fa16bb98e8f9e9828c6bc7208f6ae445aeab6` | 2026-09-09 |
| `cloudflare/pingora` | `1adcb3815b70d6594379db044b5aa67f9bc1af76` | 2026-10-30 |
| `cloudflare/foundations` | `bba016f883d64f2fd2ed465b9aeaf27df0531799` | |
| `cloudflare/ahocorasick` | `054963ec939627782012c7c34eefd2942488d4e1` | |
| `cloudflare/wirefilter` | `f656cc5c04bc112977d949b6afd48c5ebe426ece` | |
| `cloudflare/mmap-sync` | `20826943e6e95f6e28d1a4496d1621cebd4206a2` | |
| `cloudflare/cardinality-estimator` | `e8497bf3897ddfd98a6e5e2b88971e11994056d8` | |

**Input data for every measurement**: the 23 list files in `lab/lists/` (sha256-named), normalised
to bare hostnames (strip `||`/`^`/`*.`/comment/`0.0.0.0 ` hosts-form, keep `[a-z0-9_.-]` dotted
names): **2,292,735 unique names, 38,453,838 name bytes, mean 16.77 B, median 14 B**, 2,670,922
per-list entries (duplication factor 1.165, i.e. only 6.2 MiB of the 42.9 MiB of per-list name
bytes are duplicates). The number matches the brief's 2.29 M unique / 2.46 M entries closely enough
that the measurements below should be read as ours, not as a synthetic corpus.

---

## 0. Bottom line

1. **The one Cloudflare artifact that is already the right shape for us is not a crate, it is a
   ~175-line C program**: `2020-02-mmuniq/mmuniq-hash.c` in `cloudflare/cloudflare-blog`. It is a
   power-of-two, linear-probing table storing **nothing but the 64-bit hash** in each 8-byte slot,
   with `0` as the empty sentinel. `mmuniq.c` in the same directory is the production version: it
   resizes, keeps the fill rate at 0.6, hashes with AES-NI in the same pass as the newline scan,
   and batches 128 prefetches. **[SRC]** Run as-is on our 2.29 M names — one merged table, no
   per-list attribution, hashes only without the names — it needs **35.5 MiB RSS and 0.57 s**
   **[MEASURED]**, against our 98 MiB `DomainSet`; the same structure kept as 23 per-list tables at
   α ≤ 0.5 is 43.6 MiB of slots and gives attribution for free (§1.3, §11 T1).
2. **`trie-hard` is the wrong tool at our size, and we now have the numbers**: on our 2.29 M names
   it produces 3.89 M nodes at a measured **40 B/node**, i.e. **148 MiB of nodes (67.8 B/name)
   plus the name blob = 197 MiB, built with a 473 MiB peak RSS** **[MEASURED]**. Its own published
   win is a 119-entry map with a >90 % miss rate on 10–30 short header names
   (`blog.cloudflare.com/pingora-saving-compute-1-percent-at-a-time`). Different regime entirely.
3. **`entropy-map`'s MPHF is the one place where Cloudflare code beats the obvious design** — but
   it needs a real port. On our 2.29 M domains the index costs **2.10–2.72 bits/key = 0.26–0.34
   B/key**, and `Set<u64>` (index + 8-byte fingerprints) is **8.34 B/key, exact, 0 false
   positives** **[MEASURED]**. The linear-probing table we would actually deploy is 14.6 B/key at
   α = 0.547 (measured, §1.3), so the MPHF is ~40 % smaller — for 4.6 s of single-threaded
   immutable build and ~250–300 lines of C#. The quantified-FP variant (MPHF + **1-byte
   fingerprint: 1.34 B/key, 0.368 % false positives**; 2 bytes → 2.34 B/key, 0.0017 %) is the
   honest "how small could a lossy set be" number.
4. **`pingora-lru` is the best layout lesson in the org** (not the data structure, the *layout*):
   payload stored once in a contiguous arena, `u32` indices instead of pointers, head/tail
   sentinels at indices 0/1, free-list recycling, and a lookup table that holds only
   `u64 hash → u32 slot`. `async_lru.rs` states the rule explicitly: "The real key `K` lives only
   in the linked list arena nodes … No key duplication."
5. **`foundations` has no collections at all** — the module list is `addr, cli, derive, panic,
   ratelimit, security, sentry, settings, telemetry, utils`, and `settings/collections.rs` is a
   `serde` wrapper around `IndexMap` for config ordering, not a data structure. `pingora-foundations`
   is a telemetry shim over it. So there is nothing to take from that crate; anyone citing
   "foundations collections" is thinking of something else.
6. **`cloudflare/ahocorasick` is the quantitative anti-pattern**: its node is
   `child [256]*node` + `fails [256]*node` = 4 KiB of pointers *per trie node* **[SRC]**.
7. **No Cloudflare conference talk on these structures exists that I could open.** Details and the
   exact searches in §10; short version: no Cloudflare talk at RustConf 2026, none in the P99 CONF
   agenda/on-demand index, no USENIX paper, and the one Cloudflare TV "Quicksilver" session I found
   is a Tagalog re-record whose page 404s. The engineering content lives in the blog post, not in a
   talk, and I could not open any video transcript.

---

## 1. `cloudflare-blog/2020-02-mmuniq/` — the linear-probing hash table, in Cloudflare's own code

Five files: `mmuniq.c` (10,396 B — the real one), `mmuniq-hash.c` (4,742 B — the simple
fixed-size one the blog post links to), `mmuniq-bloom.c` (6,785 B), `csiphash.c` (4,272 B,
Marek Majkowski's MIT SipHash), `Makefile`. This is the code behind
<https://blog.cloudflare.com/when-bloom-filters-dont-bloom/>; the previous research note covers
that post's argument, this section covers the *code*.

### 1.1 `mmuniq-hash.c`: the smallest useful form

The whole data structure, verbatim from `mmuniq-hash.c`:

```c
static uint64_t global_size = DEFAULT_HASH_SIZE;   /* 500,000,000 */
static uint64_t global_size_mask;

static void process_line(char *s, int l, uint64_t *bm)
{
        uint64_t h = siphash24((const uint8_t *)s, l, k0, k1, NULL);
        uint64_t i = 0;
        for (i = h; i < h + 4096; i += 1) {
                uint64_t *v = &bm[i & global_size_mask];
                if (*v == 0)        { *v = h; miss = 1; break; }
                else if (*v == h)   { miss = 0; break; }
                hash_conflicts += 1;
        }
        ...
}
```

and the sizing:

```c
global_size_mask = 1;
while (global_size_mask <= global_size) global_size_mask <<= 1;
global_size_mask -= 1;
size_t bm_sz = (global_size_mask + 1) * 8;                  /* 8 B per slot */
uint64_t *bm = mmap(NULL, bm_sz, PROT_READ|PROT_WRITE,
                    MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE, -1, 0);
```

| property | value | tag |
|---|---|---|
| bytes per slot | **8** (the raw 64-bit hash; no separate key) | [SRC] |
| empty sentinel | hash value `0` (a real hash of 0 is silently lost) | [SRC] |
| probe | linear, `i++` masked, hard stop after **4096** probes, then it *reports a duplicate* and increments `overflow_count` | [SRC] |
| load factor | **not enforced**: `-n` is the user's cardinality estimate; table = next power of two ≥ n | [SRC] |
| resizing | none in this file (see `mmuniq.c`) | [SRC] |
| allocation | anonymous `mmap` + `MAP_POPULATE` — the table never touches the managed heap | [SRC] |
| hash | SipHash-2-4, fixed keys `0xdeadbeeffadebabe` ×2 | [SRC] |

The 4096-probe cap is worth noting as a *correctness* choice: past the cap the program calls the
line a duplicate (the conservative direction for a dedup tool, the wrong direction for a block
list — we must never silently drop a rule).

### 1.2 `mmuniq.c`: what a productionised version adds

Same table, plus:

- **resize**: when `global_items > fill_rate * (mask+1)`, mmap a table of twice the slots and
  reinsert every non-zero slot, then `munmap` the old one. `DEFAULT_FILL_RATE 0.6`, clamped to
  `[0.1, 0.9]`; `fill_rate` is a CLI flag `-f`. **[SRC]**
- **initial size derived from the CPU**, not the input: `sysconf(_SC_LEVEL3_CACHE_SIZE)`, doubling
  from 4096 slots until `slots*2*8 >= L3` — i.e. the table starts about half the L3 size.
  **[SRC]** (main(), `mmuniq.c:263+`)
- **one pass for newline + hash**: `find_nl_and_hash()` loads 16 bytes with
  `_mm_loadu_si128`, finds `'\n'` with `_mm_cmpeq_epi8`/`_mm_movemask_epi8`, and updates a 128-bit
  AES state with the same 16 bytes:
  `hash = _mm_aesenc_si128(_mm_xor_si128(hash, piece), rk0); hash = _mm_aesenc_si128(hash, rk1);`
  and finally `h = hash[0] ^ hash[1]`. Round keys are constants; there is a `NOSSE` build that
  falls back to SipHash. **[SRC]**
- **batched prefetch**: 128 pending lines, `__builtin_prefetch(&bm[h & mask])` issued as soon as
  the hash is known, inserts deferred to the end of the batch — the standard "hash a batch, then
  probe a batch" trick so the misses overlap. **[SRC]**

| property | value | tag |
|---|---|---|
| bytes per slot | 8 | [SRC] |
| default fill rate | **0.6** (0.1–0.9 accepted) | [SRC] |
| resizing | double + full reinsert; peak = old + new | [SRC] |
| prefetch batch | 128 entries | [SRC] |
| probe bound | `OVERFLOW_AFTER 4096` | [SRC] |
| hash | AES-NI, 16 B/step, 64-bit output; SipHash fallback | [SRC] |

### 1.3 What it costs on *our* data

`mmuniq-hash.c` compiled unmodified and fed our normalised domain file:

```
$ gcc -O2 -o mmuniq-hash mmuniq-hash.c -lm
$ ./mmuniq-hash -n 2292735 < domains.txt > out.txt
[.] Parameters: n=4194304 size=4MiB
[.] Hash conflicts 0.602 per line
wall=0.57 s   maxrss=36,324 KiB    output lines = 2,292,735
```

**[MEASURED]**

| quantity | value |
|---|---|
| slots | 4,194,304 (next power of two ≥ 2,292,735) |
| load factor | 0.547 |
| slot bytes | 33,554,432 B = 32.0 MiB |
| process RSS | **35.5 MiB** |
| extra probes per insert | **0.602** |
| wall time | 0.57 s (includes `MAP_POPULATE` of 32 MiB) |

Two things to keep:

- The measured 0.602 extra probes at α = 0.547 matches the textbook linear-probing expectation
  `½(1 + 1/(1−α)) − 1 = 0.604` **[INFERENCE]**. So the probe behaviour at these load factors is
  completely predictable and there is no reason to be afraid of α ≈ 0.6.
- The **power-of-two rounding is the real cost**: 4.19 M slots for 2.29 M keys = 14.6 B/key.
  `mmuniq-hash` sizes with `while (mask <= n) mask <<= 1`, i.e. the smallest power of two *strictly
  greater* than n, which lands at α = 0.547 for our merged set but at **α = 0.985** for a set whose
  size is just under a power of two. That matters when you size per list instead of merged, and the
  comparison has to be made at equal load factor **[INFERENCE, computed from the real per-list
  counts]**:

  | layout | slots | bytes | load factor |
  |---|---|---|---|
  | 23 per-list tables, mmuniq rule | 2,860,257 | **21.8 MiB** | 0.934 avg, **0.985** for the big list → tens of probes |
  | 23 per-list tables, α ≤ 0.5 | 5,720,514 | **43.6 MiB** | ≤ 0.5 |
  | 1 merged table, mmuniq rule | 4,194,304 | **32.0 MiB** | 0.547 |
  | 1 merged table + `uint[]` list mask | 4,194,304 | **48.0 MiB** | 0.547 |

  So: per-list sizing at the *same* rule looks cheaper but is unusable at α = 0.985; at an equal
  α ≤ 0.5 the merged table's slots are smaller (32 vs 43.6 MiB) but adding the per-name list mask
  puts merged at 48 MiB, i.e. **per-list tables at α ≤ 0.5 (43.6 MiB) are the cheapest correct
  option and give attribution for free**. Merging wins only when you would otherwise store
  duplicated names — and only 6.2 MiB of the 42.9 MiB of per-list name bytes are duplicates.

### 1.4 Port-ready C# (this is the one I would actually do)

```csharp
// One table, 8 B/slot, exact "no resize while serving" immutable build.
sealed class HashSet64 {
    readonly ulong[] _slots;          // 0 == empty
    readonly int _mask;               // _slots.Length - 1
    public HashSet64(int expected) {
        int n = 1; while (n < (long)expected * 2) n <<= 1;   // alpha <= 0.5 like mmuniq's 0.6
        _slots = new ulong[n];        // Array.Clear == calloc, zero pages, no per-slot work
        _mask  = n - 1;
    }
    public void Add(ulong h) {
        if (h == 0) h = 1;            // mmuniq's only wart: 0 is the sentinel
        int i = (int)h & _mask;
        for (int probes = 0; probes < 4096; probes++, i = (i + 1) & _mask) {
            ulong v = _slots[i];
            if (v == h) return;       // duplicate
            if (v == 0) { _slots[i] = h; return; }
        }
        throw new InvalidOperationException("table full");   // never silently drop a rule
    }
    public bool Contains(ulong h) {
        if (h == 0) h = 1;
        int i = (int)h & _mask;
        for (int probes = 0; probes < 4096; probes++, i = (i + 1) & _mask) {
            ulong v = _slots[i];
            if (v == h) return true;
            if (v == 0) return false;
        }
        return false;
    }
}
```

Notes that matter and are all traceable to the C:

- `new ulong[]` in .NET is zero-filled by the GC, so the "empty" sentinel costs nothing to
  initialise (the C uses `mmap`'s zero pages for the same reason) **[INFERENCE]**.
- Do **not** size to `expected` — size to `2·expected` so α ≤ 0.5; at α = 0.547 we measured
  0.602 extra probes, which is a second cache line touched on ~60 % of lookups. **[MEASURED] +
  [INFERENCE]**
- The 64-bit hash per name is the whole per-name cost. At 2.29 M names × ~3 suffixes per query this
  is 3 hashes of short strings per lookup — the same work `HashSet<string>` does once per *string*,
  three times over, so expect lookup cost to be in the same class as today, with 4× less memory.
- On x64 you can hash 16 B at a time with `System.Runtime.Intrinsics.X86.Aes.Encrypt`
  (BCL, no package) exactly as `mmuniq.c` does; on ARM32/ARM64 keep a scalar path. **[INFERENCE]**

---

## 2. `cloudflare/trie-hard` — layout, own benchmarks and their conditions, and our numbers

### 2.1 Data layout, read from `src/lib.rs` (1,055 lines) and `src/u256.rs` (193 lines)

```rust
pub struct TrieHardSized<'a, T, I> {
    masks: MasksByByteSized<I>,          // [I; 256] — letter -> 1-bit mask, 1..32 B each
    nodes: Vec<TrieState<'a, T, I>>,     // the whole trie, contiguous, root at index 0
}
struct SearchNode<I> { mask: I, edge_start: usize }      // 8+8 B for I=u64
enum TrieState<'a, T, I> {
    Leaf(&'a [u8], T),
    Search(SearchNode<I>),
    SearchOrLeaf(&'a [u8], T, SearchNode<I>),
}
```

- The integer width is chosen from the number of **distinct bytes** in the key set: `..=8 → u8`,
  `9..=16 → u16`, `17..=32 → u32`, `33..=64 → u64`, `65..=128 → u128`, `129.. → U256`.
  (**[SRC]** `MasksByByte::new`.)
- **There is no edge array.** Children of a node live in `nodes[edge_start .. edge_start + popcount(mask)]`,
  in ascending child-byte order; the child's index is computed, not stored:
  ```rust
  let mask_res = self.mask & trie.masks.0[c as usize];
  (mask_res > 0).then(|| {
      let smaller = mask_res - 1;
      self.edge_start + (smaller & self.mask).count_ones() as usize
  })
  ```
  That is `edge_start + popcount(mask & (input_bit - 1))` — one AND, one decrement, one `popcnt`.
  The README's phrase "children stored in a central vec" refers to this; the edges themselves cost
  **0 bytes**. **[SRC]**
- Leaves store the *original key as a slice* (`&'a [u8]`, 16 B fat pointer) plus `T`, and `get`
  compares the remaining bytes on a leaf hit (`k.len() == key.len() && k[i..] == key[i..]`). So the
  trie does not own the strings; the caller keeps the blob. **[SRC]**
- Build is BFS over a `VecDeque<StateSpec>` against a `BTreeMap<&[u8], T>` of all keys — i.e. the
  **builder needs the full key set sorted in a B-tree**, which is where the build peak goes. **[SRC]**

### 2.2 Its own benchmarks, and the exact conditions

README (`README.md`) **[SRC]**:

| claim | measured on |
|---|---|
| time to read 10k entries | a map of **119 entries**, "containing only lower-case characters, numbers, and `-`", read 10k times |
| "trie-hard surpasses `std::HashMap` when miss rate gets above 50 %" | samples are generated by replacing words in a 50k-line random-word file at 100/75/50/25/10/5/2/1 % hit rates (`divan_bench.rs`, `generate_samples`) |
| load 15.5k words: TrieHard **11.92 ms** vs radix_trie **3.49 ms** | same corpus |
| header keys are **reversed** (`HEADERS_REV`, `build.rs`) before insertion | i.e. they benchmark `resubmit-nwo-log`-style keys so common *suffixes* share prefixes |

The blog post gives the production conditions, which are the ones that matter
(<https://blog.cloudflare.com/pingora-saving-compute-1-percent-at-a-time/>, 2024-09-10) **[SRC]**:

- Target: `clear_internal_headers` in `pingora-origin`, 35 M requests/s, 40,000 compute-seconds/s.
- The set is **100+ internal header names**; a request carries **10–30** headers and
  "only one or two headers per request on average will be internal", i.e. **>90 % misses**.
- Numbers: original loop 3.65 µs → inverted loop 1.53 µs → trie-hard **0.93 µs**; production stack
  sampling 19/1111 → 9/1103 → 4/1171 samples, i.e. 1.71 % → 0.82 % → **0.34 %** CPU.
- Comparison data points given in the post: `fst` ≈ **50 ns slower** than `HashMap`;
  `radix_trie` ≈ **1 µs slower**; regex ≈ **2× HashMap**.

So the published win is: **119 short keys, >90 % misses, dozens of probes per request** — i.e. the
trie amortises one structure over ~20 probes/request. Our shape is the opposite: a 2.29 M-key
structure probed ~3 times per DNS query.

### 2.3 What it does on our data

I copied `src/lib.rs` + `src/u256.rs` into a probe crate, added a `stats()` accessor exposing
`nodes.len()`, `nodes.capacity() * size_of::<TrieState>()` and `size_of::<TrieState>()`, and built
with `T = u32` (a per-name list id). In our 2.29 M names there are **38 distinct bytes**
(`a-z`, `0-9`, `.`, `-`) → the `u64` mask variant.

| metric | forward trie | reversed trie (suffix sharing) |
|---|---|---|
| names | 2,292,735 | 2,292,735 |
| nodes | **3,888,273** | 3,632,992 |
| nodes per name | 1.696 | 1.585 |
| `size_of::<TrieState<u64, u32>>` | **40 B** | 40 B |
| node bytes used | 155,530,920 B (148.3 MiB) = **67.8 B/name** | 145,319,680 B (138.6 MiB) = 63.4 B/name |
| node bytes with Vec capacity | 167,772,160 B (160.0 MiB) = 73.2 B/name | same capacity |
| build time | 4.22 s | 7.89 s |
| peak RSS (build + keys) | **484,088 KiB = 472.7 MiB** | 476,684 KiB = 465.5 MiB |
| **total incl. 38.45 MB name blob** | **196.7 MiB = 89.95 B/name** | 196.7 MiB |

**[MEASURED]**

Reading of these numbers:

- **40 B/node**, not the 36 B the struct implies: `SearchOrLeaf(&[u8], u32, SearchNode<u64>)` is
  16+4+8+8 = 36 B and Rust still fits it in 40 with the discriminant in padding. **[MEASURED, with
  layout arithmetic as INFERENCE]**
- A hand-packed C# port that drops the leaf slice (a *set* does not need it) and drops `T` would be
  `ulong mask + uint edgeStart + byte tag = 13 → 16 B` padded. 3,888,273 × 16 B = **59.3 MiB** for
  the merged set, 27.1 B/name, with **no name blob at all** (the trie *is* the string set) and
  suffix matching for free. **[INFERENCE]**
- That is genuinely below our 98 MiB — but the walk is ~17 dependent loads per rejected name and
  the node array is 60–155 MB, i.e. permanently outside L3. `trie-hard`'s advantage came from the
  whole trie sitting in L1. At our size we would be trading a hash probe (~2 cache misses) for ~17.
- The build peak is the killer for a 1 GiB device: 473 MiB to build a 197 MiB structure in Rust;
  a C# build over a `SortedDictionary` would be worse.
- The reversed variant saves only 6.6 % of nodes (3.63 M vs 3.89 M) — domain suffix sharing is much
  weaker than header-name sharing, because the label *before* the shared suffix differs.

**Verdict: port the layout, not the structure.** The `popcount(mask & (bit-1))` child index and the
"edges are implicit by contiguity" rule are the transferable ideas; the 2.29 M-node trie is not.
Where it *would* pay: a small (≤ 20 k name) hot-list front end that fits in L2, exactly the niche
`trie-hard` was built for.

---

## 3. `cloudflare/entropy-map` — the MPHF set, read line by line

### 3.1 The index

`src/mphf.rs` (650 lines), following "Fingerprinting-based minimal perfect hashing revisited"
(DOI 10.1145/3596453, cited in the README) with a custom rank structure from
"Engineering Compact Data Structures for Rank and Select Queries on Bit Vectors"
(<https://arxiv.org/pdf/2206.01149.pdf>, cited in `src/rank.rs`).

State, per level, per group:

```rust
pub struct Mphf<const B: usize = 32, const S: usize = 8, ST = u8, H = WyHash> {
    ranked_bits: RankedBits,        // the bit vector + rank index
    level_groups: Box<[u32]>,       // groups per level
    group_seeds: Box<[ST]>,         // one seed per group, u8 by default
}
```

Build (`build_level`, **[SRC]**):

- **Level 0** is sized `level_size = ceil(n * gamma)` bits, `gamma` default **2.0**.
- The level is cut into `groups = adjusted_size / B` groups of `B` bits (B default **32**);
  `adjusted_size` is rounded up to `lcm(B, 64)`.
- For each candidate seed `0 .. 2^S` (S default **8**, so 256 seeds) it sets one bit per key
  (`bit_index_for_seed` = murmur3 finaliser of `(hash ^ seed)` then `fastmod32(x, B)` into the
  group), tracks collisions in a second bit plane, keeps the plane with the most surviving bits,
  and records that seed for the group.
- Keys whose bit survived are removed from the work list (`hashes.retain(...)`); the rest go to the
  next level. Repeat until the work list is empty, max 64 levels.
- Scratch is `3 * segments + 3` u64 words: three bit planes per segment so the "current seed",
  "collision", and "best so far" planes stay in one cache line per group.

Query (`get_impl`, **[SRC]**) — the whole lookup:

```rust
for (level, &groups) in level_groups.iter().enumerate() {
    let level_hash = hash_with_seed(hash_key::<H,_>(key), level);
    let group_idx  = groups_before + fastmod32(level_hash as u32, groups);
    let seed       = group_seeds[group_idx] as u32;
    let bit_idx    = bit_index_for_seed::<B>(level_hash, seed, group_idx);
    if let Some(rank) = ranked_bits.rank(bit_idx) { return Some(rank); }
    groups_before += groups;
}
None
```

`rank()` (`src/rank.rs`, **[SRC]**): `L2_BIT_SIZE = 512`, `L1_BIT_SIZE = 8 * 512 = 4096` bits.
Per 4096-bit L1 block there is one `L12Rank([u8; 16])` holding a 44-bit L1 rank plus eight 12-bit
L2 ranks — **16 B per 512 B of bit vector = 3.125 % overhead**, which is exactly what the crate
doc-comment claims. The rank itself is: test the bit; sum `popcount` over the u64 words of the
current L2 block before the word, plus the masked word.

### 3.2 The set

`src/set.rs` **[SRC]**: `Set<K> { mphf: Mphf<..>, keys: Box<[K]> }`, with `keys` reordered so
`keys[mphf.get(k)] == k`, and

```rust
pub fn contains<Q>(&self, key: &Q) -> bool {
    self.mphf.get(key)
        .map(|idx| unsafe { self.keys.get_unchecked(idx) == key })
        .unwrap_or_default()
}
```

**This is the crucial design point for us**: `Set<String>` stores every string — the MPHF only
replaces the *index*. There is no compression of the payload. You only get a small structure if
`K` is a fixed-width fingerprint.

### 3.3 The bits/key claims and how they are measured

The README's "2.10 to 2.71 bits per key" and "5–20 ns" are measured by
`md.size() as f32 * 8.0 / n` in the unit tests and benchmark (`src/mphf.rs` tests,
`benches/mphf.rs`), i.e. **index bytes only, excluding the keys**, on `n` random `u64`s.
The unit tests hard-code the expected strings, so these are checkable source facts **[SRC]**:

| B | S | n | gamma | bits/key | levels | avg levels per query |
|---|---|---|---|---|---|---|
| 32 | 8 | 10,000 | 1.0 | 2.20 | 7 | 1.63 |
| 32 | 8 | 100,000 | 1.0 | **2.11** | 10 | 1.64 |
| 32 | 8 | 100,000 | 2.0 | 2.73 | 4 | **1.06** |
| 32 | 7 | 10,000 | 1.0 | 2.29 | 7 | 1.70 |
| 32 | 4 | 10,000 | 1.0 | 2.58 | 9 | 1.92 |
| 32 | 0 | 10,000 | 1.0 | 3.65 | 14 | 2.73 |
| 24 | 8 | 10,000 | 1.0 | 2.25 | 6 | 1.57 |

And `benches/mphf.rs` documents, in a comment, the benchmark conditions and results for
**N = 1,000,000 random u64s**: gamma 1.0 → **2.10 bits/key**, construction **1.51 s**,
`get` **14.3 ns**; gamma 2.0 → **2.72 bits/key**, construction **1.19 s**, `get` **4.6 ns**.
`benches/rank.rs` documents rank at N = 1 M: **1.55–1.62 Gelem/s**, construction overhead
**3.16 %**. Note the counter-intuitive trade: *lower* gamma = fewer bits but **more levels and a
3× slower query** — gamma is the knob, and the README's 5–20 ns range is exactly that spread.

### 3.4 Measured on our 2.29 M domains

Counting allocator (`GlobalAlloc` wrapper, exact heap bytes), n = 2,292,735, keys = 64-bit
fingerprint of each name (SipHash-1-3 via `DefaultHasher`):

| structure | bytes | B/key | bits/key | tag |
|---|---|---|---|---|
| `Mphf<32,8>` γ=1.0 | 600,964 | 0.262 | **2.097** | [MEASURED] |
| `Mphf<32,8>` γ=1.5 | 658,092 | 0.287 | 2.296 | [MEASURED] |
| `Mphf<32,8>` γ=2.0 | 778,748 | 0.340 | 2.717 | [MEASURED] |
| `Set<u64>` γ=2.0 (index + 8 B keys) | 19,120,708 | **8.34** | 66.7 | [MEASURED] |
| `HashSet<u64>` (std, SipHash) | 37,748,752 | 16.46 | 131.7 | [MEASURED] |
| MPHF build peak, above the 18.3 MB key vector | +19.8 MiB | +9.06 | — | [MEASURED] |

Construction (single-threaded): γ=1.0 **5.46 s**, γ=1.5 **3.82 s**, γ=2.0 **4.61 s**
(the crate's own 1 M figure is 1.2–1.5 s, so it scales slightly worse than linearly — more levels).

Correctness: `Set<u64>::contains` returned **true for 6,878,205/6,878,205** member probes and
**0 false positives** over 2,292,735 non-member probes. `Mphf::get` alone returns `Some` for
**94.17 %** of non-members at γ=2.0 (99.999 % at γ=1.0) — the index is not a filter, which is why
the set has to store the keys.

**The variant that is actually interesting for us.** Build the MPHF over the 64-bit fingerprints,
then store an *n*-byte fingerprint array indexed by MPHF output instead of the 8-byte key:

| payload | total bytes | B/key | false positives on 2,292,735 non-members |
|---|---|---|---|
| 1-byte fingerprint | 3,071,483 | **1.340** | 8,427 = **0.3676 %** |
| 2-byte fingerprint | 5,364,218 | **2.340** | 40 = **0.0017 %** |

**[MEASURED]** (100 % of member probes still correct.) The 1-byte figure is the predicted
`P(rank hit) / 256 = 0.9417/256 = 0.368 %` **[INFERENCE]**, so the model is understood, not lucky.

Interpretation for a DNS blocker: 0.37 % of *non-blocked names* would be wrongly blocked — that is
~8,400 distinct innocent names at our size, and with ~3 suffix probes per query the per-query rate
is ~1.1 %. Not acceptable. 2 bytes gives 40 names / 0.0017 %, ~0.005 % of queries — defensible only
if the product tolerates a handful of wrong blocks; the full 8-byte key version (8.34 B/key) is
exact modulo 2⁻⁶⁴.

### 3.5 Port-ready? It is closer than the blog-level note concluded, but it loses on build

Comparing at an *achievable* load factor rather than the theoretical 1.0:

| 2.29 M 64-bit fingerprints | bytes/key | probes / loads per query | notes |
|---|---|---|---|
| linear-probe table, 4.19 M slots (α = 0.547) | **14.6** | 1.60 (measured 0.602 extra) | what `mmuniq-hash` gives as-is |
| linear-probe table, `fastmod32`, α = 0.7 | 11.4 | 2.17 | [INFERENCE] arbitrary slot count, no power of two |
| linear-probe table, `fastmod32`, α = 0.9 | 8.9 | 5.5 | [INFERENCE] probe count explodes |
| `Mphf` γ=2.0 + 8 B keys (`Set<u64>`) | **8.34** | 1.06–1.64 level walks | [MEASURED] |
| `Mphf` γ=1.0 + 8 B keys | 8.26 | 1.63 | [MEASURED] |

So the MPHF set really is **~40 % smaller than the table we would actually deploy** (8.34 vs 14.6
B/key), and ~27 % smaller than a `fastmod`-sized table at α = 0.7. That is a real win, and it is
the one place in this audit where Cloudflare code beats the obvious design.

What it costs: an immutable full rebuild (3.8–5.5 s single-threaded here, and the whole fingerprint
list must exist first: build peak +9.06 B/key), no incremental add/remove, and 1.06–1.64 level
walks averaging ~3 dependent loads each (group seed, bit word, rank word) versus ~2 for a probe
**[INFERENCE from `get_impl`]**. A faithful C# port is ~250–300 lines (`fastmod32`, murmur3
finaliser, level loop, a 64-bit-word bit vector with a `ulong[4096/64]` rank index and `byte[]` L2
ranks) — **over the ≤150-line diff budget** in the brief, and it is the only structure in this
report that needs a real port rather than a paste.

Where a C# port *is* worth ~40 lines: the **`fastmod32` trick** (`(uint)(((ulong)x * n) >> 32)`
instead of `%`), which `mphf.rs` cites from Lemire and which applies to any of our bucket
calculations, and the **rank-on-a-bitvector** layout if we ever want a `popcount`-indexed mask.

---

## 4. `pingora`: four crates, and one genuinely useful layout

### 4.1 `pingora-lru` — arena + `u32` indices + single-copy keys

`src/linked_list.rs` (709 lines) **[SRC]**:

```rust
type CompactIndex = u32;
const NULL: CompactIndex = u32::MAX;
const HEAD: CompactIndex = 0;
const TAIL: CompactIndex = 1;
const OFFSET: CompactIndex = 2;

struct Node<K> { prev: CompactIndex, next: CompactIndex, data: K }   // 8 B + K
struct Nodes<K> { head: Node<K>, tail: Node<K>, data_nodes: Vec<Node<K>> }
pub struct LinkedList<K = u64> { nodes: Nodes<K>, free: Vec<CompactIndex> }
```

- **8 bytes of link overhead per node, not 16**, and the whole list is one contiguous `Vec` with
  sentinels at 0/1 so `insert_after`/`unlink` have no special cases.
- Deleted slots are recycled through `free` — the list is sized for its high-water mark and never
  shrinks (`data_nodes.reserve_exact(capacity/10)` beyond 65,536 nodes, i.e. growth is capped at
  10 % slack rather than doubling).
- `src/lib.rs` `LruUnit` = `{ lookup_table: HashMap<u64, Box<LruNode<T>>>, order: LinkedList,
  used_weight: usize }` with `struct LruNode<T> { data: T, list_index: usize, weight: usize }`.
  `async_lru.rs` states the intent: *"Single-copy keys: The real key `K` lives only in the linked
  list arena nodes. The actor maintains a lightweight `u64 → list_index` hashmap … No key
  duplication."* **[SRC]** (Note `list_index` is still `usize` here, not `CompactIndex` — an
  inconsistency in their own code; a port should use `uint`.)

**Transferable:** exactly one copy of every payload, and 32-bit indices for intra-structure links.
For us: our `DomainSet` already keeps one blob, but every offset/ID in the app should be a
**`uint`**, not `long`/`int`-in-an-8-byte-slot. That is the "ketama 8→6 bytes" lesson in a second
place.

### 4.2 `tinyufo` + `pingora-memory-cache` — per-entry overhead, from their own numbers

`tinyufo/src/lib.rs` (790), `buckets.rs` (174), `estimation.rs` (240) **[SRC]**:

```rust
pub struct Bucket<T> { uses: Uses /* AtomicU8 */, queue: Location /* AtomicBool */, weight: u16, data: T }
```

- Key is **`type Key = u64`** — the cache stores the *hash*, never the key ("NOTE: that we
  currently don't store the Actual key in the cache"). **[SRC]**
- Two storage backends: `Fast` = `flurry::HashMap<Key, Bucket<T>>`, `Compact` =
  `Box<[SkipMap<Key, Bucket<T>>]>` sharded at 32 items/shard, chosen by `new_compact()`. **[SRC]**
- Frequency sketch (`estimation.rs`): count-min over `AtomicU8` counters, width `ceil(e/ε)`,
  depth `ceil(ln(1−δ)/ln(1/2))`, with `ε = δ = 1/items` for `optimal()` and `1/(items/100)` for
  `compact()`. Their own test asserts `optimal_paras(1_000_000) == (2718282, 20)` — **2.718 M slots
  × 20 rows of 1-byte counters = 54.4 MB for a 1 M-entry cache, i.e. 54 B/entry of pure sketch**
  **[SRC]**; `compact()` is that with `items/100` ⇒ 62,330 × 15 = 0.93 MB = 0.41 B/entry at our
  n = 2.29 M **[INFERENCE from the source formula]**.
- Their own README memory table (zero-sized assets) **[SRC]**:

| cache size | TinyUFO | TinyUFO compact | `lru` | `moka` |
|---|---|---|---|---|
| 100 | 39,409 B | 19,000 B | 9,408 B | 354,376 B |
| 1,000 | 236,053 B | 86,352 B | 128,512 B | 535,888 B |
| 10,000 | 2,290,635 B | 766,024 B | 1,075,648 B | 2,489,088 B |

  ⇒ at 10 k entries **229 B/entry** (fast) vs **76.6 B/entry** (compact) vs 107.6 B/entry for `lru`
  **[INFERENCE from their table]**. Applying their own formula at `estimated_size = 10,000` gives
  `optimal_paras(10,000) = (27,183 slots, 14 rows) = 380,562 B = 38 B/entry` **[INFERENCE]**, i.e.
  the sketch is only ~17 % of the 229 B — the rest is the `flurry`/`SkipMap` map entry, the
  `Bucket` (8 B of atomics + `u16` weight + alignment), and the two `SegQueue` nodes. That is the
  useful lesson: in a concurrent cache the *container*, not the clever sketch, dominates bytes.
- `pingora-memory-cache` is a thin TTL wrapper and has **no compact structure of its own**:
  `pub struct MemoryCache<K,T> { store: TinyUfo<u64, Node<T>>, _key_type: PhantomData<K>,
  hasher: RandomState }` with `struct Node<T> { value: T, expire_on: Option<Instant> }` and
  `TinyUfo::new(size, size)`. **[SRC]** So every cost in the table above applies unchanged.

**Transferable:** the *shape* of the sketch (fixed byte-per-slot counters, `& mask` instead of
`%`, `min` over rows), not the sizes. For us the sketch idea is only relevant if we wanted a
per-domain request-count in front of the resolver — out of scope.

### 4.3 `pingora-limits` — the smallest count-min in the org

`src/estimator.rs` (154) **[SRC]**:

```rust
pub struct Estimator { estimator: Box<[(Box<[AtomicIsize]>, RandomState)]> }
```

Rows of `AtomicIsize` (8 B/counter), one hasher per row, `min` across rows; `rate.rs` uses
**4 hashes × 1024 slots × 2 slots (red/blue, flipped each interval)** = 65,536 B fixed, with
`HASHES = 4; SLOTS = 1024; // This value can be lower if interval is short (key cardinality is low)`.
`inflight.rs` uses the same 4 × 8192 and documents the trade in the source: *"Time complexity for a
lookup operation is O(h). Space complexity is O(h*n). False positive ratio is 1/(n^h). We choose a
small h and a large n"*. **[SRC]**

**Transferable:** the red/blue double-buffer for interval rollover — the same trick as `mmap-sync`,
used for time instead of versions.

### 4.4 `pingora-cache/src/key.rs` — Cloudflare's own fingerprint width for a key set

```rust
// 16-byte / 128-bit key: large enough to avoid collision
const KEY_SIZE: usize = 16;
pub type HashBinary = [u8; KEY_SIZE];
pub struct CompactCacheKey { pub primary: HashBinary,
                             // save 8 bytes for non-variance but waste 8 bytes for variance
                             pub variance: Option<Box<HashBinary>> }
```

**[SRC]** Two things worth quoting in our proposal: (a) when Cloudflare needed a default fingerprint
width for an unbounded key population they picked **128 bits**, with the reason written in the
comment; (b) they explicitly reasoned about `Option<Box<[u8;16]>>` (24 B) vs a flat 16 B field.
Also `CompactCacheKey` is `Ord`, i.e. it is designed to be sorted and compared, not hashed.

---

## 5. `cloudflare/foundations` — nothing to take, and that is the finding

`foundations/src/lib.rs` declares exactly: `utils`, `addr`, `panic`, `sentry` (deprecated),
`cli`, `settings`, `telemetry`, `security`, `ratelimit`, `derive`,
`reexports_for_macros`. **[SRC]**

`foundations/src/settings/collections.rs` is `pub struct Map<K,V>(IndexMap<K,V>)` — a `Settings`
impl so that generated config files have stable key order — plus `Vec`, `VecDeque`,
`BinaryHeap`, `IndexSet` impls. Not a data structure. **[SRC]**
`pingora-foundations/src/lib.rs` (414 lines) is a `BackgroundService` + telemetry bridge over
`foundations`. **[SRC]**

So: **no compact collection code exists in either crate.** Worth stating in the proposal so nobody
assumes otherwise.

`cloudflare/cardinality-estimator` is the only other "compact structure" repo in the org that I
found (via the 580-repo census, filtered on `trie|hash|bloom|set|map|filter|compact|mem|cache|
bitset|roaring|dict|matcher|radix|cuckoo|mphf`). It has one idea worth 10 lines: the "array"
representation keeps up to **128 exact 32-bit hashes** and tests membership with a **16-wide
vectorised scan** (`contains_vectorized::<16>`, `src/array.rs`) before promoting to a HyperLogLog —
i.e. a 4 B/hash linear scan with SIMD, for small sets. **[SRC]** At 128 max it does not scale to
us, but "small exact set, then probabilistic" is the same staging we already use with the Bloom
front end.

---

## 6. `cloudflare/ahocorasick` — the anti-pattern, quantified

`ahocorasick.go` (332 lines) **[SRC]**:

```go
type node struct {
        root    bool
        b       []byte
        output  bool
        index   int
        counter uint64
        child   [256]*node
        fails   [256]*node
        suffix  *node
        fail    *node
}
```

On amd64 that is `1+24+1+8+8` (≈48 with padding) + `2 × 256 × 8 = 4096` + `2 × 8` ≈ **4,160 B per
node** **[INFERENCE, Go struct layout arithmetic; Go was not installed so I could not print
`unsafe.Sizeof`]**. One node per *character*. For a 2.29 M-name set with mean length 16.8 that is
~38 M nodes → ~150 GB. The README is one line and gives no numbers **[SRC]**.

The useful part: `child`/`fails` are 256-entry *pointer* arrays, and the file's own comment
concedes the trade ("The use of fixed size arrays is space-inefficient but fast for lookups").
This is the exact structure `trie-hard` replaces with one `popcount` — and the reason `trie-hard`
exists. Cite it as the "before" picture, not as a candidate.

---

## 7. `cloudflare/wirefilter` — `RangeSet` and the `ListMatcher` trait

`engine/src/range_set.rs` (57 lines) **[SRC]**, in full:

```rust
pub struct RangeSet<T> { ranges: Box<[RangeInclusive<T>]> }
// From<Vec<RangeInclusive<T>>>: sort_unstable_by_key(start), then dedup_by merging
// overlapping/adjacent-by-containment ranges
pub fn contains<Q>(&self, value: &Q) -> bool where T: Borrow<Q>, Q: ?Sized + Ord {
    self.ranges.binary_search_by(|range| {
        if range.start().borrow() > value { Ordering::Greater }
        else if range.end().borrow() >= value { Ordering::Equal }
        else { Ordering::Less }
    }).is_ok()
}
```

| property | value |
|---|---|
| bytes per range | `2 × size_of::<T>()` = **8 B** for `u32` (IP ranges) |
| sorted + merged at build | yes, `sort_unstable` + `dedup_by` |
| query | `binary_search_by` over the range array, O(log #ranges), no allocation |

**Transferable, and cheap:** the `binary_search_by` predicate that turns "is v inside any range"
into one comparison sequence, and `dedup_by` with a mutating closure to merge at build. For us the
direct analogue is our sorted-blob binary search; the range form only helps if we were to encode a
domain interval — which we cannot (names are not dense in integer order).

`engine/src/list_matcher.rs` (160 lines) is a **trait**, `ListMatcher`, plus `AlwaysListMatcher` /
`NeverListMatcher`; the concrete list storage is supplied by the embedder through
`ListDefinition::deserialize_matcher`. **[SRC]** There is **no shipped hash-set list
implementation** in the repo — a grep for `HashSet|BTreeSet|ahash` across `engine/src` returns only
`ExpectedTypeList(BTreeSet<ExpectedType>)` (a type-set in `types.rs`) and a test-local
`BTreeSet<Box<[u8]>>` in `ast/field_expr.rs`. So wirefilter gives us the *interface* idea (lists are
pluggable, serialised through a trait) and one 8 B/entry sorted-array structure, nothing about
string sets.

---

## 8. `cloudflare/mmap-sync` — the reload/peak-memory answer

`src/state.rs` **[SRC]**:

```rust
const STATE_SIZE: usize = mem::size_of::<State>();
#[repr(C)]
pub(crate) struct State<const SD: usize = 1_000_000_000> {
    version: AtomicU64,              // the published 64-bit version word
    idx_readers: [AtomicU32; 2],     // readers currently in instance 0 and 1
}
```

`src/instance.rs` **[SRC]** — the version word is bit-packed, and *this* is the trick:

| bits | meaning |
|---|---|
| 0 | instance index (0 or 1) → file `_data_0` / `_data_1` |
| 1..40 | data size (39 bits, `< 549 GB`) |
| 40..64 | checksum (24 bits) |

i.e. one `u64` identifies the live snapshot completely, so publication is a single atomic store.
`src/data.rs` keeps `read_mmaps: [Option<Mmap>; 2]` / `write_mmaps: [Option<MmapMut>; 2]` and only
remaps when the requested size exceeds the current mapping. Writer path (`synchronizer.rs`):
serialise → checksum → `acquire_next_idx` (waits for readers of the *other* slot to drain, with a
**grace period** after which the reader count is force-reset, because a reader may have crashed) →
write into the other file → `state.switch_version(new_version)`. Reader path: load version →
`rlock` (increment the reader count for that index) → read the mapped bytes → `ReadGuard::drop`
decrements. **[SRC]** The module doc names the technique: "inspired by the Left-Right concurrency
control technique" (paper linked in the file).

**Transferable to us with almost no code**: the reload peak. Today a reload needs ~2× because the
new `DomainSet` and the old one are both live in the managed heap. Instead: build the new structure
into a second file (or a second `MemoryMappedFile` section), publish a single `long` that encodes
`{generation:1, length:39, checksum:24}`, and have readers `Volatile.Read` that long, take a
reader-count increment, re-check the long, and only then `AcquirePointer`. That is ~60 lines in C#
and it simultaneously solves (a) 2× reload peak, (b) anonymous RSS → reclaimable page cache,
(c) torn reads on a 1 GiB device.

**Caveat, from the source:** their reader protocol relies on readers staying *inside* the mapping
for less than `grace_duration`, because the writer will reset a stuck reader count and then
overwrite that file. In C# the same holds — you must copy any pointer you keep past the guard, and
the grace period must exceed your worst-case query time by a lot. **[SRC + INFERENCE]**

---

## 9. Master table: bytes per entry, all traceable

| Structure / repo | unit | bytes/entry (or per node) | load factor / resizing | source of number |
|---|---|---|---|---|
| `mmuniq-hash.c` table | slot (8 B) | **8 B/slot**, 14.6 B/name at power-of-two sizing | none; user sizes via `-n` | [SRC] + [MEASURED] |
| `mmuniq.c` table | slot | 8 B/slot | **0.6**, double + reinsert | [SRC] |
| `trie-hard` `TrieState<u64,u32>` | node | **40 B**, 1.696 nodes/name = **67.8 B/name** | n/a (bulk build, BFS) | [MEASURED] |
| `trie-hard` + name blob | per name | **89.95 B/name** (197 MiB total) | n/a | [MEASURED] |
| `entropy-map` `Mphf` γ=1.0/2.0 | key | **0.262 / 0.340 B** (2.10 / 2.72 bits) | n/a, immutable | [MEASURED] |
| `entropy-map` `Set<u64>` | key | **8.34 B** | n/a | [MEASURED] |
| MPHF + 1-byte fp | key | **1.340 B**, 0.368 % FP | n/a | [MEASURED] |
| MPHF + 2-byte fp | key | **2.340 B**, 0.0017 % FP | n/a | [MEASURED] |
| `std HashSet<u64>` (Rust) | key | 16.46 B | 87.5 % (hashbrown) | [MEASURED] |
| `pingora-lru` linked list | node | **8 B** links + payload | preallocated, free-list | [SRC] |
| `pingora-lru` lookup table | entry | 8 B hash + 8 B `Box` ptr (+ header) | hashbrown | [SRC] |
| TinyUFO (fast) | entry | **229 B** at 10 k | flurry map + sketch | [SRC] (their README table) |
| TinyUFO (compact) | entry | **76.6 B** at 10 k | sharded `SkipMap`, 32/shard | [SRC] |
| TinyUFO count-min (optimal, n=1 M) | entry | **54 B** (`2718282 × 20 × 1 B`) | none | [SRC] (their test asserts the numbers) |
| `pingora-limits::Rate` | whole structure | 65,536 B fixed (2 × 4 × 1024 × 8 B) | none | [SRC] |
| `wirefilter::RangeSet<u32>` | range | **8 B** | none, merged at build | [SRC] |
| `ahocorasick` node | node (= 1 char) | **≈4,160 B** (two `[256]*node`) | none | [SRC] + [INFERENCE] |
| `mmap-sync::State` | per shard | **16 B** (u64 + 2×u32) | n/a | [SRC] |
| `cardinality-estimator` array repr | item | **4 B** (u32 hash), ≤128 items | doubles to cap | [SRC] |

For scale, our current position (from `docs/analysis.md`, as quoted in the brief): exact
`DomainSet` **98 MiB anon** for 2.46 M entries ≈ 44.8 B/entry; theoretical floor ≈ 57.8 MiB.

---

## 10. Talks, slides and videos: what I could actually open

I looked for conference material by Cloudflare engineers on these structures. Result: **nothing
openable, and I am not going to quote a talk I did not read.**

| venue / channel | what I did | result |
|---|---|---|
| RustConf 2026 speaker list, <https://rustconf.com/speakers/> | fetched the full page (902 lines) | **no Cloudflare speaker at all**, and no hash/data-structure talk; grep for `Cloudflare|hash|data structure` over the fetched text: 0 matches |
| RustConf 2022 speakers, <https://2022.rustconf.com/speakers> | search result excerpt only | no Cloudflare entry seen in the excerpt (**UNVERIFIED** for the rest of the page) |
| P99 CONF agenda + on-demand index, <https://p99conf.io/agenda/>, <https://p99conf.io/on-demand> | searched `site:p99conf.io cloudflare pingora OR tinyufo OR "1.1.1.1"` | no Cloudflare session found; the icons of the conference (Bun, Turso, ScyllaDB, io_uring) are unrelated. The one Pingora-adjacent item is **Amos Wenger's** "Rust + io_uring + ktls" (`p99conf.io/session/rust-io_uring-ktls-how-fast-can-we-make-http`), which is not Cloudflare and not about sets |
| USENIX (ATC/NSDI/Security) | `site:usenix.org Cloudflare Quicksilver OR Pingora OR "DNS"` | hits are all third-party DNS-security papers that merely *mention* Cloudflare; **no Cloudflare paper on set/table internals** |
| Cloudflare TV "Quicksilver: Configuration Distribution at Internet Scale" | search returned event URLs; the canonical `/event/quicksilver-…/` path **404s**, and every hit is a Filipino/Tagalog re-record (`/event/filipino-tagalog-quicksilver-…/<id>`) | **could not open a transcript or slides** |
| "Rust in Production" podcast S05E03, Cloudflare (Edward Wang & Kevin Guthrie), <https://corrode.dev/podcast/s05e03-cloudflare/> | fetched the episode page (2025-10-30) | page has **show notes only, no transcript**; the notes link one third-party video, *"ThePrimeTime: Cloudflare – Trie Hard – Big Savings On Cloud"* (`youtube.com/watch?v=xV4rLfpidIk`) — a YouTuber's reaction, **not** a Cloudflare talk, and I did not open its transcript |
| Cloudflare blog posts that *are* the talk | fetched the trie-hard post in full (quoted in §2.2) | it is the only first-party engineering narrative on these structures that I opened; the 2026 DNS-cache post is covered in `docs/research-cloudflare.md`, not re-read here |

**Conclusion for the proposal:** do not cite a Cloudflare conference talk about hash tables —
there is not one I can verify. Cite the blog post (`pingora-saving-compute-1-percent-at-a-time`)
for trie-hard's numbers and conditions, and the *code* (everything in §1–§8) for the layouts. If a
talk citation is required later, the candidate to chase is the Cloudflare TV Quicksilver session —
but every URL I found 404s or is a Tagalog re-record, so it is **UNVERIFIED** that an English
recording with slides exists.

---

## 11. What transfers: ranked, with the smallest C# form

Judged against the brief: well below 98 MiB for 2.46 M entries, lookup near `HashSet`, one-pass
build with low peak, plain C# (no NuGet), small diff, exact where possible.

### T1. `mmuniq-hash`'s table, kept per list — the core recommendation

**Why:** it is Cloudflare's own answer to "deduplicate a large set of lines with the least memory",
it is 8 B/slot with no separate key, and I measured 35.5 MiB RSS for our merged 2.29 M names. The
`DomainSet` we have is 98 MiB because it stores the name blob; a hash-only set stores 8 B/slot and
nothing else.

**Smallest form:** §1.4 (≈35 lines). Per list you keep one `ulong[]`; a hit in list *i* is the
attribution. Sized to α ≤ 0.5, the 23 real lists need **43.6 MiB of slots** in total (5.72 M slots
for 2.67 M per-list entries) **[INFERENCE from the real counts]**, versus 98 MiB today; the merged
alternative is 48 MiB, so per-list is both smaller and simpler (§1.3).

**What you give up:** exact spelling. `a.b.example.net` and `A.B.Example.NET` map to the same entry
only if you lowercase before hashing (do), and you can no longer answer "is this exact string in the
list" differently from "is this name in the list". For **prefix/suffix** matching you generate the
label suffixes and hash each — the cost is 3–4 hashes per query instead of 1. If you need the
matched *name* for logging, keep a parallel sorted blob of the matched names only (or accept
"blocked by list X").

**Two things not to copy:** the `0`-is-empty sentinel (map `h==0 → 1`, and if you ever store a
suffix mask, store it in a parallel array so the sentinel never collides with data), and the
4096-probe "give up and call it a duplicate" (throw instead — a block list must never silently
drop a rule).

### T2. `mmap-sync`'s version word — for the reload peak, ~60 lines

`long version = (idx & 1) | ((long)len << 1) | (checksum << 40)`; readers publish into
`idx_readers[idx]`, writer waits for the other slot to drain, then flips. Two `MemoryMappedFile`
sections instead of two managed heaps. Directly attacks the "reload needs ~2×" constraint, which is
the binding one on a 1 GiB box: 2 × 22 MiB of page-cache-mapped slots is nothing, whereas
2 × 98 MiB of managed heap is fatal. [SRC §8]

### T3. `pingora-lru`'s layout discipline — free

One copy of every payload; `uint` for every intra-structure index; sentinel slots at fixed indices;
free-list recycling; growth capped at +10 % instead of doubling. Applied to the list-metadata tables
around the sets, not to the sets themselves. [SRC §4.1]

### T4. `fastmod32` and the count-min shape — micro

`(uint)(((ulong)x * n) >> 32)` instead of `%` in any bucket computation (Lemire, cited by
`mphf.rs`); if we ever add a per-domain counter, use `pingora-limits`' layout (fixed 1-byte slots,
`& mask`, `min` across 4 rows, red/blue interval flip, 65,536 B total). [SRC §3.1, §4.3]

### T5. `entropy-map`'s MPHF — the last 20 MiB, if we will pay ~300 lines

8.34 B/key exact versus **14.6 B/key** for the probe table we would actually deploy (α = 0.547), and
versus 11.4 B/key for a `fastmod`-sized table at α = 0.7. Kept per list it is
**8.34 B × 2.67 M per-list entries = 21.3 MiB** against 43.6 MiB for per-list probe tables
**[INFERENCE]** — the best exact number in this audit. The price: 3.8–5.5 s single-threaded build
per 2.29 M keys (≈ 60 s for 23 lists, sequential, ~9 B/key of build peak), no incremental update,
and a 250–300-line port. **Do T1 first**; take T5 only if the memory budget refuses 43.6 MiB.
The 1-byte-fingerprint variant (1.34 B/key, 0.368 % FP) is the quantified-FP datapoint to quote if a
reviewer asks how small a *lossy* set could be — it is not shippable at 8,400 wrongly blocked names.
[SRC §3, MEASURED §3.4–3.5]

### T6. `trie-hard` — do not port at this size; keep it for hot lists

40 B/node measured, 1.696 nodes/name, 197 MiB total, 473 MiB build peak. Its published win is a
119-key map with >90 % miss rate. If we ever want a "top 10 k blocked domains" front end, the
`popcount(mask & (bit−1))` child index + implicit edges is the cheapest correct way to build it
(16 B/node in C#). [SRC §2, MEASURED §2.3]

### T7. Correction to the blog-level note's R2 ("one shared blob + per-domain list mask")

At equal load factor, **merging the hash slots is a win** (32.0 MiB merged at α = 0.547 versus
43.6 MiB for 23 per-list tables at α ≤ 0.5), but the per-name `uint` list mask that merging forces
costs another 16 MiB, so merged + mask = **48 MiB against 43.6 MiB** for per-list tables that carry
attribution implicitly. And only **6.2 MiB** of the 42.9 MiB of per-list name bytes are actually
duplicated across the 23 lists, because one list holds 2.07 M of the 2.29 M unique names.
**So "one shared set + mask" is not the structural win it looked like** — the win is switching from
storing names to storing 8-byte hashes at all (§1). Merging is still right if we want a single
immutable artifact to publish through `mmap-sync` (T2), which is a different argument.
**[INFERENCE, from the real per-list counts]**

---

## 12. What I could not verify

1. **No Cloudflare conference talk, slide deck or video transcript on hash/trie/MPHF internals
   exists that I could open.** §10 lists every search and every page fetched. In particular I could
   not open any YouTube transcript at all (no text-fetchable transcript source), so nothing in this
   report quotes a spoken talk.
2. **`mmuniq`'s per-line conflict count of 0.602** is measured by *their* counter, which increments
   once per occupied non-matching slot — I read that from the code, but I did not verify the
   counter's arithmetic against an independent probe-count trace.
3. **The 4096-probe behaviour under adversarial input** (e.g. many domains sharing a long common
   suffix) is not tested here; with SipHash the hashes are uniform, but if we hash *suffixes* of the
   same name, the probe sequences are independent only if the hash is good. UNVERIFIED for our
   suffix-generation scheme.
4. **`entropy-map`'s construction at 2.29 M** took 3.8–5.5 s here, but this box was running other
   benchmark agents concurrently; the *memory* numbers are exact (counting allocator), the *time*
   numbers are upper bounds. Its README's "5–20 ns" query claim measured 43–124 ns here, consistent
   with a loaded machine, so I report the relative order (MPHF ≪ `HashSet`) and not the absolutes.
5. **`trie-hard`'s node size of 40 B** is measured via `size_of::<TrieState<u64,u32>>()`; I did not
   verify how it would lay out with `T = ()` (a pure set), and I did not build the C#-equivalent
   16 B/node version, so the "59.3 MiB for the merged set" figure in §2.3 is arithmetic, not a
   measurement.
6. **`ahocorasick`'s ≈4,160 B/node** is Go struct-layout arithmetic; Go is not installed here, so
   `unsafe.Sizeof` was not run.
7. **`cloudflare/trie-hard`'s "119 entries"** is the README's number; `data/headers.txt` has 118
   unique lines by my count (`wc`-equivalent in Python over the file), a 1-entry discrepancy I did
   not chase.
8. **`wirefilter`'s production list storage** (what Cloudflare actually plugs into `ListMatcher`
   for their WAF lists) is not in the public repo; UNVERIFIED.
9. **`mmuniq.c`'s resize loop** iterates `j < global_size_mask`, not `<=`, so it skips the last slot
   when reinserting; I did not test whether that can lose an entry in practice, and I did not port
   the resize path.

---

## 13. Reproduction

```bash
# input corpus (read-only; derived from the lab lists)
cd lab/lists
python3 - <<'PY' > /tmp/CloudflareSourceAndTalks/domains.txt
import glob, re
host = re.compile(r'^(?=.{1,253}$)(?:[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z]{2,63}$')
out = set()
for f in sorted(glob.glob('*')):
    for line in open(f, errors='replace'):
        s = line.strip()
        if not s or s[0] in '#![':            # comment / adblock header
            continue
        p = s.split()
        if len(p) >= 2 and p[0] in ('0.0.0.0', '127.0.0.1'):
            s = p[1]                          # hosts-file form
        s = s.split('#')[0].strip().lstrip('|').lstrip('*').lstrip('.')
        s = re.split(r'[\^/$|]', s)[0].strip().lower()
        if host.match(s):
            out.add(s)
print('\n'.join(sorted(out)))
PY
#   -> 2,292,735 names, 38,453,838 bytes, mean 16.77 B  (2,151 lines dropped as non-hostname)

# 1) Cloudflare's own dedup tool, unmodified
cd /tmp/CloudflareSourceAndTalks/cloudflare-blog/2020-02-mmuniq
gcc -O2 -o /tmp/CloudflareSourceAndTalks/mmuniq-hash mmuniq-hash.c -lm
/usr/bin/time -f "wall=%e maxrss=%M" \
  /tmp/CloudflareSourceAndTalks/mmuniq-hash -n 2292735 \
  < /tmp/CloudflareSourceAndTalks/domains.txt > /dev/null
# -> wall=0.57 maxrss=36324, "Hash conflicts 0.602 per line"

# 2) trie-hard node accounting (patched copy exposing nodes.len()/capacity/size_of)
cd /tmp/CloudflareSourceAndTalks/trie-measure      # lib.rs + u256.rs copied from ../trie-hard/src,
                                                   # plus one added `pub fn stats()`; no other change
cargo build --release
/usr/bin/time -v ./target/release/probe ../domains.txt      # forward
/usr/bin/time -v ./target/release/probe ../domains.txt rev  # reversed keys

# 3) entropy-map: MPHF, Set<u64>, fingerprints (counting GlobalAlloc for exact heap bytes)
cd /tmp/CloudflareSourceAndTalks/entropy-probe
cargo build --release --bin probe && ./target/release/probe ../domains.txt
cargo build --release --bin fp    && ./target/release/fp    ../domains.txt
```

Nothing was written outside `/tmp/CloudflareSourceAndTalks/` and this file. No ports were bound, no
service was started, and the repository was only read.
