# Exact, memory-efficient domain sets: what the literature and real blockers use

Scope: is there a better **exact** structure than the current `DomainSet` (UTF-8 bytes in one
buffer, sorted `int[]` offsets, binary search, per-list Bloom front) for millions of DNS block-list
domains with suffix lookup, per-list attribution, one-pass build and no new NuGet dependency?
Everything below is either a primary source (URL given) or a measurement made for this note; the
latter is labelled *measured here*. Anything I could not verify is labelled UNVERIFIED.

## 0. Baseline and units

The comparison point is `results/structure-bench-20261102.txt`: 21 block lists plus 2 allow lists,
2,454,497 parsed per-list entries, per-list `DomainSet` + Bloom, GC heap after a full collection
**57.8 MiB = 24.7 B/entry**, exact, and +1.6 % p50 against `HashSet<string>` in the same harness.
That 24.7 B is roughly 17–18 B of text (length byte + characters), 4 B of offsets and ~1.7 B of
Bloom (10 bits/entry requested, rounded up to a power of two), plus per-list array slack; the
app-level steady `anon` (89.4 MiB) and reload peak (229.3 MiB) are in `docs/analysis.md` and are a
different measurement.

The lists are in `lab/lists/` (23 files, 54 MiB). For the structure measurements below I extracted
domains with a local parser (hosts / plain / `||domain^` forms, per-list dedup) and got
**2,672,240 per-list keys, 2,292,939 unique, average 16.84 characters**. That is 8.9 % more keys than
the app's parser produced, so absolute MiB here are slightly pessimistic; **bytes per key** is the
comparable unit. FST and marisa runs use the same extracted files.

## 1. What real DNS blockers and resolvers actually do

| System | Structure (verified in source/docs) | Exact | Per-domain cost | Notes |
|---|---|---|---|---|
| Pi-hole FTL | SQLite `gravity(domain, adlist_id)` table, queried per name through `vw_gravity` with a prepared statement; `PRAGMA mmap_size = 268435456`; uniqueness on `(domain, adlist_id)` | yes | no in-memory set; SQLite B-tree pages | Not a compact in-memory structure at all. [gravity-db.c](https://raw.githubusercontent.com/pi-hole/FTL/master/src/database/gravity-db.c), [schema](https://raw.githubusercontent.com/pi-hole/pi-hole/master/advanced/Templates/gravity.db.sql), [docs](https://docs.pi-hole.net/database/domain-database/) |
| AdGuard Home / `urlfilter` | Go `map[string][]StorageID` for hosts rules; 5-byte-gram `ShortcutIndex` (`map[shortcut][]StorageID`) for `||domain^` rules; `DomainIndex` map for `$domain` rules; `bytesPerRuleEst = 64` | yes (rule match is evaluated) | ~64 B/rule *estimate in the source*, plus Go map overhead | No domain trie. [dnsengine.go](https://raw.githubusercontent.com/AdguardTeam/urlfilter/master/dnsengine.go), [shortcut.go](https://raw.githubusercontent.com/AdguardTeam/urlfilter/master/internal/lookup/shortcut.go), [domain.go](https://raw.githubusercontent.com/AdguardTeam/urlfilter/master/internal/lookup/domain.go) |
| Blocky | sorted `[]uint64` of 64-bit hashes + top-bit bucket index (`hashSetKeysPerBucket = 4`); wildcard cache hashes the reversed suffix and probes every label boundary | no (64-bit hashes) | 8 B hash + ~1 B index ≈ 9 B/entry | Closest real-world analogue of our hash variant, with a cheaper index. [hash_set.go](https://raw.githubusercontent.com/0xERR0R/blocky/main/cache/stringcache/hash_set.go), [wildcard_cache.go](https://raw.githubusercontent.com/0xERR0R/blocky/main/cache/stringcache/wildcard_cache.go) |
| Unbound | `rbtree` of `struct local_zone`; each zone has a name, a lock, a `region`, a per-zone `local_data` rbtree and parent pointers; RPZ QNAME triggers become local zones. `local_zones_get_mem()` = `sizeof(*z) + namelen + regional_get_mem()` | yes | no published B/domain; the struct alone is >180 B by field layout (3-pointer rbnode, rwlock, region, rbtree, …), before the name and region | Suffix matching is `local_zones_find_le` on the rbtree. [localzone.h](https://raw.githubusercontent.com/NLnetLabs/unbound/master/services/localzone.h), [rpz.c](https://raw.githubusercontent.com/NLnetLabs/unbound/master/services/rpz.c) |
| dnsmasq | hosts entries become `struct crec` in the DNS cache (3 pointers, `all_addr`, `time_t`, flags, 50-byte inline name: **≈112 B by field layout**); `--address=/domain/` servers are a **sorted `struct server*` array** searched by binary search, one `struct server` (~100+ B) plus the domain string per entry | yes | ~112 B per hosts entry; ~100+ B per `server` entry | Suffix walk is explicit in `lookup_domain`. [dnsmasq.h](https://raw.githubusercontent.com/imp/dnsmasq/master/src/dnsmasq.h), [domain-match.c](https://raw.githubusercontent.com/imp/dnsmasq/master/src/domain-match.c) |
| CoreDNS | no blocklist plugin in the tree; `hosts` uses `map[string][]net.IP`; `file` uses a left-leaning red-black tree of `Elem` per name | yes | no published figure; map/tree node + name | [hostsfile.go](https://raw.githubusercontent.com/coredns/coredns/master/plugin/hosts/hostsfile.go), [tree.go](https://raw.githubusercontent.com/coredns/coredns/master/plugin/file/tree/tree.go) |
| Knot Resolver | `policy.suffix` builds an **Aho–Corasick** automaton over wire-format names; `policy.suffix_common` is a linear scan with a common-suffix pre-check, documented as faster for tables “in the order of hundreds”; `policy.rpz` builds these rules | yes | no published B/domain; AC states are proportional to total pattern bytes times the per-state transition cost | The C AC implementation is a separate submodule (`lua-aho-corasick`). [policy.lua](https://raw.githubusercontent.com/CZ-NIC/knot-resolver/master/modules/policy/policy.lua), [README](https://raw.githubusercontent.com/CZ-NIC/knot-resolver/master/modules/policy/README.rst), [trie.h](https://raw.githubusercontent.com/CZ-NIC/knot-resolver/master/lib/generic/trie.h) |
| BIND RPZ | per policy zone an `isc_ht_t` hash table keyed by the raw wire-format name; each node carries an `nmdata_t` with several trigger bitmaps and a `dns_name_t`; IP triggers use a radix/`dns_rpz_cidr_node` tree | yes | no published B/domain; hash entry + name copy + `nmdata_t` | ARM claims lookup “proportional to the logarithm of the number of rules in the largest single policy zone”, while the source uses a hash table; do not reconcile the two. [rpz.h](https://raw.githubusercontent.com/isc-projects/bind9/main/lib/dns/include/dns/rpz.h), [rpz.c](https://raw.githubusercontent.com/isc-projects/bind9/main/lib/dns/rpz.c), [ARM](https://raw.githubusercontent.com/isc-projects/bind9/main/doc/arm/rpz.inc.rst) |
| PowerDNS recursor RPZ | `std::unordered_map<DNSName, Policy>` per trigger type (`d_qpolName`, `d_propolName`), `NetmaskTree<Policy>` for IP triggers; `Policy` holds a `shared_ptr<PolicyZoneData>` and optional custom records | yes | no published figure; hash node + `DNSName` + `Policy` (~40 B plus name) | [filterpo.hh](https://raw.githubusercontent.com/PowerDNS/pdns/master/pdns/recursordist/filterpo.hh), [rpzloader.cc](https://raw.githubusercontent.com/PowerDNS/pdns/master/pdns/recursordist/rpzloader.cc) |
| dnsdist | `SuffixMatchNode` is a `SuffixMatchTree<bool>` **label trie** plus a `std::unordered_set<DNSName>` of the same names for iteration/printing (duplicate storage) | yes | no published figure | [dnsname.hh](https://raw.githubusercontent.com/PowerDNS/pdns/master/pdns/dnsname.hh) |
| NextDNS | closed source; public material only claims “millions of domains” and nanosecond-scale analysis | UNVERIFIED | UNVERIFIED | No data structure or memory figure is published. |
| Technitium | Advanced Blocking: one `HashSet<string>` per list (and per allow/block set in ad-block lists); built-in block list zone: one merged `Dictionary<string, List<Uri>>` plus an allow `Dictionary<string, object>` | yes | 80 B/entry (HashSet, measured here); 145 B/entry / 339.4 MiB (merged dictionary, measured here) | [App.cs](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/0dd592a/Apps/AdvancedBlockingApp/App.cs), [BlockListZoneManager.cs](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/0dd592a/DnsServerCore/Dns/ZoneManagers/BlockListZoneManager.cs) |
| uBlock Origin | `HNTrieContainer`: hostnames stored **reversed by label** in a typed-array trie; each node is 3 × `uint32` (sibling, child, segment+flags); 12 B/node plus the label characters in a char buffer; no presorting needed | yes | ~24 B/key for a flat 2 M-domain list by my node count (12 B × 2.1 M nodes + 25 MB label bytes); measured here by counting the distinct suffixes | Built for incremental add and suffix match, not for minimal space. [hntrie.js](https://raw.githubusercontent.com/gorhill/uBlock/master/src/js/hntrie.js) |
| Chrome Safe Browsing | sorted hash prefixes, **one memory-mapped file per prefix size**; 4-byte SHA-256 prefixes in v4, 16-byte prefixes for the extension blocklist in v5; a prefix hit is confirmed with a full hash (server-side in v4) | no (prefix) + full-hash confirmation | 4 B/prefix before Rice compression; full 32 B only in the confirm store | `kMaxStoreSizeBytes = 50 MB`, comment says real stores are ~6 MB. [HashPrefixMap](https://raw.githubusercontent.com/chromium/chromium/main/components/safe_browsing/core/browser/db/hash_prefix_map.h), [v4_store.cc](https://raw.githubusercontent.com/chromium/chromium/main/components/safe_browsing/core/browser/db/v4_store.cc), [Update API](https://developers.google.com/safe-browsing/v4/update-api) |
| Firefox URL classifier | `nsUrlClassifierPrefixSet`: sorted 32-bit prefixes, full prefix every `DELTAS_LIMIT + 1 = 121` entries and `uint16` deltas between (`MAX_INDEX_DIFF = 65536`); lookup is binary search over the index plus a ≤120-delta scan | no (32-bit prefix) + full-hash completion | ≈ 4/121 + 2·120/121 ≈ **2.02 B/prefix** plus the index array; `.vlpset` stores variable-length prefixes as sorted strings | [nsUrlClassifierPrefixSet.h](https://raw.githubusercontent.com/mozilla-firefox/firefox/main/toolkit/components/url-classifier/nsUrlClassifierPrefixSet.h), [.cpp](https://raw.githubusercontent.com/mozilla-firefox/firefox/main/toolkit/components/url-classifier/nsUrlClassifierPrefixSet.cpp), [VariableLengthPrefixSet.cpp](https://raw.githubusercontent.com/mozilla-firefox/firefox/main/toolkit/components/url-classifier/VariableLengthPrefixSet.cpp) |
| Brave `adblock-rust` | rules are built into a FlatBuffer blob; network rules are indexed by token; `serialize()` exposes the blob for fast reload | yes (rule evaluation) | no published B/domain; per-rule cost, full adblock syntax | Not a domain-set structure. [engine.rs](https://raw.githubusercontent.com/brave/adblock-rust/master/src/engine.rs) |

Two patterns stand out. First, **no mainstream DNS blocker uses a compact exact domain set**. They
use SQLite (Pi-hole), per-domain objects with hash/rbtree/trie nodes (Unbound, BIND, PowerDNS,
dnsmasq, CoreDNS, Knot), Go maps (AdGuard), or hashes (Blocky). Per-domain overhead in those designs
is tens to hundreds of bytes. Second, **the only real-world structures near our budget are hash
prefix arrays** (Chrome 4 B, Firefox ~2 B), and both are probabilistic and confirmed elsewhere; they
are not exact domain sets.

Technitium itself is the outlier in the wrong direction: 80 B/entry for `HashSet<string>`, 145 B/entry
for the merged `Dictionary<string, List<Uri>>`, against 24.7 B/entry for the current `DomainSet`.
The compact structure is already better than every mainstream implementation above for which a
per-domain cost is published or can be bounded from its field layout; the BIND, Unbound, PowerDNS
and Knot bounds are inferences from struct fields, not measurements.

## 2. Succinct and compressed exact structures

### 2.1 FST / DAWG (the `fst` crate and Lucene)

A minimal acyclic deterministic finite-state acceptor stores a set of strings as a byte-level DAG:
common prefixes *and suffixes* are shared, and lookup is O(length) with no hashing.
Andrew Gallant's article documents the construction (Daciuk's incremental algorithm with a bounded
hash-table of frozen states), the fact that construction can be streamed from sorted keys in
constant memory, and real sizes: 15.8 M Wikipedia titles (384 MB) → 157 MB FST (9.95 B/key);
49.1 M DOI URLs (2.8 GB) → 113 MB (2.3 B/key); 1.65 B Common Crawl URLs (134 GB) → 27 GB (17.5 B/key)
([article](https://burntsushi.net/transducers/)). Lucene's FST, built with the same incremental
algorithm, holds 9.8 M Wikipedia terms in 69 MB (7.0 B/key) with <256 MB heap
([McCandless](https://blog.mikemccandless.com/2010/12/using-finite-state-transducers-in.html)).

*Measured here* (Rust `fst` 0.4.7, `SetBuilder` over UTF-8 keys, `Set::as_fst().size()`):

| Keys | FST bytes | Bytes/key | Build |
|---|---|---|---|
| Big list, 2,065,646 keys, forward | 17,675,988 | 8.56 | 31 MB peak RSS, ~2.5 s |
| Big list, 2,065,646 keys, reversed | 16,571,961 | **8.02** | ~2 s |
| All 23 lists, 2,672,240 keys, forward | 24,605,052 | 9.21 | **33 MB peak RSS, 3.2 s** |
| All 23 lists, keys reversed | 23,371,838 | 8.75 | 2.7 s |
| Union, 2,292,939 unique keys | 20,134,777 | 8.78 | 2.6 s |

The reversed-key variant is 5–6 % smaller because it shares top-level-domain prefixes (`.com` is a
prefix of the reversed string) and, with a reader that checks the final flag at every label boundary,
lets one walk answer all suffix queries instead of one walk per suffix. The crate's plain
`contains()` does one full-key walk, so the single-walk behaviour is a property of the reader a C#
port would write, not of `contains()`. Lookup on the big list (200 k queries, in-process, single
thread): **264 ns per miss, 808 ns per hit** for one `contains`; a full suffix walk is
**488 ns miss / 777 ns hit**. On 23 lists the worst-case miss path is therefore ~11 µs per query if
every list is walked.

Exactness: exact. Build peak: the Rust builder streams and keeps a bounded registry, so the peak is
the output plus a few MB; in C# the parser's byte buffer (~37 MB big list) and `int[]` offsets
(~8 MB) must exist anyway, so the realistic peak is buffer + offsets + FST ≈ 63 MB, and the reload
peak is old FST + new build ≈ 80 MB. C# size: a simple arena (1-byte node header, label byte,
3- or 4-byte target) is ~300 lines and lands at **10–12 B/key**; the crate's 8.0–8.75 B/key comes
from its byte-packed node format (target deltas, last-transition optimization) and is a 500–700-line
port. Verdict: the best exact structure; the reversed-key variant is the one to prototype.

### 2.2 marisa-trie (LOUDS + tail compression)

MARISA is a static trie with recursively implemented storage. Its README benchmark on 9,805,576
Wikipedia titles (200,435,403 bytes plain, 54,933,690 gzipped) gives **marisa 50,753,560 bytes
(5.18 B/key)** versus tx-trie (LOUDS) 127,727,058 (13.02 B/key) and darts-clone 376,613,888
(38.4 B/key) ([README](https://raw.githubusercontent.com/s-yata/marisa-trie/master/README.md)).

*Measured here* (Python `marisa-trie` 1.4.1, `Trie(keys).save()`, file size):

| Set | Bytes | Bytes/key |
|---|---|---|
| Big list, 2,065,646 keys | 10,759,752 | **5.21** |
| All 23 lists, 2,672,240 keys | 15,565,352 | **5.82** (14.8 MiB) |

For scale, `gzip -9` of the big list is 10,452,074 bytes (5.06 B/key) and `xz -9` is 8,175,592
(3.96 B/key): marisa is within 3 % of gzip while supporting exact lookup. Build peak: the Python
process building the big list peaked at **388 MB RSS**, but that includes the 2 M Python strings;
libmarisa's own peak is UNVERIFIED. Lookup is O(length) with pointer/rank-select work; I did not
measure it. C# size: MARISA's recursion, LOUDS, tail and link encoding are thousands of lines; not
implementable in 300 lines. Verdict: the space winner, but a library project, and the build peak is
a risk on a 1 GiB device.

### 2.3 LOUDS / path-compressed tries

LOUDS encodes an ordinal tree in 2 bits per node plus labels; SuRF's hybrid LOUDS-DS "consumes only
10 bits per trie node" ([SuRF, SIGMOD 2018, §2](https://people.iiis.tsinghua.edu.cn/~huanchen/publications/surf-sigmod18.pdf)).
On our big list the **unminimized** character trie has 19,364,510 nodes (9.37 nodes/key, measured
here by summing `len - LCP(prev)`), so 10 bits/node is 24.2 MB (11.7 B/key) for that list; all 23
lists give 26.5 M nodes and 31.6 MiB (12.4 B/key). A LOUDS trie is exact but does not share suffixes
(the DAG does), so it is larger than the FST. A path-compressed (radix/Patricia) trie over labels
has ~1.02 nodes/key and ~12.6 B/key (see 2.5), because flat block lists barely contain subdomains.
C# size: a LOUDS builder/reader is ~200–300 lines; lookup needs rank/select. Verdict: more code than
front coding for the same or worse space.

### 2.4 HAT-trie

The HAT-trie combines a trie index with cache-conscious array-hash buckets; it is **dynamic**
(supports inserts) and keeps sorted order. The paper reports up to 80 % faster and up to 70 % less
space than a burst-trie; on its 28.77 M-string "distinct" set (average length 9.59) the best hybrid
configuration uses **270.16 MB = 9.39 B/string**, pure 332 MB (11.5 B/key), burst-trie 901 MB
(31 B/key) ([HAT-trie, ACSC 2007, Tables 1–2](https://moodle2.units.it/pluginfile.php/717134/mod_resource/content/0/Hat-trie.pdf)).
It is exact and has a good build peak (it builds in place), but it stores whole keys in buckets, does
not give suffix matching directly (you would store reversed keys), and a C# implementation of the
trie + array-hash buckets is ~300–500 lines. Verdict: competitive with a simple FST on short keys,
but more code and bucket slack; not a clear win over front coding.

### 2.5 Front coding (block prefix compression)

Store the sorted keys in blocks; inside a block, drop the prefix shared with the previous key. This
is exactly LevelDB's block format: `shared_bytes: varint, unshared_bytes: varint, key_delta`, with a
full key every `block_restart_interval` (default 16) and a restart-offset array for binary search
([block_builder.cc](https://raw.githubusercontent.com/google/leveldb/main/table/block_builder.cc),
[options.h](https://raw.githubusercontent.com/google/leveldb/main/include/leveldb/options.h)).

*Measured here* on the extracted lists, with 1-byte LCP, 1-byte suffix length and a 4-byte block
offset:

| Block | All lists, MiB | Bytes/key |
|---|---|---|
| 8 | 33.54 | 13.16 |
| 16 | 31.96 | 12.54 |
| 32 | 31.17 | 12.23 |
| 64 | **30.78** | **12.08** |
| 128 | 30.58 | 12.00 |

The average LCP between adjacent sorted domains is 7.33 bytes out of 16.71 (median 7), so ~44 % of
the text disappears. Exactness: exact (same bytes, decoded). Build: one pass after the existing sort;
peak = raw buffer + compressed buffer + block offsets (~37 + 24 + 8 MB for the big list, ~100 MB
while the old list is still alive). Lookup: binary
search over block first keys (~15 probes at B=64) then decode ≤64 entries; same order as the current
binary search, probably slightly better cache behaviour. C# size: **~120–150 lines**. Verdict: the
smallest, lowest-risk exact improvement; ~47 % below 57.8 MiB, or ~40 % with the Bloom kept.

### 2.6 Reversed-label trie

A label trie over reversed labels is the natural DNS suffix structure (PowerDNS `SuffixMatchTree`,
uBlock `HNTrieContainer`). On our big list, the number of distinct suffixes is **2,105,626 for
2,065,646 domains** (1.019 nodes/key): only 1.9 % of the domains are suffixes of another, so there is
almost no sharing. Storing one node per suffix with 2 bits topology + 1 bit terminal + 1 byte label
length + the first label's bytes gives **~13.7 B/key (28.2 MB)** for the big list; all lists give
2.82 M nodes and **~13.6 B/key (~35 MiB)**. uBO's 12 B/node + characters is ~24 B/key by the
same node count. Exact, and suffix lookup is one walk, but on flat block lists it is no better than
front coding and 50 % worse than the FST. Verdict: only interesting for lists with many subdomains,
which the current data is not.

### 2.7 SuRF and Elias–Fano: not exact, or not a set

SuRF is an **approximate** range filter built on the same LOUDS-DS trie: at equal memory its point
false-positive rate is slightly worse than a Bloom filter (0.2 % vs 0.1 % in the RocksDB experiment),
and it cannot confirm a key. It is out on exactness.

Elias–Fano encodes a sorted integer sequence in `n·⌈log2(U/n)⌉ + 2n` bits
([survey, §3.4](https://arxiv.org/abs/1908.10598)); for 2.67 M 64-bit hashes in `U = 2^64` that is
**5.74 B/key (14.6 MiB)**, but it is still a hash set, not an exact domain set. The useful exact
application is the **offset array**: 2.45 M offsets into a ~37 MB buffer cost ~6.1 bits each instead
of 32, saving ~6.7 MB (about 12 % of 57.8 MiB) with ~80 lines and no change to the string storage.
That is a cheap first step, not the 2× win.

## 3. Minimal perfect hashing with verification

An MPHF maps the n keys bijectively to `[0, n)`; it says nothing about a key outside the set, so
membership needs the key or a fingerprint.

| Scheme | Space | Notes |
|---|---|---|
| Lower bound | **1.443 bits/key** (`log2 e`) | [MPHF survey](https://arxiv.org/abs/2506.06536) |
| CHD | **2.0 bits/key** at α=0.99, λ=6 | fast build, slow query; survey §6.1 |
| PTHash | competitive with CHD, 2–4× faster query; "purely retrieval-based methods cannot get below 2 bits/key" | [PTHash](https://arxiv.org/abs/2104.10402), survey §10 |
| RecSplit | **1.56 bits/key**, <2 ms/key | [RecSplit](https://arxiv.org/abs/1910.06416) |
| ShockHash | **1.489 bits/key** for 10 M keys, ~30 min; 1.52 with RecSplit-like build time | [ShockHash](https://arxiv.org/abs/2310.14959) |
| Bipartite ShockHash-RS / Consensus-RS | **1.489 / 1.444 bits/key** | survey §6.2 |
| BBHash | **3.7 bits/element** at 10^10 keys, 5 GB and <7 min with 8 threads | [BBHash](https://arxiv.org/abs/1702.03154) |
| Ribbon / BuRR | retrieval with **<1 % space overhead** over `r` bits/key; Bloom has ≥44 % overhead | [Ribbon](https://arxiv.org/abs/2103.02515), [BuRR](https://arxiv.org/abs/2109.01892) |

Exactness: with an MPHF alone, any key maps somewhere; to answer membership exactly you store the
keys in MPHF order, which puts the string bytes back. With an r-bit fingerprint the false-positive
rate is `2^-r` (probabilistic), and at r=64 the fingerprints alone are 8 B/key, worse than the FST.
The only sensible use is as a **lookup accelerator**: MPHF + a key array replaces binary search with
1–2 accesses for ~2–4 bits/key. But the FST already gives O(length) lookup without a separate key
array, and front coding's binary search is adequate. Verdict: no space win, and not exact without the
keys; not worth a rewrite.

## 4. Filters as a front end only

A filter can never make the exact structure smaller; it only moves the miss cost.

* Bloom: our 10 bits/key (1.25 B/key) is already near the practical optimum; the paper's
  "space overhead ≥ 44 %" refers to the `log2(1/f)` bound.
* Xor filters: faster and ~1.23× smaller than Bloom at the same FPR in the authors' evaluation
  ([Xor filters](https://arxiv.org/abs/1912.08258)), which would save perhaps 1 MiB here.
* Ribbon/BuRR: <1 % overhead over `r` bits/key and faster than Bloom; a 1 %-FPR ribbon is ~7.1
  bits/key against Bloom's ~10. Saves ~1 MiB. Still approximate.
* Chrome/Firefox: 4-byte (Chrome) or 32-bit delta-coded (Firefox) prefixes, then full-hash
  confirmation. This is the canonical "filter then exact confirm" design, but the confirm is remote
  or needs the full hash store; it does not give a local exact set.

Verdict: keep the Bloom only if an FST's own miss path turns out to hurt p50; do not build the
structure around a filter.

## 5. Measurements side by side

All rows except the baseline are per-list structures over the same 23 extracted lists (2,672,240
keys); the baseline is the app's 2,454,497 entries. Scale a row by 0.918 to compare at the app's
count.

| Structure | Bytes/key | MiB (23 lists) | vs 57.8 MiB | Exact | Build peak | Lookup |
|---|---|---|---|---|---|---|
| Current `DomainSet` + Bloom | 24.7 | 57.8 | 1.00× | yes | buffer + offsets + Bloom | Bloom + binary search |
| **FST, forward** | **9.21** | **23.47** | **−59 %** | yes | 33 MB (Rust, streaming); ~63 MB in C# with the sorted buffer | 264 ns miss / 808 ns hit per set |
| **FST, reversed** | **8.75** | **22.29** | **−61 %** | yes | same | one walk per set answers all suffixes (boundary-aware reader); 488 ns miss / 777 ns hit per suffix walk |
| **marisa-trie** | **5.82** | **14.83** | **−74 %** | yes | 388 MB Python peak (includes keys); C++ UNVERIFIED | O(length), not measured |
| Front-coded blocks, B=64 | 12.08 | 30.78 | −47 % | yes | buffer + compressed + block index | block binary search + decode |
| Front-coded + Bloom | 13.68 | 34.8 | −40 % | yes | +~4.2 MB | as above, cheap misses |
| LOUDS char trie (10 bits/node) | 12.4 | 31.6 | −45 % | yes | trie nodes | rank/select, O(length) |
| Reversed-label trie | ~13.6 | ~35 | −40 % | yes | suffix node set | one walk |
| Elias–Fano offsets only | −3.2 B/key vs current | ~51 | −12 % | yes | none extra | EF select + binary search |
| EF over 64-bit hashes | 5.74 | 14.6 | −75 % | **no** | n/a | 2 accesses |
| SuRF / Bloom / Xor / Ribbon | 1.25 (Bloom) | 3.3 (Bloom) | n/a | **no** | small | 1–3 accesses |

The LOUDS and reversed-label rows are all-list estimates from node counts; the FST, marisa and
front-coding rows are file sizes from actual builds/simulations. The FST and marisa sizes are the
serialized structure only; in C# add a ~24-byte array header and the owning object. The app's bench
set has 2.454 M entries (8 % fewer than the 2.672 M measured here), so scaled: FST-reversed
20.5 MiB, front-coded 28.3 MiB, marisa 13.6 MiB.

## 6. Ranked shortlist

**1. Reversed-key FST, per list — best if a compact node encoding is acceptable.**
22.3 MiB measured (−61 %; 20.5 MiB scaled to the app's 2.454 M entries), exact, one walk per list
for all suffixes, build peak ~63 MB in C#, 33 MB in the Rust streaming builder. A simple C# arena
in ~300 lines gives ~10–12 B/key (26–32 MiB); the crate's 8.0–9.2 B/key needs its packed node
format (~500–700 lines). Keep the Bloom only if the extra ~11 µs/query worst-case miss path shows
up in p50; FST + Bloom is ~26.5 MiB (−54 %).

**2. Front-coded sorted blocks + existing Bloom — smallest, lowest-risk patch.**
30.8 MiB (−47 %), or 34.8 MiB (−40 %) with the Bloom (28.3 / 31.9 MiB scaled to the app's entry
count); ~120–150 lines; exact; ~68 MB new structures, ~100 MB while the old list is alive; lookup
stays a binary search, now over 1/64 of the keys plus a short decode. This is the option to take if
the change must stay small and predictable.

**3. marisa-trie / a MARISA-like succinct trie — best space, not a patch.**
14.8 MiB (−74 %), exact, but thousands of lines of C++ and a 388 MB Python build peak (C++ peak
UNVERIFIED); not implementable in 300 lines and not a NuGet-free C# job.

**4. LOUDS / path-compressed trie.**
~12.4 B/key (LOUDS) or ~13.6 B/key (reversed labels), exact, more code than front coding, no space
advantage over it. Skip.

**5. Reversed-label trie (uBO/PowerDNS style).**
Natural suffix semantics, but ~13.6 B/key on flat lists and 1.02 nodes/key; only worth it if
the lists gain many subdomains.

**6. MPHF + keys / EF hashes / SuRF / filters.**
No exact space win (MPHF + keys), or not exact (EF hashes, SuRF, Bloom/Xor/Ribbon). Skip for this
problem.

A merged FST over the 2.29 M unique names plus a 4-byte per-entry list mask would be ~20.1 +
9.2 = 29.3 MB and one lookup per query, but it changes the app's per-list order, allow/block and
per-URL option model; the per-list FST gets most of the win without that rewrite.

## 7. What the smallest C# change looks like

Front-coded blocks, keeping the existing per-list `DomainSet` API and the suffix walk:

```
// one buffer per list, blocks of 64 keys
// block: [first key length][first key bytes]
//        then 63 × [shared prefix len][suffix len][suffix bytes]
// int[] blockOffsets  (4 B per 64 keys = 0.06 B/key)
bool Contains(ReadOnlySpan<byte> key) {
    int lo = 0, hi = _blockOffsets.Length - 1;
    while (lo < hi) { ... compare key with the block's first key ... }
    int p = _blockOffsets[lo], shared = 0;
    Span<byte> current = stackalloc byte[255];
    for (int i = 0; i < 64; i++) {
        shared = _buffer[p++]; int n = _buffer[p++];
        // current[0..shared) stays; copy n suffix bytes; compare
        if (equal) return true;
    }
    return false;
}
```

The parser keeps writing UTF-8 keys exactly as now; `Sort()` already produces the order the block
builder needs, and gains a compaction pass that emits the blocks. No new dependency, no change to
the allow/block scan, one file plus the nested type.

For the FST variant the same buffer feeds a Daciuk builder: sort, walk the sorted keys once, freeze
suffix states into a bounded registry (`Dictionary<StateKey,int>`, ~10 k entries) and append each
frozen node to a `byte[]` arena; the reader is a loop over `(label, offset)` pairs. Build the reversed
variant by writing the key bytes reversed and checking the final flag at every `'.'` during the walk.
Both are single-file changes and can be validated against `DomainSet` with the existing boundary and
exhaustive tests.

## 8. What I could not verify

* Per-domain memory for Unbound, BIND, PowerDNS, Knot, CoreDNS and AdGuard is not published; the
  figures above are field-layout inferences, not measurements.
* NextDNS is closed source; no data structure or memory figure exists publicly.
* Chromium and Firefox publish prefix sizes and store caps, not total memory for their lists.
* libmarisa's own build peak: the 388 MB figure is the Python process and includes the key list.
* FST lookup was measured on amd64 in Rust, not on the ARM64 target and not through the app.
* Front-coding lookup was not benchmarked; its latency claim is algorithmic only.
* There is no primary benchmark of FST/LOUDS/marisa on DNS block lists; the B/key numbers for FST,
  marisa and front coding here are measurements on our own lists, not published results.

## Summary

No mainstream DNS blocker or resolver holds an exact domain set in a form close to 24.7 B/domain:
they use SQLite, rbtrees, hash tables, per-domain structs, Go maps or 32/64-bit hashes, and the only
compact real-world lists (Chrome, Firefox) are probabilistic prefix arrays confirmed elsewhere.
Among exact structures, the measurements are clear:

* **FST (reversed keys, per list): 22.3 MiB, −61 %, exact, one walk per list.** The `fst` crate does
  this with a streaming builder at 33 MB peak; a 300-line C# arena is ~10–12 B/key (26–32 MiB), and
  the crate's 8.0–8.75 B/key needs its packed node format (500–700 lines).
* **Front-coded blocks: 30.8 MiB, −47 %, exact, ~120–150 lines.** The lowest-risk real win.
* **marisa-trie: 14.8 MiB, −74 %, exact, but a library-sized implementation with a large build peak.**

The most promising direction is the reversed-key FST, optionally with the existing Bloom left in
front; the smallest acceptable change is front-coded blocks. MPHF, Elias–Fano over hashes, SuRF and
all filters are either not exact or do not reduce the exact storage, so they cannot beat the 57.8 MiB
point on their own.

## References

Primary sources opened for this note (all URLs as read):

* https://burntsushi.net/transducers/ — FST construction, streaming build, sizes.
* https://blog.mikemccandless.com/2010/12/using-finite-state-transducers-in.html — Lucene FST, 9.8 M terms / 69 MB.
* https://raw.githubusercontent.com/s-yata/marisa-trie/master/README.md — MARISA vs LOUDS vs darts sizes.
* https://moodle2.units.it/pluginfile.php/717134/mod_resource/content/0/Hat-trie.pdf — HAT-trie design and tables.
* https://people.iiis.tsinghua.edu.cn/~huanchen/publications/surf-sigmod18.pdf — SuRF, 10 bits/node, FPR.
* https://arxiv.org/abs/1908.10598 — Elias–Fano bound and front coding context.
* https://arxiv.org/abs/2506.06536 — MPHF survey and comparison numbers.
* https://arxiv.org/abs/2104.10402 — PTHash.
* https://arxiv.org/abs/1910.06416 — RecSplit, 1.56 bits/key.
* https://arxiv.org/abs/1702.03154 — BBHash, 3.7 bits/element.
* https://arxiv.org/abs/2310.14959 — ShockHash, 1.489 bits/key.
* https://arxiv.org/abs/2103.02515 — Ribbon filter.
* https://arxiv.org/abs/2109.01892 — BuRR, <1 % overhead.
* https://arxiv.org/abs/1912.08258 — Xor filters.
* https://raw.githubusercontent.com/google/leveldb/main/table/block_builder.cc and `include/leveldb/options.h` — front coding / restart interval 16.
* https://developers.google.com/safe-browsing/v4/update-api — 4-byte prefixes, full-hash confirm.
* https://raw.githubusercontent.com/chromium/chromium/main/components/safe_browsing/core/browser/db/hash_prefix_map.h — mmap'd sorted prefix files.
* https://raw.githubusercontent.com/mozilla-firefox/firefox/main/toolkit/components/url-classifier/nsUrlClassifierPrefixSet.h and `.cpp` — delta-coded 32-bit prefix set.
* https://raw.githubusercontent.com/gorhill/uBlock/master/src/js/hntrie.js — reversed-label typed-array trie.
* https://raw.githubusercontent.com/pi-hole/FTL/master/src/database/gravity-db.c and https://raw.githubusercontent.com/pi-hole/pi-hole/master/advanced/Templates/gravity.db.sql — SQLite gravity.
* https://docs.pi-hole.net/database/domain-database/ — Pi-hole domain tables.
* https://raw.githubusercontent.com/AdguardTeam/urlfilter/master/dnsengine.go and `internal/lookup/shortcut.go` — AdGuard indexes.
* https://raw.githubusercontent.com/0xERR0R/blocky/main/cache/stringcache/hash_set.go and `wildcard_cache.go` — Blocky hash sets.
* https://raw.githubusercontent.com/NLnetLabs/unbound/master/services/localzone.h and `services/rpz.c` — Unbound local zones.
* https://raw.githubusercontent.com/imp/dnsmasq/master/src/dnsmasq.h and `src/domain-match.c` — dnsmasq `crec` and sorted server array.
* https://raw.githubusercontent.com/coredns/coredns/master/plugin/hosts/hostsfile.go and `plugin/file/tree/tree.go` — CoreDNS maps and LLRB tree.
* https://raw.githubusercontent.com/CZ-NIC/knot-resolver/master/modules/policy/policy.lua and `README.rst` — Knot Aho–Corasick / suffix_common.
* https://raw.githubusercontent.com/isc-projects/bind9/main/lib/dns/include/dns/rpz.h and `lib/dns/rpz.c` — BIND RPZ hash table.
* https://raw.githubusercontent.com/PowerDNS/pdns/master/pdns/recursordist/filterpo.hh and `pdns/dnsname.hh` — PowerDNS RPZ maps and SuffixMatchNode.
* https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/0dd592a/Apps/AdvancedBlockingApp/App.cs and `DnsServerCore/Dns/ZoneManagers/BlockListZoneManager.cs` — `HashSet<string>` and merged dictionary.
* https://raw.githubusercontent.com/brave/adblock-rust/master/src/engine.rs — FlatBuffer rule storage.
