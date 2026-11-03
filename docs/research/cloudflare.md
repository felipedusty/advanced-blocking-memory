# Cloudflare's published work on large-set membership, and what transfers to our `HashSet<string>` problem

Research note, 2026-11-02. Read-only investigation; nothing here was benchmarked by me.
Every factual claim below is tagged with the URL I actually opened. Anything I could not
verify is marked **UNVERIFIED**, and anything I derived is marked **[INFERENCE]**.

## 0. Bottom line

1. **Cloudflare has never published the data structure behind 1.1.1.1 for Families or
   Gateway DNS block lists.** The only public statement is that they ship "a compact data
   structure" that replicates efficiently and takes hours to regenerate
   (<https://blog.cloudflare.com/the-mistake-that-caused-1-1-1-3-to-block-lgbtqia-sites-today/>).
   No name, no layout, no numbers.
2. Their **closest published analogues to our problem are not block lists**. In descending
   order of directness: `entropy-map`, an exact minimal-perfect-hash set that keeps the keys
   anyway to reject non-members (2.10–2.71 bits/key of index overhead, 5–20 ns queries);
   `wirefilter`'s `RangeSet`, a sorted `Box<[RangeInclusive<T>]>` with binary search;
   `trie-hard`, a contiguous bitmask trie for small string sets with a high miss rate; and
   the 2026 Big Pineapple DNS-cache rewrite (953 → 420 bytes/entry), which is a lesson in
   *field layout* rather than in set algorithms.
3. Two of their results **argue against structures we might be tempted to add**: Bloom
   filters stop paying once they exceed L3
   (<https://blog.cloudflare.com/when-bloom-filters-dont-bloom/>), and a pointer-based
   trie loses to flat arrays once the working set exceeds TLB reach — their BPF LPM trie
   degrades from 134.7 ns to ~1.5 M ops/s as it grows past ~80 K entries
   (<https://blog.cloudflare.com/a-deep-dive-into-bpf-lpm-trie-performance-and-optimization/>).
4. Their **most transferable single idea for bytes** is deduplication of repeated strings
   and one contiguous, length-prefixed blob per entry set, with `u16` offsets instead of
   pointers (DNS cache post, 2026). Applied to us that becomes *block front-coding of the
   sorted name blob*: still exact, still binary-searchable, one extra decode per probe.
5. Their **most transferable idea for peak memory** is `mmap-sync`: build the next version
   in a second file, publish it with a one-word atomic switch, never mutate in place
   (<https://github.com/cloudflare/mmap-sync>, <https://blog.cloudflare.com/scalable-machine-learning-at-cloudflare/>).
   In .NET that maps onto `MemoryMappedFile` + `AcquirePointer`, which moves the 30–90 MiB
   of block-list bytes out of anonymous RSS into reclaimable page cache.

No Cloudflare post gives us a ready-made better `DomainSet`, and none describes a DNS
block-list structure at all. But the GitHub org does contain one exact set artifact with a
published per-key index cost (`entropy-map`, §6a.2) and one sorted-array range set
(`RangeSet`, §6a.3), and the 2026 cache rewrite gives the layout techniques. Together they
give us cheap, testable refinements. The ranked list is in §9; the audit trail — 580 org
repositories, 167 blog posts from the tag sweep, the docs limits, and the research
publications — is in §12.

---

## 1. Method and scope

I searched `blog.cloudflare.com`, `developers.cloudflare.com`, `research.cloudflare.com`,
the `cloudflare` GitHub organisation, and Cloudflare-tagged crates, for: Bloom / cuckoo /
xor / perfect hash, trie, radix, LPM, FST, compact/sorted arrays, zero-copy, `rkyv`, mmap,
block list, category, credential, DDoS set, ipset, eBPF map, WAF/Ruleset matching, and DNS
cache/resolver internals.

What "exhaustive" meant in practice, so the coverage can be checked:

- **GitHub org census.** Enumerated all 580 public repositories of the `cloudflare` org
  through the API (6 pages of 100; pages 7–8 empty), filtered names and descriptions, and
  read the source of every repository whose subject touches membership sets, filters,
  tries, perfect hashing, compact serialization, DNS, hostname/URL matching or memory
  reduction. Also checked the `cloudflareresearch` org and the other `cloudflare*` orgs
  returned by search. Results in §6a and §12.C.
- **Blog tag sweep.** Fetched the tag pages for Rust, Research, Performance, DNS, 1.1.1.1,
  Gateway, Security, Bots, Speed, Optimization and Deep Dive (18 posts each, 167 unique),
  plus the `cuckoo` and `bloom` tags, which **do not exist** (both return the blog's 404
  page). Every title is listed in §12.A with a relevance verdict.
- **Full-text reads.** I read each cited post in full, not the search snippet. Posts that
  appeared only as snippets are marked **UNVERIFIED** and are not used as evidence.
- **Docs limits.** Read the public list/category pages and the Cloudflare One account-limit
  reference, because the documented caps are the only public hint at the scale the list
  products are built for (§6a.5).
- **Research and talks.** Read the Research site's fast/measurable focus pages and its
  presentations index (21 publications + talks); none is about set structures (§6a.6).

Talks, RFCs and IETF drafts by Cloudflare authors turned up nothing on set representation;
the DNS RFCs they authored (DoH, SVCB, OHTTP) are protocol work, not storage.

Terminology in this note: *exact* = no false positives and no false negatives; *suffix
lookup* = testing `a.b.example.net`, `b.example.net`, `example.net`, `net`; *per-list
attribution* = knowing which of the N lists produced a hit.

Our current position, for reference (from this repository, `docs/analysis.md`, measured on
the pinned 23-list config): original `HashSet<string>` ≈ 269 MiB anon for 2,670,703
per-list entries (105.8 B/entry including the server baseline); compact exact `DomainSet`
84.0 MiB sorted-only and 89.4 MiB with a Bloom front end (33.0 and 35.1 B/entry); a
64-bit open-addressing index costs 103.1 MiB. The theoretical floor discussed in the brief
is 57.8 MiB (≈29 B per unique name, 2,292,355 unique).

---

## 2. DNS filtering and block lists: what Cloudflare actually says

### 2.1 1.1.1.1 for Families

<https://blog.cloudflare.com/introducing-1-1-1-1-for-families/>, 2020-04-01.

- Two resolver addresses, 1.1.1.2 (malware) and 1.1.1.3 (malware + adult). The post notes
  that 1.1.1.1 as a whole was then processing "more than 200 billion DNS requests per day";
  it gives no per-Families volume.
- "1.1.1.1 for Families is built on top of the same site categorization and filtering
  technology that powers Cloudflare's Gateway product." No data structure is described.

### 2.2 The one structural sentence Cloudflare has published

<https://blog.cloudflare.com/the-mistake-that-caused-1-1-1-3-to-block-lgbtqia-sites-today/>,
2020-04-02, post-mortem of a mis-included category:

> "In order to distribute the list of sites quickly to all our data centers we use a
> compact data structure. The upside is that we can replicate the data structure worldwide
> very efficiently. The downside is that generating a new version of the data structure
> takes several hours."

That is the whole disclosure. It establishes the *shape* of their design — a prebuilt,
compact, immutable artifact, replicated as a unit, rebuilt offline on the order of hours —
and nothing about the algorithm. It also notes that when they needed an emergency fix they
"pushed individual sites to an allow list immediately", i.e. a small, separately updatable
override set in front of the big artifact.

This is exactly the immutable-build-then-swap model we are considering, and it is evidence
that a multi-hour build is acceptable when the artifact is compact. It is *not* evidence
about memory per domain.

### 2.3 Gateway: categories, inheritance, and the suffix rule

<https://developers.cloudflare.com/cloudflare-one/traffic-controls/domain-categories/>,
page last updated 2026-10-12.

- Categories come from Cloudforce One, an upstream content vendor, "over 30 open-source
  intelligence feeds and premium commercial feeds, such as Avira and Zvelo", plus in-house
  ML (DGA, DNS tunnelling, phishing).
- The page publishes the full category table (IDs 1–34 with subcategory IDs), which is the
  per-entry attribution key: a domain carries category/subcategory IDs, not a list name.
- **Suffix semantics are documented and match ours**, with a twist: "Subdomains that have
  not been assigned a category will inherit the category of their parent domain. When
  Gateway categorizes a subdomain, the subdomain will carry only its own category.
  Categorized subdomains will not inherit their parent domain's categories."
- Two optional behaviours matter for lookup design: "Filter traffic by resolved IP
  category" (block on the resolved IP as well as the name) and "Ignore `CNAME` domain
  categories" (CNAME targets carry their own categories unless suppressed).

<https://developers.cloudflare.com/cloudflare-one/traffic-controls/dns-policies/>,
last updated 2026-10-12: policies are evaluated first-match; a blocked query is answered
`0.0.0.0`/`::` for A/AAAA and `REFUSED` for other types. No storage detail.

**Verdict for us.** Gateway's semantics (parent-label inheritance, per-entry category IDs,
explicit opt-out for CNAMEs) are a public confirmation that production DNS filtering is
built on suffix lookup plus a small attribution value per name — the same contract we have.
The representation is not published. Their "hours to regenerate" note is the strongest
public support for the immutable artifact approach.

### 2.4 Where the filtering code actually runs

<https://blog.cloudflare.com/big-pineapple-intro/>, 2023-02-28: 1.1.1.1 for Families,
AS112 and "Gateway DNS" are "supported by guest apps running on BigPineapple", the Rust
resolver platform. Guest apps run in Wasm sandboxes with an isolated memory space; to avoid
copying request data they pre-reserve address space and map a shared region into the guest
("no copy is needed"). Relevant detail for us: filtering is a *plugin inside the resolver
process*, so whatever the block-list structure is, it is in-process and read-mostly. It
does not follow that it is a hash set.

### 2.5 What is missing

No Cloudflare post or doc page describes the block-list structure, its per-domain cost,
its build algorithm, or how per-list attribution is encoded. The 1.1.1.3 post-mortem is the
only primary source, and it says "compact data structure" and stops.

---

## 3. Probabilistic and exact set structures in production

### 3.1 "When Bloom filters don't bloom" — the anti-Bloom result

<https://blog.cloudflare.com/when-bloom-filters-dont-bloom/>, 2020-03-02, Marek Majkowski.

Task: deduplicate 40 M lines (600 MiB) from IP-spoofing measurement files. He built
`mmuniq-bloom` (k=8, power-of-two bit array, siphash24) and profiled it.

| Configuration | Time | Notes (all from the post) |
|---|---|---|
| `sort` + `uniq` baseline | "about 2 minutes" | shell tooling |
| Bloom, k=8, 128 MiB filter | 12 s | 87.2% of cycles in the hot loop; one `mov` (the bit-array load) dominated |
| Bloom, k=1 | 11 s user + 22 s kernel | needs 64 GiB to hold the same false-positive rate |
| 64-bit siphash open-addressing table, linear probing | 4 s | 0.7 buckets probed on average |
| Same + dynamic resize + batched prefetch | **2.1 s** | 35–40% from prefetch alone |

The arithmetic he gives: 40 M lines × 8 hashes ≈ 320 M memory misses; at ~100 ns each that
is ~32 s of pure miss time, and the measured 12 s means the 128 MiB filter only partly
fits cache. Collision probability for the 64-bit-hash variant is derived as
`n²/2m` = `(40M)²/(2·2⁶⁴)` ≈ one bad set in 23,000.

Quotable conclusion: "Bloom filters are great, as long as they fit into the L3 cache. The
moment this assumption is broken, they are terrible… Bloom filters optimize for memory
usage, not for memory access." And: "prefer optimizing for reduced number loads, over
optimizing the amount of memory used."

**Exact?** No — both variants are probabilistic; he explicitly accepts data loss. **Suffix?**
No. **Transfers?** Yes, as a *warning*: our front-end filter is 5.3 MiB over the sorted set
and its measured cost is inside amd64 noise but it is a random-access structure. On a Pi
with 512 KiB–2 MiB L3, any filter bigger than L3 behaves like his 128 MiB filter. The
transferable design rule is "measure misses per lookup, not bytes saved".

> **Round-2 correction (§13).** The framing above — "anti-Bloom warning" — undersells the
> post. Its winning structure is not a Bloom at all but a table of raw 64-bit hashes with
> linear probing and no stored keys, and the author reports it beating the Bloom filter on
> both time and false-positive rate. The L3 warning stands; the structural finding was
> incomplete. Source-level detail in §13.1.

### 3.2 Brotli: a k=1 Bloom as a one-bit rejector

<https://blog.cloudflare.com/brotli-compression-using-a-reduced-dictionary/>, 2020-11-11.

Three-layer lookup for dictionary words: radix trie → hash table on the first four bytes →
k=1 Bloom filter.

| Layer | Size per key | Job | Reported effect |
|---|---|---|---|
| radix trie (compressed nodes) | 31,700 words | longest match | avoids trying several words |
| hash table on 4-byte prefix | "16 bytes" per prefix, ~11,000 prefixes | reject if no word starts with these 4 bytes | avoids trie walks for most misses |
| k=1 Bloom on 4-byte prefix | **1 bit** per prefix | reject before the hash probe | "rejects more than half of all non-matching positions", saves a cache miss |

Cost: "only 1% to 3% more CPU" for the whole reduced-dictionary scheme; the k=1 filter is
"simply a lookup table with one bit" and "requires a single memory access".

**Exact?** The layers are filters; the trie match is exact, so the composite is exact.
**Suffix?** No, but the *pattern* — 1 bit to reject, 16 bytes to narrow, tree to confirm —
is directly reusable. **Transfers?** Yes, see §9 R3: a 1-bit-per-candidate rejector over the
full candidate name (2 MiB at 2²⁴ bits) can replace or precede the current Bloom, at one
bit test per suffix candidate instead of one multi-hash test per set.

### 3.3 Quicksilver: Bloom vs Cuckoo, with numbers

<https://blog.cloudflare.com/quicksilver-v2-evolution-of-a-globally-distributed-key-value-store-part-1/>,
2025-07-10.

Quicksilver is Cloudflare's global KV store, "over 3 billion keys per second". In v1,
RocksDB's per-SST Bloom filters answered negative lookups from memory: "99% of the time,
negative lookups are served using only this in-memory data structure, avoiding the need for
disk I/O". Negative lookups are "about ten times more" frequent than positive ones.

They needed the same trick on proxies and evaluated Cuckoo filters for 5 billion keys:

| Structure | Memory for 5 B keys at comparable FPR | Exact? |
|---|---|---|
| Bloom filter | **6 GB** | no |
| Cuckoo filter | **18 GB** | no |

They rejected both in favour of **key/value separation**: store every key, persist values
only for cached keys. "The total size of pure keys in Quicksilver is approximately 11 times
smaller than the full dataset." This keeps Bloom-filter fast negative lookups and unlocks
range queries.

**Transfers?** Two things. (a) *Quantitative*: at equal false-positive rate, a Bloom is 3×
smaller than a cuckoo filter in their measurement — so if we ever go probabilistic, cuckoo
and xor filters are the wrong direction. (b) *Structural*: keep the key (the name) and make
the value (the list attribution) as small as possible; that is the same conclusion as our
merged-index measurement. Note the asymmetry with our case: they can afford to be
probabilistic on "does this key exist" because a false positive only costs a replica
round-trip; a DNS block list cannot.

### 3.4 pingora-limits: count–min sketch, and the "first stage" pattern

<https://blog.cloudflare.com/how-pingora-keeps-count/>, 2023-05-12.

CM sketch instead of `HashMap` for per-origin connection counting: O(1) per event,
O(log n) space, lock-free atomic counters. Benchmark with 1 M keys / 100 M events:

| Structure | Single thread | 8 threads | Peak bytes | Allocations |
|---|---|---|---|---|
| pingora-limits (CM sketch) | 10 ns/event | 212 ns | **26,184** | 9 |
| `Mutex<HashMap>` | 51 ns | 1,505 ns | 53,477,392 | 20 |
| `DashMap` | 43 ns | 212 ns | 36,211,208 | 491 |

That is 1/2000 of the naive memory at 5× the single-thread speed. Production collision
probability is tuned to ~1/2⁵².

The transferable sentence is at the end: where false positives are unacceptable, the sketch
"can work as a first stage filter where only the events beyond a certain threshold are fed
to a hash table to perform accurate counting". That is the same two-stage architecture as
our Bloom + exact search, stated as a general principle.

**Exact?** No, biased upward. **Transfers?** Not the structure (we do membership, not
counting). The principle, yes.

### 3.5 Pwned Passwords: bucketing by hash prefix

<https://blog.cloudflare.com/validating-leaked-passwords-with-k-anonymity/>, 2018-02-21.

The k-anonymity API: client sends the first 5 hex chars of the SHA-1, downloads that
bucket, compares offline.

| Quantity | Value (from the post) |
|---|---|
| dataset | 320 M hashes at design time; "over half a billion" on v2 |
| prefix length | 5 hex chars → 16⁵ = 1,048,576 buckets |
| bucket size, 320 M set | median 305 hashes; responses 8.6–16.8 KB, median 12.2 KB |
| bucket size, 500 M+ set | average 478; smallest 381, largest 584 |
| build | sort by hash, O(n log n + n), then cut at the longest prefix that keeps every bucket > 1 |

**Exact?** Yes, at the client, after the range download. **Transfers?** The idea of a
*prefix-keyed exact bucket* is the same shape as our sorted blob + binary search: one
sorted array, a prefix that identifies a contiguous range, exact compare inside. It also
shows the cost of very short prefixes: 5 hex chars still leaves ~500 entries per bucket at
500 M keys, i.e. a linear scan of hundreds. We get the same effect with 2.29 M names and
O(log n) + one cache line, which is better than their bucket scan because our keys are
already sorted.

### 3.6 Credential checks at the WAF edge

<https://blog.cloudflare.com/account-takeover-protection/>, 2021-03-30. Exposed Credential
Checks: "we apply a keyed cryptographic hash function to the username/password pair within
the WAF process and check whether the resulting hash value matches keyed hashes of pairs
from our database of known breached credentials." Credentials never leave the WAF process.

The MIGP design is described in
<https://blog.cloudflare.com/privacy-preserving-compromised-credential-checking/>
(search result only — **UNVERIFIED**, I did not open it): bucketing by a 16–20 bit hash
prefix of the username, per-entry keys derived through an OPRF, exact decryption client-side.
Do not cite the details without reading it.

**Transfers?** Only the pattern "keyed hash → bucketed exact store". No published structure
with a memory number. Not applicable to us: we have no secrets and no privacy constraint.

---

## 4. Tries, prefix and suffix matching

### 4.1 BPF LPM trie: why pointer tries lose at scale

<https://blog.cloudflare.com/a-deep-dive-into-bpf-lpm-trie-performance-and-optimization/>,
2025-10-21. `BPF_MAP_TYPE_LPM_TRIE` is what Magic Firewall and routing use for IP and
IP+port matching.

Benchmark (AMD EPYC 9684X, 10 K entries, 32-bit prefixes, selftests):

| Operation | Throughput | Latency |
|---|---|---|
| lookup | 7.423 M ops/s | 134.710 ns |
| update | 2.643 M ops/s | 378.310 ns |
| delete | 0.712 M ops/s | 1,405.152 ns |
| free | 0.573 K ops/s | 1.743 ms |

Scaling: "Once you reach 1 million entries, throughput is around 1.5 million ops/sec, and
continues to fall as the number of entries increases." Cause: each node is a separate
kmalloc allocation, so a path traversal is a chain of cache misses; "at around 80K entries,
dTLB miss rate becomes the bottleneck". The kernel implementation has only two child
pointers per node, so multibit comparison degrades to one bit at a time and level
compression (as in Linux `fib_trie`) is absent; path compression is "less effective" as data
densifies, and BPF LPM tries store the entire key at the leaf anyway.

**Exact?** Yes for range membership. **Suffix?** It is longest-prefix on bits, which is the
IP analogue of our parent-label walk, but a DNS name is not a fixed-width key. **Transfers?**
Strongly, as a negative result: a 2.29 M-name pointer trie would be ~2.29 M × depth
scattered nodes; on a Pi the dTLB is far smaller than on EPYC, so the crossover would come
much earlier than 80 K. Any trie we build must be a **single contiguous array**, and the
flat sorted blob we already have is the extreme case of that.

### 4.2 `trie-hard`: contiguous bitmask trie

<https://blog.cloudflare.com/pingora-saving-compute-1-percent-at-a-time/>, 2024-09-10, and
<https://github.com/cloudflare/trie-hard>.

Problem: remove ~100 internal headers from every proxied request at 35 M req/s. The original
loop ran 3.65 µs; inverting the loop (iterate request headers, test membership) gave 1.53 µs.

| Implementation | Bench time | Sampled CPU | Predicted CPU |
|---|---|---|---|
| original (100 × remove) | 3.65 µs | 1.71% | — |
| `HashMap` | 1.53 µs | 0.82% | 0.72% |
| `trie-hard` | **0.93 µs** | **0.34%** | 0.43% |

Other measured points: `fst` (the crate) was "a little (50 ns) slower" than `HashMap`;
regex was ~2× slower than `HashMap`; `radix_trie` was "a full microsecond slower than
hashmap". Trie reading is O(log L) for misses and O(L) for hits, and "we are getting misses
over 90% of the time" — that is why it wins.

How it is built (README): all nodes and child indices in contiguous vectors; each node
stores a **bitmask of allowed bytes** and a range into a central child-index array; the
child index is computed with `((input_mask - 1) & node.mask).count_ones()`. The design
assumes a small alphabet: "at most 37 unique bytes… in practice only 30 unique bytes appear
in the stored map. This means we are storing our underlying tree information in `u32`s."
Loading is bulk-only: 15.5 K words in 11.92 ms vs 3.49 ms for `radix_trie` (3.4× slower to
build, ~3× faster to read).

**Exact?** Yes. **Suffix?** No — it is prefix-oriented, and the README says prefix search is
not implemented. **Transfers?** The *technique* transfers (bitmask child test, `count_ones`
arithmetic, contiguous arrays), but the arithmetic does not hold for DNS: the alphabet is
`a–z`, `0–9`, `-`, `.` and possibly `_` — 38–39 distinct bytes, which no longer fits a
`u32` mask; you would need `u64` masks, doubling the per-node metadata. And a byte-per-node
trie over 2.29 M names has on the order of the total name length in nodes unless you path-
compress, at which point you have rebuilt a sorted array with worse constants. See §9 R5.

### 4.3 Workers routing is regex, not a trie

<https://blog.cloudflare.com/improving-web-standards-urlpattern/>, 2025-03-24. URLPattern
(WHATWG) is what Workers uses for route matching. On construction it "parses your input
patterns for each component and compiles them internally into eight specialized regular
expressions (one for each component type)"; matching runs those regexes. Cloudflare
contributed the implementation to Ada URL and Node.js. No memory or throughput numbers, and
no trie/hostname table. **Transfer:** none for us; recorded because "Workers routing" is
often assumed to be a radix tree and, per Cloudflare's own description, it is not.

### 4.4 Gateway wildcard domains and the synthetic-IP trick

<https://blog.cloudflare.com/egress-policies-by-hostname/>, 2025-07-07. Egress policies can
be written for `*.bank.example.com`, for a category, or for an application ("essentially
sets of hostnames grouped together"). Because egress must be decided at L4 before any HTTP
Host is visible, Gateway answers the DNS query with a **synthetic IP** from `100.80.0.0/16`
(or `2606:4700:0cf1:4000::/64`), remembers the mapping for a short time, and rewrites the
destination after applying the policy; addresses are recycled, so 65,536 IPv4 tags serve "a
very large number of hostnames".

**Transfer:** a genuinely different way to avoid a big lookup table — replace a key with a
small integer and keep a short-lived map. Not applicable to us (our lookup is already the
DNS query itself), but it is a reminder that Cloudflare's answer to "too many hostnames" is
often *don't store the hostnames*.

### 4.5 Magic Firewall: one shared map instead of N copies

<https://blog.cloudflare.com/magic-firewall-optimizing-ip-lists/>, 2022-03-29. IP lists were
implemented as nftables sets inside per-customer network namespaces. "Each network namespace
gets a complete copy of all the lists that its rules reference… if 10 users have a rule that
uses the anonymizer list, then a server has 10 copies of that list stored in the kernel."
They moved to a single eBPF `BPF_MAP_TYPE_LPM_TRIE` per list, shared across namespaces,
because eBPF maps are not namespaced; after the change "the number of customers is no longer
a predominant factor in this feature's resource usage". No byte numbers — the post shows
kernel slab and cgroup graphs only.

The nftables-in-a-namespace design is the closest published thing to an `ipset`: a
kernel-side set of IPs attached to a firewall rule, copied per namespace, and it is the
design they replaced. I found **no** Cloudflare post that describes using `ipset` itself, so
"Cloudflare runs block lists in iptables/ipset" is not supported by anything I could open.

**Exact?** Yes (ranges via LPM). **Transfers?** Directly, structurally: N copies of an
overlapping set is the expensive shape, one shared set plus a per-entry attribution is the
cheap shape. That is the argument for the merged index with a per-domain list bitmask; our
own measurement puts it at 64 MiB.

### 4.6 L4Drop: when matching is arbitrary, generate code, don't store a set

<https://blog.cloudflare.com/l4drop-xdp-ebpf-based-ddos-mitigations/>, 2018-11-28. They
wanted rules in an eBPF map (as Facebook's firewall does) but "the filters created by
bpftools rely heavily on matching arbitrary packet data… the kernel's eBPF verifier
currently disallows loops", so maps were impossible; they compile rules to C, then eBPF,
with per-rule enable bits patched into the ELF. Production: "over 8 million" packets/s
dropped, overall CPU up "about 10%", softirq up slightly over 2× while packets rose 40×.

**Transfer:** none for a membership set (our predicate is uniform), but it explains the
general Cloudflare preference: specialise the code path to the data when the data is
static.

### 4.7 Malicious-URL detection is not a published membership structure

<https://blog.cloudflare.com/building-urlscanner>, 2024-03-08. The URL Scanner behind
Security Center verdicts is "built upon ... Cloudflare Workers, Durable Objects, and the
Browser Rendering API": a submitted URL is rendered and analysed, and the verdict is stored
with the scan. No local set of malicious URLs, no hash-prefix table, no filter is described;
the matching work is the scan itself, not a lookup. So for "phishing / malicious URL
detection" there is nothing to transfer on the data-structure side. What does transfer is the
product shape — a per-URL verdict record with provenance — which is our per-domain list mask.

---

## 5. Memory layout, compact serialisation, zero-copy

This is the area with the most directly usable material.

### 5.1 The 2026 DNS-cache rewrite: 953 → 420 bytes per entry

<https://blog.cloudflare.com/dns-cache-memory-optimization-1111/>, 2026-08-27. Big Pineapple
holds "over 250 billion DNS cache entries"; five layout changes cut per-entry footprint by
56% and freed ~100 TB.

| Metric | Before | After | Change |
|---|---|---|---|
| per-entry net footprint | 953 B | 420 B | −56% |
| per-entry allocations | 1.1 KB | 461 B | −58% |
| insert throughput | 625,000/s | 893,000/s | +43% |
| lookup latency | 828 ns | 670 ns | −19% |
| p99 process RSS | 9.3 GB | 5.3 GB | −43% |
| p90 process RSS | 6.5 GB | 3.8 GB | −42% |

The five changes, in their order:

1. **`Vec<T>` → `Box<[T]>`** (and `String` → `Box<str>`): drop the capacity field (8 bytes
   each) and the over-reserved heap tail. 8 such fields per entry = 64 B/entry, "over 15
   terabytes" across the fleet.
2. **One list + `u16` offsets** instead of three section lists: 28 B/entry (two 8-byte
   pointer + 8-byte length pairs replaced by two 2-byte offsets). They note Rust padding
   means removing a small field can shrink the struct by more than the field size; they also
   pack booleans into a bitflag.
3. **Drop the owner name when it equals the query name** (`Option<Box<Name>>` = `None`,
   reconstructed from the cache key at read time). "Most records, however, have an owner
   identical to the queried domain."
4. **Box the large enum variants** (`Txt(Box<Txt>)`, `Naptr(Box<Naptr>)`) so an `A` record
   does not pay for the 136-byte NAPTR variant padded to a 144-byte enum. Saves ~120 B per
   A/AAAA record, which are >80% of traffic.
5. **Store record data as one `Box<[u8]>`** of 2-byte-length-prefixed raw records, written
   through a reusable scratch buffer and `memcpy`'d once. Contiguous, no per-record
   allocation, direct copy into the response for A/AAAA/TXT/DNSSEC. +13% insert throughput
   alone; −5% lookup latency.

Why they did *not* store the whole response in wire format: DNSSEC records are conditional
on the DO bit, so they would need two variants; and parsing on every lookup costs more than
the already-parsed struct.

**Exact?** N/A (it is a cache, not a set). **Transfers?** This is the best single source for
"same algorithm, 56% less memory". Mapping to `DomainSet`:

- "drop the repeated owner" ⇒ **deduplicate repeated name bytes** across sorted neighbours
  (front coding). Every `*.doubleclick.net` entry shares a 16-byte suffix; storing it 4,000
  times is the same waste as storing the query name in every record.
- "one list + `u16` offsets" ⇒ our `int[]` offsets are already the right shape; if the
  buffer is < 64 KiB per block, block-relative `u16` offsets halve the index.
- "`Box<[T]>` not `Vec<T>`" ⇒ in C#, never keep a `List<byte>`/`MemoryStream` with spare
  capacity alive; `ToArray()` at the end and drop the builder. A `List<byte>` with 2×
  capacity is 40 MiB of waste at our size.
- "length-prefixed raw records in one buffer" ⇒ exactly our blob, and a reason to keep the
  per-domain record as `[varint length][bytes]` rather than object-per-domain.

[INFERENCE] At 33–35 B/entry total and ~8.4 MiB of `int[]` offsets, the name bytes are the
dominant term (roughly 20–25 B/name). A 30–50% reduction in name bytes is therefore worth
roughly 15–25 MiB per full 23-list config — several times what the Bloom filter costs.

### 5.2 Packing a struct from 8 to 6 bytes: 25%, and 100 TB

<https://blog.cloudflare.com/saving-100-tb-of-ram-with-math/>, 2026-09-18. `pingora-ketama`
stored `struct Point { hash: u32, index: u32 }` = 8 bytes. The insight: the index never
needs 32 bits ("not likely to ever have to coordinate more than 2¹⁶ ≈ 65k servers"), so
`{ u32, u16 }` should be 6 bytes — but Rust alignment keeps it at 8. Solution: `struct
Point([u8; 6])` with getters, which "compile to the same thing" as `repr(packed)` without
the UB risk. Result: "reduces the amount of memory used for consistent hashing by a
whopping 25%". They also cut hashes per server by 90% after deriving the exact
coefficient-of-variation formula, and the combined change "dropped the used memory by 100TB".
Some processes were using 6 GB of ring points.

**Transfers?** Two lessons. (a) Check the *actual* width of every field: a `long` offset
where `int` suffices is 4 bytes × 2.29 M = 8.75 MiB. (b) Alignment/padding can silently
undo a width reduction; in C# `struct { uint; ushort; }` is 8 bytes with default layout
unless you use `[StructLayout(LayoutKind.Sequential, Pack = 1)]` or store parallel arrays.
We should use parallel arrays (`int[] offsets`, `uint[] masks`), which have no padding at all.

### 5.3 `mmap-sync` + BLISS: build in a second file, publish with one atomic word

<https://github.com/cloudflare/mmap-sync> and
<https://blog.cloudflare.com/scalable-machine-learning-at-cloudflare/>, 2023-06-19.

Design: one writer, many readers, two copies of the data in two memory-mapped files, plus a
third "state" file holding an atomic `InstanceVersion` = 1 bit active-file index + 39 bits
data size (up to 549 GB) + 24 bits checksum, and per-copy reader counters. Readers take a
guarded reference (RAII) that increments the counter; writers wait for the old copy's
readers to drain. `rkyv` gives zero-copy access to the struct, including `HashMap<u64,
Vec<f32>>`: "no data is copied during deserialization and no work is done to deserialize
data". The reader side is allocation-free (enforced with dhat).

Why mmap instead of a socket (their IPC benchmark: one million 1,024-byte messages, ping
pong):

| IPC method | Avg duration | Throughput |
|---|---|---|
| Unix domain socket | 5.609 µs | 177,573 msg/s |
| Pipe | 4.733 µs | 210,369 msg/s |
| Shared memory | 0.598 µs | 1,616,014 msg/s |
| **Memory-mapped file** | **0.503 µs** | **1,908,613 msg/s** |

Production result: ML feature fetch p50 532 → 9 µs, p99 9,510 → 18 µs, p999 16,000 → 29 µs;
overall request latency −12.5%, Bot Management module −55.93%.

**Exact?** N/A. **Transfers?** Strongly, for our reload problem. The pattern is exactly
"build the next immutable version off to the side, then flip one pointer". In C# the flip is
trivial (`Volatile.Write(ref _current, next)`); the interesting part is *where the bytes
live*: if the blob and offsets are in a read-only `MemoryMappedFile` view, they are
file-backed page cache, not anonymous memory. On a 1 GiB Pi that changes the failure mode
from OOM to reclaim. Two caveats: random reads from a cold SD-card-backed mapping are slow,
so warm it sequentially after the swap (and keep the old file until readers drain, which in
.NET means until no thread holds a span into it — easiest with a `ReaderWriterLockSlim`
around swaps, or by never freeing and letting the OS drop the mapping).

### 5.4 MessagePack and RRSet grouping: 9× less edge storage

<https://blog.cloudflare.com/how-we-made-our-dns-stack-3x-faster/>, 2017-04-11. Authoritative
DNS data pipeline: replaced JSON+protobuf with MessagePack generated from the Go structs,
and regrouped data so one query needs one KV read (one key per RRSet; A/AAAA/CNAME values
grouped under a single "address" key). "We actually reduced the space required to store the
data at the edge by around 9x", and average query handling got 3× faster across 6 M zones.

**Transfers?** Mostly confirmation: grouping values that are always read together (our
per-list name sets) and dropping schema bloat (per-domain objects) is where the big wins are,
not in the lookup algorithm.

### 5.5 The serde alternative they rejected

Same cache post: full wire-format storage was rejected because of the DO-bit variants and
per-lookup parsing. **Transfers?** For us: do not store the block list in a
self-describing/parse-on-read format. A `byte[]` + `int[]` with fixed semantics beats
anything that needs a parser at lookup time.

### 5.6 quiche-mallard: zero-copy tested in a fork, then upstreamed

<https://github.com/cloudflare/quiche-mallard>. The README states it "was a fork of
cloudflare/quiche to test new zero-copy and congestion control patches. These have been
merged upstream as of quiche 0.24. quiche-mallard is now considered deprecated and
archived." So the zero-copy work is real but lives in `quiche`, and the page gives no
numbers and no data-structure design. **Transfers?** Not the technique (packet-buffer
plumbing), but the process: prototype a risky memory change in a fork, measure, merge,
archive the fork. Nothing here for a domain set.

---

## 6. Master table

Structure / technique, what it is, the numbers the source gives, exactness, suffix support,
and whether it transfers. "—" means the source gives no number.

| # | Source (date) | Structure | Numbers reported | Exact | Suffix | Transfer |
|---|---|---|---|---|---|---|
| 1 | [Bloom post](https://blog.cloudflare.com/when-bloom-filters-dont-bloom/) (2020-03-02) | Bloom k=8, 128 MiB; 64-bit open-address table | 40 M lines: 12 s vs 4 s vs 2.1 s; k=1 needs 64 GiB; 0.7 probes; 1-in-23k collision | no | no | warning: filter must fit L3 |
| 2 | [Brotli dict](https://blog.cloudflare.com/brotli-compression-using-a-reduced-dictionary/) (2020-11-11) | radix trie + 4-byte hash + k=1 Bloom | 1 bit vs 16 B/prefix; rejects >half of misses; +1–3% CPU | yes (composite) | no | **high** (1-bit rejector) |
| 3 | [Quicksilver v1.5](https://blog.cloudflare.com/quicksilver-v2-evolution-of-a-globally-distributed-key-value-store-part-1/) (2025-07-10) | Bloom in RocksDB; Cuckoo evaluated | Bloom 6 GB vs Cuckoo 18 GB @5 B keys; 99% negative hits from RAM; keys 11× smaller than data | no | no | **medium** (Bloom≪cuckoo; key/value split) |
| 4 | [pingora-limits](https://blog.cloudflare.com/how-pingora-keeps-count/) (2023-05-12) | count–min sketch | 26,184 B vs 53.5 MB; 10 ns vs 51 ns; 1/2⁵² prod collision | no | no | principle only |
| 5 | [Pwned Passwords](https://blog.cloudflare.com/validating-leaked-passwords-with-k-anonymity/) (2018-02-21) | sorted hashes cut into prefix buckets | 16⁵ buckets; median 305/bucket; 8.6–16.8 KB responses | yes (client) | no | **medium** (sorted range + exact compare) |
| 6 | [trie-hard post](https://blog.cloudflare.com/pingora-saving-compute-1-percent-at-a-time/) (2024-09-10) | contiguous bitmask trie | 3.65→0.93 µs; 0.82%→0.34% CPU; `fst` +50 ns vs hashmap; O(log L) miss / O(L) hit; >90% misses | yes | no | **medium** (miss-first design) |
| 7 | [trie-hard repo](https://github.com/cloudflare/trie-hard) (n.d.) | nodes+children in flat vectors, bitmask + `count_ones` | ≤37 distinct bytes for `u32` (30 in practice); load 15.5 K words 11.92 ms vs 3.49 ms | yes | no | technique only |
| 8 | [BPF LPM trie](https://blog.cloudflare.com/a-deep-dive-into-bpf-lpm-trie-performance-and-optimization/) (2025-10-21) | 2-child radix over key bits, kmalloc nodes | 134.7 ns @10 K; ~1.5 M ops/s @1 M; dTLB bound @80 K; free 1.743 ms | yes | bit-prefix | **high** as a negative result |
| 9 | [Magic Firewall](https://blog.cloudflare.com/magic-firewall-optimizing-ip-lists/) (2022-03-29) | one shared eBPF LPM map vs per-namespace nftables sets | no byte numbers; "number of customers no longer predominant" | yes | no | **high** (share, don't copy) |
| 10 | [L4Drop](https://blog.cloudflare.com/l4drop-xdp-ebpf-based-ddos-mitigations/) (2018-11-28) | rules compiled to eBPF code, not maps | 8 M packets/s dropped; +10% CPU | yes | no | low |
| 11 | [WAF 40%](https://blog.cloudflare.com/making-the-waf-40-faster/) (2020-07-01) | PCRE→DFA regex; memoisation cache | no CPU delta at migration; memoisations 56%→74%, −40% time, −4.3% CPU; first regex cache "staggering" memory | yes | no | low (cache discipline) |
| 12 | [Firewall Rules](https://blog.cloudflare.com/how-we-made-firewall-rules/) (2019-03-04) | key lookup in Quicksilver | O(1); customers with "hundreds of thousands" of rules | yes | no | low |
| 13 | [wirefilter](https://blog.cloudflare.com/building-fast-interpreters-in-rust/) (2019-03-04) | `IndexMap`→fixed array for field dispatch | 2,548→1,227 ns matching (~2×) | yes | no | **medium** (small-int IDs) |
| 14 | [URLPattern](https://blog.cloudflare.com/improving-web-standards-urlpattern/) (2025-03-24) | 8 compiled regexes per pattern | — | yes | no | none |
| 15 | [Egress by hostname](https://blog.cloudflare.com/egress-policies-by-hostname/) (2025-07-07) | synthetic IP tags from `100.80.0.0/16` | 65,536 tags reused | yes | wildcard | low |
| 16 | [DNS cache 2026](https://blog.cloudflare.com/dns-cache-memory-optimization-1111/) (2026-08-27) | `Box<[T]>`, merged buffers, `u16` offsets, owner elision, length-prefixed raw records | 953→420 B/entry; −56% memory; +43% insert; −19% lookup; −100 TB | N/A | N/A | **highest** |
| 17 | [ketama packing](https://blog.cloudflare.com/saving-100-tb-of-ram-with-math/) (2026-09-18) | 8→6 byte struct, 90% fewer hashes | −25% ring memory; 6 GB procs; −100 TB | N/A | N/A | **high** (field width) |
| 18 | [mmap-sync](https://github.com/cloudflare/mmap-sync) / [BLISS](https://blog.cloudflare.com/scalable-machine-learning-at-cloudflare/) (2023-06-19) | mmap + rkyv + left-right swap | mmap IPC 0.503 µs vs UDS 5.609; p50 532→9 µs; p99 9,510→18 µs | N/A | N/A | **high** (reload) |
| 19 | [DNS stack 3×](https://blog.cloudflare.com/how-we-made-our-dns-stack-3x-faster/) (2017-04-11) | RRSet grouping + MessagePack | −9× edge storage; 3× query speed | N/A | N/A | medium |
| 20 | [IP Lists](https://blog.cloudflare.com/introducing-ip-lists/) (2020-07-22) | account-level named list, replicated | 1 list / 1,000 entries at launch | yes | no | low |
| 21 | [1.1.1.3 post-mortem](https://blog.cloudflare.com/the-mistake-that-caused-1-1-1-3-to-block-lgbtqia-sites-today/) (2020-04-02) | "compact data structure", prebuilt | build takes "several hours" | — | — | **the only direct evidence** |
| 22 | [entropy-map](https://github.com/cloudflare/entropy-map) (n.d.) | MPHF index + stored keys compared for equality | 2.10–2.71 bits/key of index; 5–20 ns/query | yes | per candidate | **medium** (study, §9 R7) |
| 23 | [wirefilter `RangeSet`](https://github.com/cloudflare/wirefilter) (n.d.) | `Box<[RangeInclusive<T>]>`, merged at build, binary search | — | yes | range only | **high** (same shape as ours) |
| 24 | [URL Scanner](https://blog.cloudflare.com/building-urlscanner) (2024-03-08) | scan-based verdict, no URL set | — | — | — | none |

---

## 6a. Source-level audit: GitHub, docs, research

### 6a.1 Organisation census

`https://api.github.com/orgs/cloudflare/repos?per_page=100` returned 100, 100, 100, 100,
100, 80 repositories for pages 1–6 (pages 7–8 empty): **580 public repositories**. I
filtered names and descriptions for `bloom|cuckoo|xor|filter|trie|fst|hash|lpm|radix|dns|
domain|host|rout|match|set|compact|table|zone|geo|rule|waf|list|search|index|mem`, then
checked every exact candidate from the brief against the full name list.

Repositories that do not exist (verified against that list, not guessed):

| Name looked for | Result |
|---|---|
| `cloudflare/flowtrack` | not present |
| `cloudflare/ipnet` | not present (`ipnet` is a third-party Rust crate) |
| `cloudflare/cuckoofilter`, `/bloomfilter`, `/fst`, `/mphf`, `/radix`, `/lpm` | not present |
| `cloudflare/trie-hard`, `/entropy-map`, `/mmap-sync`, `/wirefilter`, `/wildcard`, `/ahocorasick` | present |

The other `cloudflare*` orgs returned by `/search/users?q=cloudflare+type:org` are
`cloudflare-apps`, `cloudflarearchive`, `CloudflareHackers`, `Cloudflare-Studio`,
`cloudflare-casb`, `cloudflare-api`, `cloudflare-open-source`, `cloudflare-whatwg`,
`Cloudflare-Community`, plus unrelated third-party names. I checked `cloudflareresearch`
(11 repos: `doplar`, `poc-watermark`, `arc`, `vole-mole`, `unweight-kernels`, crypto
demos) — nothing on membership sets. The archive/apps orgs are historical product code, not
data-structure work, and were not read file by file.

### 6a.2 `entropy-map`: Cloudflare's exact perfect-hash set

<https://github.com/cloudflare/entropy-map> (Apache-2.0). This is the most relevant
artifact in the org for our problem, and it changes the "no perfect hashing" conclusion in
§7.

README, verbatim points:

- "ultra-low latency hash map Rust crate using minimal perfect hash functions (MPHF) and
  compact encoding of values".
- MPHF "memory usage ranging from `2.10 bits` to `2.71 bits` per key depending on
  parameters"; "query time ranging from `5 ns` to `20 ns` depending on the parameters,
  number of keys and L1-L3 cache sizes".
- Based on "Fingerprinting-based minimal perfect hashing revisited"
  (<https://doi.org/10.1145/3596453>); rank storage follows "Engineering Compact Data
  Structures for Rank and Select Queries on Bit Vectors"
  (<https://arxiv.org/pdf/2206.01149.pdf>); parameters: group size `B` (default 32 bits),
  seed range `2^S` (default `S=8`), seed type, `WyHash`, and a `gamma` that trades
  construction time against query time. Optional `rkyv` zero-copy serialization.

Source, `src/set.rs`:

```rust
pub struct Set<K, ...> { mphf: Mphf<...>, keys: Box<[K]> }
...
self.mphf.get(key).map(|idx| unsafe { self.keys.get_unchecked(idx) == key })
```

The doc comment states the design constraint exactly: "Keys are stored in the map to ensure
that queries for an item not in the set always fail." Construction collects the keys,
builds the MPHF, then reorders the key array into MPHF order with in-place swaps, so a built
set is a dense `keys[0..n]` array addressed by the hash.

Compare with `DomainSet`: they pay **2.1–2.7 bits/key** for an O(1) index and store the keys
in hash order; we pay **32 bits/key** for `int` offsets and store them in sort order. For
2.29 M keys the MPHF is ~0.6–0.8 MiB against ~8.75 MiB of offsets, so an MPHF variant would
save ~8 MiB and remove the binary search — but it destroys the sorted order that makes
front-coding possible (§9 R1), and `mphf.rs` is 650 lines plus a rank/select structure, far
over our 300-line budget. Ranked as "study, do not port" (§9 R7).

The README does not say where (or whether) this runs in production. **UNVERIFIED** as a
deployed system.

### 6a.3 `wirefilter`: the list is a trait, and `RangeSet` is a sorted array

<https://github.com/cloudflare/wirefilter>.

- `engine/src/list_matcher.rs`: a list in the rules language is an opaque
  `trait ListMatcher: ... + Serialize`, with `AlwaysList`/`NeverList` implementations and a
  `ListDefinition` registered in the `Scheme`. **The engine does not own the set
  representation**; the embedding service supplies the matcher. This is the structural
  reason no Cloudflare post describes the WAF's list storage: it lives outside the
  open-source engine, in the service that implements the trait.
- `engine/src/rhs_types/list.rs`: `pub struct ListName(Box<str>)` — a boxed slice, not a
  `String`, the same capacity-elision trick the 2026 cache post measures.
- `engine/src/range_set.rs`, complete design in ~50 lines:

```rust
pub struct RangeSet<T> { ranges: Box<[RangeInclusive<T>]> }
// build: ranges.sort_unstable_by_key(|r| *r.start());
//        ranges.dedup_by(|b, a| if b.start() <= a.end() { merge; true } else { false });
// lookup:
self.ranges.binary_search_by(|range| {
    if range.start().borrow() > value { Ordering::Greater }
    else if range.end().borrow() >= value { Ordering::Equal }
    else { Ordering::Less }
}).is_ok()
```

That is exact, allocation-free at lookup, O(log n), and the closest published *source*
shape to our sorted-offset blob. It is used for IP ranges in rules (`ip.src in {...}`), not
for names, but it shows Cloudflare's own answer to "immutable set, compact, exact" is the
same one we chose.
- `engine/src/searcher.rs`: substring prefilters are `memchr::memmem::Finder` or a
  `sliceslice::MemchrSearcher`; a cheap exact rejector in front of the expensive matcher.
  The same layering as Brotli's k=1 Bloom and our Bloom front end.

### 6a.4 `pingora`: what is actually in the open repository

<https://github.com/cloudflare/pingora>.

- `pingora-ketama/src/lib.rs`: `struct PointV1 { node: u32, hash: u32 }` and
  `#[repr(transparent)] struct PointV2([u8; 6])` with `hash()`/`index()` getters — the 25%
  packing win from the 2026 post is visible in source, including the comment explaining why
  `repr(packed)` was avoided.
- `pingora-load-balancing/src/selection/weighted.rs`: `assert!(backends.len() <=
  u16::MAX as usize, "support up to 2^16 backends")` — the source-level justification for
  the `u16` index.
- `pingora-limits/src/estimator.rs`: `pub struct Estimator { estimator:
  Box<[(Box<[AtomicIsize]>, RandomState)]> }` — the CM sketch, one boxed row per hash,
  lock-free.
- `tinyufo/src/estimation.rs`: a second, `u8`-counter CM sketch with ageing, used by the
  TinyLFU cache-admission policy. Two independent CM sketches in one repo.
- **No `trie_hard`, no Bloom filter, no radix tree anywhere in the open repo.** The
  `trie-hard` caller (`pingora-origin`) is not open source; searching the tree for
  `trie|bloom|radix` yields only substring hits inside "retrieve". Do not claim that the
  open-source Pingora uses a trie.

### 6a.5 Smaller repos, read for completeness

| Repo | What it is | Memory / exactness |
|---|---|---|
| `cloudflare/ahocorasick` | Go Aho-Corasick (2013). `node` has `child [256]*node` and `fails [256]*node`, plus a preallocated contiguous `trie []node` | Exact substring matching. The fixed 256-entry child and fail arrays cost ≈4 KiB of pointers per node on 64-bit; the source itself says "space-inefficient but fast for lookups". A cautionary data point for any node-per-character trie (§9 R5) |
| `cloudflare/wildcard` | `no_std` Rust `*`/`?` matcher, single 49 KB `lib.rs`, byte-slice `is_match`/`captures` | Exact per-pattern match; no set, no index, memory proportional to pattern length |
| `cloudflare/go-ipfs-blocklist` | "thin wrapper over a datastore" for CIDs | No in-memory structure at all; the blocklist is whatever the datastore is |
| `cloudflare/foundations` | Service scaffolding (telemetry, settings, seccomp) | Only `HashSet` for log-field dedup/redaction (`field_dedup.rs`, `field_redact.rs`); `ahash` is an optional dependency. Nothing relevant |
| `cloudflare/quiche-mallard` | "quiche fork with congestion & zero-copy patches" | Zero-copy here is packet-buffer handling, not set storage |
| `cloudflare/lol-html`, `cloudflare/workerd` | Streaming HTML rewriter; JS/Wasm runtime | Not set/trie work; `workerd`'s URLPattern is the regex compilation described in §4.3 |

### 6a.6 Documented limits: the scale the list products admit to

Public limits are the only official hint at what Cloudflare's *list-object* path is built
for, and they show that the large category feeds are not served through those objects.

| Product | Limit | Source |
|---|---|---|
| Zero Trust / Gateway lists | 100 lists per account | <https://developers.cloudflare.com/cloudflare-one/account-limits/> |
| Entries per Gateway list | 1,000 (Standard), 5,000 (Enterprise) | same page |
| Gateway list CSV upload | smaller than 2 MB | <https://developers.cloudflare.com/cloudflare-one/reusable-components/lists/> |
| Gateway list hostnames | **no wildcards** — "add domains as exact matches" | same page |
| Gateway lists API | 600 requests/minute | same page |
| Gateway DNS policies | 500 per account | account limits |
| Gateway policy expression | 140,000 characters | account limits |
| WAF custom lists | IP, hostname (wildcard `*.example.com` allowed), ASN | <https://developers.cloudflare.com/waf/tools/lists/custom-lists/> |
| WAF IP list ranges | IPv4 `/8`–`/32`, IPv6 `/12`–`/128`, mixed with single IPs | same page |
| Tunnel routes (CIDR + hostname) | 50,000 per account | account limits |
| Access `Domains per application` | 50 | account limits |

Two readings. (a) A 5,000-entry exact-hostname list with no wildcards cannot express a
2 M-domain block list, so the category and phishing sets must be a separate internal
artifact — consistent with the "compact data structure" of §2.2. (b) The WAF's hostname
lists *do* accept `*.example.com`, so that path must do suffix matching, but the matcher is
the opaque `ListMatcher` of §6a.3; the representation is not public.

### 6a.7 Research site and talks

<https://research.cloudflare.com/>, `/focus/fast` (13 publications), `/focus/measurable`
(8 publications), `/presentations`. Titles include Valet (SSD data placement), Kneeliverse
(knee detection for performance curves), "Rethinking Web Cache Design for the AI Era",
Unweight (lossless MLP weight compression), KEMTLS, "Post-quantum TLS without handshake
signatures", "403 Forbidden: a global view of CDN geoblocking", and Merkle Tree
Certificates. **None concerns membership sets, tries, hash indexes, learned indexes or
compact lookup tables.** The nearest thing to compactness is Unweight, which is neural
network weight compression, not lookup. The talks linked from the engineering posts are
about interpreters (wirefilter) and QUIC/TLS, not data structures.



## 7. What Cloudflare does *not* publish

State this plainly in the upstream proposal, so we are not accused of borrowing a design
that does not exist:

- **No DNS block-list data structure.** No post names the structure used for Families or
  Gateway categories, or gives bytes per domain. §2.2 is the entire public record.
- **Perfect hashing exists as a crate, but is not written up as production.** The org has
  `cloudflare/entropy-map` (§6a.2), an MPHF-based exact set, with README figures of
  2.10–2.71 bits/key and 5–20 ns queries. There is **no blog post** about it, no claim that
  it is deployed, and no `CHD`, `RecSplit` or other MPHF family in the org. So: published
  code, unstated production use. Do not write "Cloudflare uses perfect hashing in
  production"; do write "Cloudflare publishes an MPHF set whose index costs ~2.4 bits/key".
- **No FST-based set.** The only `fst` reference is a benchmark in the `trie-hard` post,
  where the crate was ~50 ns *slower* than a `HashMap` for their key set. No Cloudflare
  post describes building or using a finite-state transducer.
- **No cuckoo/xor filter in production.** Cuckoo is mentioned exactly once, as an evaluated
  and rejected alternative in Quicksilver (18 GB vs 6 GB). No xor filter anywhere.
- **No authoritative-DNS zone trie.** The authoritative server is Go `rrDNS`; the posts
  describe the *data model* (RRSet grouping, MessagePack) and say the authoritative filter
  "look[s] up the zone the query name belongs to", but not how. I found no zone-name suffix
  structure published.
- **No Rust authoritative DNS.** `rrDNS` is Go (2013, rewritten filter 2016–17). The Rust
  DNS work is the recursive resolver / Big Pineapple. `quiche` is QUIC and has nothing on
  set membership.
- **No published memory number for a block list**, at any scale, ever.

---

## 8. Judging the transferable ideas against our constraints

Constraints: exact, per-list attribution, suffix lookup, one-pass build with low peak memory,
plain C# under 300 lines, no NuGet, latency near `HashSet`.

| Idea | Exact | Per-list | Suffix | Build / peak | C# <300 lines | Verdict |
|---|---|---|---|---|---|---|
| Block front-coding of sorted names | yes | yes (mask array) | yes (binary search unchanged) | one pass; sort then emit | ~100 | **try first** |
| Merge 21–23 sets into one blob + `uint` mask | yes | yes | yes | one pass | ~150 | **try**, bigger change |
| k=1 2 MiB bit filter in front | yes (filter only) | irrelevant | per candidate | one extra pass | ~40 | **try**, cheap |
| Drop the Bloom entirely | yes | yes | yes | simpler | −20 | **measure** on target |
| mmap the blob, build to a new file | yes | yes | yes | build in file, not heap | ~120 | **try** for peak/RSS |
| Pointer/bitmask trie (`trie-hard` style) | yes | yes | needs reversal | many nodes, bulk load | ~250 | **no** (alphabet >32, node count) |
| 64-bit hash index | no | yes | yes | one pass | ~60 | **no** (rejected: 103.1 MiB measured here) |
| Cuckoo / xor filter | no | no | no | — | — | **no** (Quicksilver: 3× Bloom) |
| CM sketch | no | no | no | — | — | **no** (counts, not membership) |
| FST | yes | yes | prefix only | complex build | >300 | **no** (and Cloudflare measured it slower) |
| Perfect hashing (`entropy-map`) | yes (keys kept and compared) | yes (index → mask array) | yes per candidate, but no range order | full key set, then reorder | ~650+ (MPHF + rank/select) | **no**: over line budget, and destroys front-coding |
| Synthetic-IP tagging | n/a | n/a | n/a | — | — | **no** (different layer) |
| WAF/URLPattern regex matching | yes | n/a | n/a | — | — | **no** (wrong shape) |

Notes on the rejections:

- **Hash index.** Our own measurement already covers this: the open-addressing index costs
  103.1 MiB vs 84.0 MiB sorted-only and is 0.4% p50, i.e. no better. Cloudflare's 2020 post
  explains why (hashing reads every byte; the table adds a random access without removing
  the string compare). It would only win if we dropped exactness.
- **Perfect hashing.** `entropy-map` shows the exact form: an MPHF index plus stored keys
  compared for equality. It does support suffix lookup (each candidate is hashed
  independently) and it needs the full key set, which we have. What it destroys is order, so
  it cannot be combined with front-coding and cannot answer a range; and the MPHF plus
  rank/select is ~650 lines. Rejected on line budget and because compression (§9 R1) offers a
  larger win than the ~8 MiB of offsets it would save (§9 R7).
- **Trie.** The alphabet problem is decisive: `trie-hard`'s `u32` mask relies on ≤32 distinct
  bytes and their production set used 30. DNS names use 38–39 (a–z, 0–9, `-`, `.`, and `_`
  in some lists), so the mask becomes `u64` and the node metadata doubles. And the node count
  is the killer: a byte-per-node trie without path compression is ~40 M nodes for 2.29 M
  names; with compression it is a sorted array with worse cache behaviour. The *useful*
  residue is the miss-first insight, which our Bloom front end already exploits.

---

## 9. Ranked: what is worth trying, and the smallest C# version

Ranked by expected bytes saved per unit of risk. All of these keep `DomainSet`'s exactness
and the public contract; none needs a package.

### R1. Block front-coding of the sorted name blob — biggest byte win

**Idea (from the 2026 cache post's "drop the repeated owner" + "length-prefixed raw records
in one buffer", with the FST/sorted-block layout as the algorithmic form):** keep one
sorted `byte[]`, but store names in blocks of 16–32 entries. The first name of a block is
stored whole; each following name is stored as `(sharedPrefixLen, suffixLen, suffixBytes)`
against the previous name in the block. Sorted order means neighbours share long prefixes
(`ads.`, `track.`, `metrics.`), and dedup across lists means the same name appears once.

Lookup: binary search over block-first names (only 1/16 of the decode work), then one
sequential decode of ≤32 entries into a 255-byte stack buffer. Suffix lookup is unchanged:
for each candidate (`a.b.example.net`, `b.example.net`, …) do one `Contains`. Per-list
attribution: a parallel `uint[] masks` indexed by entry, or 3-byte packed if we want the
last 15%.

Build: parse all lists into one arena (`byte[]` grown by doubling) plus `int[] starts` and
`byte[] listIds`; sort `int[] order` with `Comparison<int>` comparing arena slices (no
`string` allocation, no comparer object per element); emit blocks sequentially, OR-ing
masks for equal names. Peak = arena + order + listIds + output ≈ 50 + 10 + 3 + 30 MiB ≈
93 MiB for the current config [INFERENCE from our 2.67 M entries and ~20–25 B/name], versus
the current ~2×89 MiB build. This directly attacks both the steady-state bytes and the
reload peak.

Risk: one extra decode per probe; measure p50 on the A53. Mitigation: keep blocks at 16
entries so a block is one or two cache lines.

[INFERENCE] Expected saving: 30–50% of the name bytes, i.e. roughly 15–25 MiB per full
23-list config if names dominate as the 33–35 B/entry total suggests. Not measured.

**Smallest C# version (~100 lines):**

```csharp
sealed class DomainBlob
{
    private const int BlockShift = 4, BlockSize = 1 << BlockShift;
    private readonly byte[] _data;      // concatenated blocks
    private readonly int[] _blockAt;    // _data offset of each block, ascending
    private readonly uint[] _mask;      // per entry, parallel to decoded order

    public bool Contains(ReadOnlySpan<byte> key, out uint lists)
    {
        int lo = 0, hi = _blockAt.Length - 1;
        Span<byte> buf = stackalloc byte[256];
        while (lo < hi)                      // last block whose first name <= key
        {
            int mid = (lo + hi + 1) >> 1;
            int n = Decode(_blockAt[mid], buf, default);
            if (buf[..n].SequenceCompareTo(key) <= 0) lo = mid; else hi = mid - 1;
        }
        int p = _blockAt[lo], end = lo + 1 < _blockAt.Length ? _blockAt[lo + 1] : _data.Length;
        int len = Decode(p, buf, default); p += EncodedLength(p);
        int entry = lo * BlockSize;
        while (true)
        {
            int cmp = buf[..len].SequenceCompareTo(key);
            if (cmp == 0) { lists = _mask[entry]; return true; }
            if (cmp > 0 || p >= end) break;
            len = Decode(p, buf, buf[..len]);   // prefix-extend previous
            p += EncodedLength(p);
            entry++;
        }
        lists = 0; return false;
    }
    // Decode: varint shared, varint suffixLen, suffix bytes appended to `prev`.
}
```

(The real file needs `EncodedLength` and the builder; both are mechanical. Keep the arena
and the sorted `int[] order` as locals in `Build` so they die before the blob is published.)

### R2. One shared blob + per-domain list mask — the structural win

**Idea (Magic Firewall: one shared map beats N per-tenant copies; Quicksilver: key/value
separation):** instead of 23 independent `DomainSet`s (44 sets counting adblock allow/deny),
build one sorted blob of 2.29 M unique names with a `uint` mask per name. A query does at
most ~5 suffix probes total instead of ~5 × 44, and one negative result rules out every
list at once. Our own measurement of the merged compact index is 64 MiB, which is already
below the 84–89 MiB of the per-list structure; R1 composes with it.

Cost: the attribution API changes from "set identity" to "mask", and the adblock allow/deny
pairs need either two masks (allow, block) or two merges. That is the "large architecture
change" already identified. Do R1 inside one set first; then decide.

### R3. Replace the Bloom with a 2 MiB k=1 bit filter (or delete it)

**Idea (Brotli: 1 bit per 4-byte prefix rejects >half of misses with one access; Bloom post:
a filter bigger than L3 is worse than a hash probe):** today the filter is 5.3 MiB of
`anon` and its benefit is inside amd64 noise. On the Pi, L3 is 512 KiB–2 MiB, so 5.3 MiB is
already outside it. Try, in order:

1. **Delete it** and measure p50/qps on the A53 (the sorted-only build already exists and
   measured +6.9% p50, −5.8% qps on amd64 — that is the cost of no filter).
2. **2 MiB single-bit filter**: one 32-bit hash of the candidate name, one bit test into a
   2 MiB `ulong[]`. At 2.29 M keys in 16.7 M bits the load factor is 13.7%, so it rejects
   ~86% of negatives with one access that fits L2/L3. This is strictly cheaper per probe
   than k=8 Bloom (8 accesses) and 2.6× smaller.
3. If the filter stays multi-hash, cap it at 1–2 MiB rather than sizing for 1% FPR.

The filter remains a pure pre-filter: a false positive falls through to the exact search, so
exactness is untouched.

### R4. mmap the blob and offsets; build the next version in a second file

**Idea (mmap-sync left-right + BLISS zero-copy):** put `_data`, `_blockAt` and `_mask` in a
read-only `MemoryMappedFile` view (`CreateViewAccessor` + `AcquirePointer`, wrap in
`ReadOnlySpan<byte>` via `new ReadOnlySpan<byte>(ptr, len)`), and rebuild into
`name.next` then rename/swap. Anonymous RSS for the block lists drops to near zero; the
pages become reclaimable page cache. On a 1 GiB device that is the difference between OOM
and reclaim, and it also means the reload peak is file pages rather than GC heap.

Caveats: random first-touch on SD storage is slow (warm sequentially once after swap);
`MemoryMappedFile` has no `madvise`, so the OS decides; and readers must not hold a span
across a swap — use a `ReaderWriterLockSlim` for the swap (readers take the read lock only
to fetch the span, then copy nothing, so the lock is held for the duration of the lookup) or
an `Interlocked` epoch counter if the lock shows up in profiles.

This is the only idea here that changes the *accounting category* of the memory rather than
its size, which is why it ranks above anything that saves a few MiB.

### R5. Do not build a trie, a hash index, or an FST

Reasons in §8. In particular, `trie-hard` is the wrong tool for a 38-symbol alphabet and
2.29 M keys; `cloudflare/ahocorasick` shows why a node-per-character trie is worse than it
looks (256-way child and fail pointer arrays, ≈4 KiB per node); and the `trie-hard` post's
own author reports the `fst` crate losing to `HashMap` on their much smaller key set.

### R6. Micro: intern list IDs, use parallel arrays, drop `long`

**Idea (wirefilter's `IndexMap`→array 2×; ketama's 8→6 bytes):** no `Dictionary<string,int>`
on the lookup path; `int`/`uint` list IDs; `int[]` offsets (not `long`); `uint[]` masks (not
`Dictionary<int, …>`); no `List<T>` with spare capacity surviving the build. Each of these
is a few MiB, and together they are the difference between 89 MiB and the 57.8 MiB target.

### R7. Considered, not recommended: `entropy-map`-style MPHF

**Idea (Cloudflare's only exact set artifact with a per-key cost):** replace the sorted
offsets with a minimal perfect hash: `mphf(name)` gives an index, `keys[index] == name`
proves membership, and the index addresses a parallel `uint` mask array. At 2.29 M keys the
index is ~0.6–0.8 MiB instead of ~8.75 MiB of `int` offsets, and lookup drops from ~2–3
cache-line probes to one hash plus one compare (5–20 ns in Cloudflare's README).

Why not now: (a) implementing fingerprinting MPHF plus rank/select is ~650 lines in Rust
before the set wrapper, so it cannot fit the 300-line budget; (b) it requires reordering
keys by hash, which kills the sorted order that R1's front-coding depends on, so it is an
alternative to R1, not an addition; (c) the win is ~8 MiB, while R1 targets 15–25 MiB.
Revisit only if the line budget grows or if lookup latency, not memory, becomes the
constraint.

---

## 10. What I could not find, and unverified items

- **The actual Families/Gateway block-list structure.** Not published. The 1.1.1.3
  post-mortem is the only source and it stops at "compact data structure".
- **A published cache-key or URL-reputation set structure.** Cache keys are documented as an
  identifier template — "an identifier that Cloudflare uses for a file in our cache",
  defaulting to scheme + host + URI with query string, plus optional headers and cookies
  (<https://developers.cloudflare.com/cache/how-to/cache-keys/>) — not as a compact set.
  URL reputation is produced by scanning (§4.7). Neither page describes a lookup structure.
- **Any Cloudflare memory number for a domain set.** None, at any scale.
- **A Cloudflare post on perfect hashing, xor filters, or an FST in production.** No post.
  Perfect hashing exists only as the `entropy-map` crate (§6a.2); the `fst` crate appears
  only as a losing benchmark.
- **An authoritative-DNS zone-suffix structure.** Not published; `rrDNS` is Go and the posts
  cover the data model, not the lookup.
- **Rust authoritative DNS.** Does not exist publicly; the Rust work is the recursive
  resolver (Big Pineapple) and `quiche`.
- **MIGP details** (<https://blog.cloudflare.com/privacy-preserving-compromised-credential-checking/>):
  seen only as a search result, not opened. **UNVERIFIED.**
- **Cloudflare's `tubular` LPM encoding** (<https://blog.cloudflare.com/tubular-fixing-the-socket-api-with-ebpf/>):
  seen only as a search result, not opened. **UNVERIFIED**, therefore not used above.
- **The 2026 cache post's "several hundred trillion" style claims** are quoted as given; I
  did not attempt to reproduce any benchmark.

## 11. One-paragraph answer for the proposal

Cloudflare has published no DNS block-list structure, so there is no Cloudflare design to
copy. The only exact-set artifact in their public org is `entropy-map`, an MPHF set whose
index costs 2.10–2.71 bits/key — unexplained by any post and with no stated production use.
What they have published in prose that bears on our problem is a set of measured layout and
access-pattern lessons: Bloom filters are only worth their accesses while they fit in L3
(2020); a 64-bit hash table beat a 128 MiB Bloom on 40 M keys (2020); a Bloom is 3× smaller
than a cuckoo filter at equal FPR (2025); a contiguous bitmask trie beats `HashMap` only
when misses dominate and the alphabet is tiny (2024); pointer tries collapse on dTLB once
they pass ~80 K entries (2025); and the same DNS cache got 56% smaller by eliding repeated
strings, merging buffers, using `u16` offsets and storing raw length-prefixed records in one
`Box<[u8]>` (2026). The transferable program for us is therefore: front-code the sorted name
blob, collapse the 23 per-list sets into one shared blob with a per-name bitmask, shrink or
delete the Bloom, and move the artifact into a file-backed mapping that is rebuilt beside
the live one and swapped atomically. None of that needs a new dependency or more than a few
hundred lines of C#.

---

## 12. Coverage table

### A. Blog tag sweep

The tag pages render only the latest 18 posts each; the eleven tags below produced 167
unique posts, listed with the relevance verdict I applied to the title (and, for the "yes"
rows, to the full text). The `cuckoo` and `bloom` tag pages **do not exist** — both return
`Page Not Found` — which is itself evidence that Cloudflare has no Bloom/cuckoo tag and no
dedicated post series on either.

| Date | Title | Slug | Relevant? |
|---|---|---|---|
| December 5, 2017 | Introducing the Cloudflare Warp Ingress Controller for Kubernetes | /cloudflare-ingress-controller/ | no |
| June 7, 2017 | How we built rate limiting capable of scaling to millions of domains | /counting-things-a-lot-of-different-things/ | partial: counters at domain scale |
| September 10, 2017 | Delivering Dot | /f-root/ | no |
| July 4, 2018 | Too Old To Rocket Load, Too Young To Die | /too-old-to-rocket-load-too-young-to-die/ | no |
| June 1, 2018 | We have lift off - Rocket Loader GA is mobile! | /we-have-lift-off-rocket-loader-ga-is-mobile/ | no |
| May 14, 2019 | Parallel streaming of progressive images | /parallel-streaming-of-progressive-images/ | no |
| May 15, 2019 | Announcing Cloudflare Image Resizing: Simplifying Optimal Image Delivery | /announcing-cloudflare-image-resizing-simplifying-optimal-image-delivery/ | no |
| December 18, 2020 | Computing Euclidean distance on 144 dimensions | /computing-euclidean-distance-on-144-dimensions/ | partial: 144-byte hashes |
| March 2, 2020 | When Bloom filters don't bloom | /when-bloom-filters-dont-bloom/ | yes: Bloom vs hash table |
| November 11, 2020 | My internship: Brotli compression using a reduced dictionary | /brotli-compression-using-a-reduced-dictionary/ | yes: k=1 Bloom + trie |
| October 3, 2020 | Introducing support for the AVIF image format | /generate-avif-images-with-image-resizing/ | no |
| July 1, 2022 | Optimizing TCP for high WAN throughput while preserving low latency | /optimizing-tcp-for-high-throughput-and-low-latency/ | no |
| May 10, 2022 | A new era for Cloudflare Pages builds | /cloudflare-pages-build-improvements/ | no |
| April 18, 2023 | Making home Internet faster has little to do with "speed" | /making-home-internet-faster/ | no |
| January 9, 2023 | Cloudflare is faster than Zscaler | /network-performance-update-cio-edition/ | no |
| June 20, 2023 | Faster website, more customers: Cloudflare Observatory can help your busin | /cloudflare-observatory-generally-available/ | no |
| June 20, 2023 | INP. Get ready for the new Core Web Vital | /inp-get-ready-for-the-new-core-web-vital/ | no |
| June 21, 2023 | Spotlight on Zero Trust: we're fastest and here's the proof | /spotlight-on-zero-trust/ | no |
| June 22, 2023 | Benchmarking dashboard performance | /benchmarking-dashboard-performance/ | no |
| June 23, 2023 | How we scaled and protected Eurovision 2023 voting with Pages and Turnstil | /how-cloudflare-scaled-and-protected-eurovision-2023-voting/ | no |
| June 23, 2023 | Introducing the Cloudflare Radar Internet Quality Page | /introducing-radar-internet-quality-page/ | no |
| March 15, 2023 | Using the power of Cloudflare's global network to detect malicious domains | /threat-detection-machine-learning-models/ | no |
| March 17, 2023 | Cloudflare Access is the fastest Zero Trust proxy | /network-performance-update-security-week-2023/ | no |
| September 25, 2023 | Cloudflare Fonts: enhancing website font privacy and speed | /cloudflare-fonts-enhancing-website-privacy-speed/ | no |
| September 28, 2023 | Race ahead with Cloudflare Pages build caching | /race-ahead-with-build-caching/ | no |
| December 27, 2024 | What's new in Cloudflare: MASQUE now powers 1.1.1.1 & WARP apps, DEX now g | /masque-now-powers-1-1-1-1-and-warp-apps-dex-available-with-remote-captures/ | no |
| December 30, 2024 | Open sourcing h3i: a command line tool and library for low-level HTTP/3 te | /h3i/ | no |
| July 25, 2024 | Making WAF ML models go brrr: saving decades of processing time | /making-waf-ai-models-go-brr/ | no |
| July 4, 2024 | Cloudflare 1.1.1.1 incident on June 27, 2024 | /cloudflare-1111-incident-on-june-27-2024/ | no |
| June 11, 2024 | Heeding the call to support Australia's most at-risk entities | /heeding-the-call-to-support-australias-most-at-risk-entities/ | no |
| March 8, 2024 | Protocol detection with Cloudflare Gateway | /gatway-protocol-detection/ | no |
| May 14, 2024 | Cloudflare's public IPFS gateways and supporting Interplanetary Shipyard | /cloudflares-public-ipfs-gateways-and-supporting-interplanetary-shipyard/ | no |
| November 8, 2024 | How we prevent conflicts in authoritative DNS configuration using formal v | /topaz-policy-engine-design/ | partial: DNS config verification |
| October 22, 2024 | Building Vectorize, a distributed vector database, on Cloudflare's Develop | /building-vectorize-a-distributed-vector-database-on-cloudflare-developer-platform/ | no |
| October 23, 2024 | Training a million models per day to save customers of all sizes from DDoS | /training-a-million-models-per-day-to-save-customers-of-all-sizes-from-ddos/ | no |
| October 25, 2024 | Elephants in tunnels: how Hyperdrive connects to databases inside your VPC | /elephants-in-tunnels-how-hyperdrive-connects-to-databases-inside-your-vpc-networks/ | no |
| October 29, 2024 | Migrating billions of records: moving our active DNS database while it's i | /migrating-billions-of-records-moving-our-active-dns-database-while-in-use/ | yes: A/B cutover |
| October 9, 2024 | What's new in Cloudflare One: Digital Experience (DEX) monitoring notifica | /roundup-dex-alerts-cloudflare-gateway-china-express/ | no |
| September 10, 2024 | A good day to trie-hard: saving compute 1% at a time | /pingora-saving-compute-1-percent-at-a-time/ | yes: trie-hard/FST numbers |
| September 24, 2024 | Cloudflare partners with Internet Service Providers and network equipment | /safer-resolver/ | no |
| September 30, 2024 | Wrapping up another Birthday Week celebration | /birthday-week-2024-wrap-up/ | no |
| April 10, 2025 | Sequential consistency without borders: how D1 implements global read repl | /d1-read-replication-beta/ | no |
| April 11, 2025 | A next-generation Certificate Transparency log built on Cloudflare Workers | /azul-certificate-transparency-log/ | no |
| April 2, 2025 | A steam locomotive from 1993 broke my yarn test | /yarn-test-suffers-strange-derailment/ | no |
| April 8, 2025 | Pools across the sea: how Hyperdrive speeds up access to databases and why | /how-hyperdrive-speeds-up-database-access/ | no |
| August 25, 2025 | Beyond the ban: A better way to secure generative AI applications | /ai-prompt-protection/ | no |
| August 28, 2025 | A deeper look at AI crawlers: breaking down traffic by purpose and industr | /ai-crawler-traffic-by-purpose-and-industry/ | no |
| August 28, 2025 | The next step for content creators in working with AI bots: Introducing AI | /introducing-ai-crawl-control/ | no |
| August 28, 2025 | The age of agents: cryptographically recognizing agent traffic | /signed-agents/ | no |
| August 29, 2025 | The crawl-to-click gap: Cloudflare data on AI bots, training, and referral | /crawlers-click-ai-bots-training/ | no |
| December 11, 2025 | React2Shell and related RSC vulnerabilities threat brief: early exploitati | /react2shell-rsc-vulnerabilities-exploitation-threat-brief/ | no |
| December 15, 2025 | ChatGPT's rivals, Kwai's quiet rise: the top Internet services of 2025 | /radar-2025-year-in-review-internet-services/ | no |
| December 18, 2025 | Announcing support for GROUP BY, SUM, and other aggregation queries in R2 | /r2-sql-aggregations/ | no |
| February 14, 2025 | Searching for the cause of hung tasks in the Linux kernel | /searching-for-the-cause-of-hung-tasks-in-the-linux-kernel/ | no |
| February 27, 2025 | Some TXT about, and A PTR to, new DNS insights on Cloudflare Radar | /new-dns-section-on-cloudflare-radar/ | no |
| February 4, 2025 | No hallucinations here: track the latest AI trends with expanded insights | /expanded-ai-insights-on-cloudflare-radar/ | no |
| January 27, 2025 | Over 700 million events/second: How we make sense of too much data | /how-we-make-sense-of-too-much-data/ | no |
| January 3, 2025 | Multi-Path TCP: revolutionizing connectivity, one path at a time | /multi-path-tcp-revolutionizing-connectivity-one-path-at-a-time/ | no |
| July 15, 2025 | Cloudflare 1.1.1.1 incident on July 14, 2025 | /cloudflare-1-1-1-1-incident-on-july-14-2025/ | no |
| July 24, 2025 | Serverless Statusphere: a walk through building serverless ATProto applica | /serverless-atproto/ | no |
| July 7, 2025 | Introducing simple and secure egress policies by hostname in Cloudflare's | /egress-policies-by-hostname/ | yes: wildcard hostname match |
| March 17, 2025 | Conventional cryptography is under threat. Upgrade to post-quantum cryptog | /post-quantum-zero-trust/ | no |
| November 3, 2025 | Fresh insights from old data: corroborating reports of Turkmenistan IP unb | /fresh-insights-from-old-data-corroborating-reports-of-turkmenistan-ip/ | no |
| November 7, 2025 | DIY BYOIP: a new way to Bring Your Own IP prefixes to Cloudflare | /diy-byoip/ | no |
| October 16, 2025 | Improving the trustworthiness of Javascript on the Web | /improving-the-trustworthiness-of-javascript-on-the-web/ | no |
| October 21, 2025 | A deep dive into BPF LPM trie performance and optimization | /a-deep-dive-into-bpf-lpm-trie-performance-and-optimization/ | yes: LPM trie, dTLB wall |
| October 27, 2025 | From .com to .anything: introducing Top-Level Domain (TLD) insights on Clo | /introducing-tld-insights-on-cloudflare-radar/ | no |
| October 27, 2025 | How does Cloudflare's Speed Test really work? | /how-does-cloudflares-speed-test-really-work/ | no |
| October 28, 2025 | Keeping the Internet fast and secure: introducing Merkle Tree Certificates | /bootstrap-mtc/ | no |
| October 29, 2025 | One IP address, many users: detecting CGNAT to reduce collateral effects | /detecting-cgn-to-reduce-collateral-damage/ | no |
| October 30, 2025 | Beyond IP lists: a registry format for bots and agents | /agent-registry/ | yes: list/registry format |
| October 30, 2025 | Anonymous credentials: rate-limiting bots and agents without compromising | /private-rate-limiting/ | no |
| October 8, 2025 | How we found a bug in Go's arm64 compiler | /how-we-found-a-bug-in-gos-arm64-compiler/ | no |
| September 18, 2025 | Connect and secure any private or public app by hostname, not IP — free fo | /tunnel-hostname-routing/ | no |
| September 23, 2025 | Building unique, per-customer defenses against advanced bot threats in the | /per-customer-bot-defenses/ | no |
| September 24, 2025 | Securing today for the quantum future: WARP client now supports post-quant | /post-quantum-warp/ | no |
| September 25, 2025 | R2 SQL: a deep dive into our new distributed query engine | /r2-sql-deep-dive/ | no |
| September 26, 2025 | Cloudflare just got faster and more secure, powered by Rust | /20-percent-internet-upgrade/ | no |
| September 26, 2025 | Introducing Observatory and Smart Shield — see how the world sees your web | /introducing-observatory-and-smart-shield/ | no |
| September 26, 2025 | How Cloudflare uses the world's greatest collection of performance data to | /how-cloudflare-uses-the-worlds-greatest-collection-of-performance-data/ | no |
| September 29, 2025 | 15 years of helping build a better Internet: a look back at Birthday Week | /birthday-week-2025-wrap-up/ | no |
| September 4, 2025 | Addressing the unauthorized issuance of multiple TLS certificates for 1.1. | /unauthorized-issuance-of-certificates-for-1-1-1-1/ | no |
| April 1, 2026 | Our ongoing commitment to privacy for the 1.1.1.1 public DNS resolver | /1111-privacy-examination-2026/ | no |
| April 14, 2026 | Scaling MCP adoption: Our reference architecture for simpler, safer and ch | /enterprise-mcp/ | no |
| April 17, 2026 | Agents Week: network performance update | /network-performance-agents-week/ | no |
| April 17, 2026 | Introducing Flagship: feature flags built for the age of AI | /flagship/ | no |
| April 17, 2026 | Unweight: how we compressed an LLM 22% without sacrificing quality | /unweight-tensor-compression/ | no |
| April 17, 2026 | Shared Dictionaries: compression that keeps up with the agentic web | /shared-dictionaries/ | partial: compression dictionaries |
| April 2, 2026 | Why we're rethinking cache for the AI era | /rethinking-cache-ai-humans/ | no |
| April 20, 2026 | The AI engineering stack we built internally — on the platform we ship | /internal-ai-engineering-stack/ | no |
| April 20, 2026 | Building the agentic cloud: everything we launched during Agents Week 2026 | /agents-week-in-review/ | no |
| April 21, 2026 | Moving past bots vs. humans | /past-bots-and-humans/ | no |
| April 22, 2026 | Making Rust Workers reliable: panic and abort recovery in wasm‑bindgen | /making-rust-workers-reliable/ | no |
| August 18, 2026 | BGP Role model: tracking the adoption of RFC 9234 | /rfc9234-bgp-role-model/ | no |
| August 19, 2026 | A revisit of remote Spectre attacks on Cloudflare Workers | /revisiting-spectre-attacks-on-workers/ | no |
| August 21, 2026 | Say it once: introducing Bot Preference Sync | /bot-preference-sync/ | no |
| August 24, 2026 | The Cloudflare Blog — brought to you by EmDash | /cloudflare-blog-uses-emdash/ | no |
| August 27, 2026 | How we saved 100 terabytes of memory by optimizing 1.1.1.1's DNS cache | /dns-cache-memory-optimization-1111/ | yes: cache layout, -56% bytes |
| August 28, 2026 | BotBase for Operators: A clearer path to joining Cloudflare's directory of | /botbase-for-operators/ | no |
| August 6, 2026 | Introducing Kitesurf: The agent-first browser that runs in V8 isolates on | /kitesurf/ | no |
| February 13, 2026 | Shedding old code with ecdysis: graceful restarts for Rust services at Clo | /ecdysis-rust-graceful-restarts/ | partial: restart/swap analogue |
| February 20, 2026 | Code Mode: give agents an entire API in 1,000 tokens | /code-mode-mcp/ | no |
| February 24, 2026 | How we rebuilt Next.js with AI in one week | /vinext/ | no |
| February 27, 2026 | The most-seen UI on the Internet? Redesigning Turnstile and Challenge Page | /the-most-seen-ui-on-the-internet-redesigning-turnstile-and-challenge-pages/ | no |
| February 27, 2026 | We deserve a better streams API for JavaScript | /a-better-web-streams-api/ | no |
| February 27, 2026 | Bringing more transparency to post-quantum usage, encrypted messaging, and | /radar-origin-pq-key-transparency-aspa/ | no |
| January 13, 2026 | What we know about Iran's Internet shutdown | /iran-protests-internet-shutdown/ | no |
| January 14, 2026 | What came first: the CNAME or the A record? | /cname-a-record-order-dns-standards/ | no |
| January 27, 2026 | Building a serverless, post-quantum Matrix homeserver | /serverless-matrix-homeserver-workers/ | no |
| July 1, 2026 | Announcing the Monetization Gateway: charge for any resource behind Cloudf | /monetization-gateway/ | no |
| July 1, 2026 | Content Independence Day, one year on: building the business model for the | /agentic-internet-bot-report/ | no |
| July 1, 2026 | Unmasking the crawls with Attribution Business Insights | /attribution-business-insights/ | no |
| July 10, 2026 | Improving Smart Tiered Cache for Public Cloud Regions | /smart-tiered-cache-for-public-clouds/ | no |
| July 14, 2026 | A broken DNSSEC rollover took down .al. Now 1.1.1.1 tells you when validat | /dnssec-nta-ede-33/ | no |
| July 20, 2026 | Cloudflare Internal DNS is now generally available | /internal-dns/ | no |
| July 23, 2026 | Introducing Cache Response Rules | /introducing-cache-response-rules/ | no |
| July 27, 2026 | We're open-sourcing our privacy proxy CLI | /open-sourcing-our-privacy-proxy-cli/ | no |
| July 29, 2026 | Post-quantum authentication to origins is now supported | /post-quantum-authentication-to-origins/ | no |
| July 6, 2026 | Your Worker can now have its own cache in front of it | /workers-cache/ | no |
| July 8, 2026 | Introducing Meerkat: an experiment in global consensus | /meerkat-introduction/ | no |
| July 9, 2026 | Why we cannot wait for better post-quantum signature algorithms | /ml-dsa-will-have-to-do/ | no |
| June 10, 2026 | Route public traffic to private applications with Cloudflare | /private-origins-dns-routing/ | no |
| June 18, 2026 | Build your own vulnerability harness | /build-your-own-vulnerability-harness/ | no |
| March 23, 2026 | Launching Cloudflare's Gen 13 servers: trading cache for cores for 2x edge | /gen13-launch/ | no |
| March 4, 2026 | Moving from license plates to badges: the Gateway Authorization Proxy | /gateway-authorization-proxy-identity-aware-policies/ | no |
| March 6, 2026 | From the endpoint to the prompt: a unified data security vision in Cloudfl | /unified-data-security/ | no |
| May 12, 2026 | When "idle" isn't idle: how a Linux kernel optimization became a QUIC bug | /quic-death-spiral-fix/ | no |
| May 14, 2026 | Our billing pipeline was suddenly slow. The culprit was a hidden bottlenec | /clickhouse-query-plan-contention/ | no |
| May 27, 2026 | Iran's Internet is partially restored, Cloudflare Radar data shows | /iran-internet-partially-restored-may-2026/ | no |
| May 6, 2026 | When DNSSEC goes wrong: how we responded to the .de TLD outage | /de-tld-outage-dnssec/ | no |
| October 1, 2026 | Support for modern cryptographic algorithms in Workers | /workers-ml-kem-ml-dsa-support/ | no |
| October 1, 2026 | One year later: Sovereign AI and the fight for choice | /sovereign-ai-choice-one-year-later/ | no |
| October 13, 2026 | Under the hood, off the hot path: How D1 scales to millions of databases | /d1-control-plane/ | no |
| October 15, 2026 | Cloudflare and OpenAI: Making AI discovery better for everyone | /cloudflare-openai-discovery-agentic-web/ | no |
| October 15, 2026 | A fully programmable secure web gateway | /programmable-gateway-dlp/ | no |
| October 16, 2026 | Continuous accountability for Verified bots | /verified-bots-accountability/ | no |
| October 19, 2026 | Introducing Clairic, a new System One class of extraction models | /clairic-extraction-model/ | no |
| October 19, 2026 | Beyond the patch: Protecting your NetScaler gateway against future vulnera | /protect-your-netscaler-gateway/ | no |
| October 2, 2026 | 2026 Birthday week: network performance update | /network-performance-birthday-week-2026/ | no |
| October 2, 2026 | Follow the thread: a new dashboard to investigate account abuse | /account-abuse-protection-dashboard/ | no |
| October 2, 2026 | Protected Quick Tunnels: simple accountless authentication for your next d | /protected-quick-tunnels/ | no |
| October 20, 2026 | 8 eMudhra certificates are compromised. Here's what you need to know | /emudhra-certificate-compromise/ | no |
| October 21, 2026 | Introducing full transaction detection for Cloudflare WAF | /full-transaction-waf/ | no |
| October 21, 2026 | Cloudflare deploys protections against php2shell vulnerability | /php-vulnerabilities-waf-protection/ | no |
| October 22, 2026 | Localizing compliance at scale: achieving South Korea's ISMS certification | /k-isms/ | no |
| October 23, 2026 | Origin Range Requests: Serving large files without range-request tuning | /origin-range-requests/ | no |
| October 26, 2026 | Cross-request KV cache exposure in the GLM-5.3 Workers AI model, and our r | /kv-cache-exposure-remediation/ | no |
| October 27, 2026 | Introducing the Cloudflare PHP Capture the Flag challenge | /php-ctf/ | no |
| October 29, 2026 | Cloudflare DDoS Threat Report 2026 Q3: More swarms, fewer giants | /ddos-threat-report-2026-q3/ | no |
| October 30, 2026 | Cloudflare services for private origins is now generally available | /private-origins-public-to-private/ | no |
| October 30, 2026 | 4 real? Tracking exploitation and patching of eMudhra's weak keys | /emudhra-patching/ | no |
| October 6, 2026 | The keys to the Internet change on October 11. Are you ready? | /root-ksk-2024-rollover/ | no |
| October 7, 2026 | Building an evidence-grounded agentic security operations harness on Cloud | /agentic-security-operations/ | no |
| October 9, 2026 | Introducing on-demand CPU and memory profiling with flamegraphs for Worker | /workers-on-demand-profiling/ | no |
| September 1, 2026 | How we could save petabytes of cache storage with Zstandard and Pingora | /cache-transcoding/ | no |
| September 10, 2026 | 1.1.1.1 now supports post-quantum DNSSEC, all 2,420 bytes of it | /post-quantum-dnssec-1111/ | no |
| September 18, 2026 | Saving another 100TB of RAM with math (and Rust) | /saving-100-tb-of-ram-with-math/ | yes: struct packing, -25% |
| September 22, 2026 | We just shipped support for the ugliest part of HTTP: Vary | /vary-support/ | no |
| September 28, 2026 | Four months of VoidZero at Cloudflare: making the open-source JavaScript t | /voidzero-update/ | no |
| September 28, 2026 | Supporting native Rust in Workers with the new Emscripten target for wasm- | /rust-workers-emscripten-target/ | no |
| September 29, 2026 | We tested our own WAF with frontier AI models. Here's what we found | /adaptive-ai-waf-testing/ | no |
| September 29, 2026 | Using AI to chart a course for our post-quantum migration | /ai-driven-cryptography-discovery/ | no |
| September 29, 2026 | Building a certificate authority for the whole Internet | /cloudflare-certificate-authority/ | no |
| September 29, 2026 | Building a post-quantum certificate authority with Merkle Tree Certificate | /pq-ca-with-mtcs/ | no |
| September 29, 2026 | Introducing Threat Signals: agentic skills for open-source threat intellig | /threat-signals/ | no |
| September 30, 2026 | Monetization Gateway beta: charge AI agents for consumption with HTTP 402 | /monetization-gateway-beta/ | no |
| September 8, 2026 | Automatic Key Exchange: faster, post-quantum secure origin handshakes for | /automatic-key-exchange-for-origins/ | no |

### B. Sources read in full beyond the tag sweep

| Date | Source | Why it matters |
|---|---|---|
| 2017-04-11 | <https://blog.cloudflare.com/how-we-made-our-dns-stack-3x-faster/> | RRSet grouping + MessagePack, 9× edge storage |
| 2018-02-21 | <https://blog.cloudflare.com/validating-leaked-passwords-with-k-anonymity/> | sorted hash prefixes, 16⁵ buckets |
| 2018-11-28 | <https://blog.cloudflare.com/l4drop-xdp-ebpf-based-ddos-mitigations/> | rules as code, not maps |
| 2019-03-04 | <https://blog.cloudflare.com/how-we-made-firewall-rules/> | Quicksilver O(1) key lookup for lists |
| 2019-03-04 | <https://blog.cloudflare.com/building-fast-interpreters-in-rust/> | `IndexMap`→array, 2× on hot path |
| 2020-03-02 | <https://blog.cloudflare.com/when-bloom-filters-dont-bloom/> | Bloom vs 64-bit hash table |
| 2020-04-01 | <https://blog.cloudflare.com/introducing-1-1-1-1-for-families/> | product description, no structure |
| 2020-04-02 | <https://blog.cloudflare.com/the-mistake-that-caused-1-1-1-3-to-block-lgbtqia-sites-today/> | the "compact data structure" quote |
| 2020-07-01 | <https://blog.cloudflare.com/making-the-waf-40-faster/> | PCRE→DFA, memoisation |
| 2020-07-22 | <https://blog.cloudflare.com/introducing-ip-lists/> | list object, 1,000 entries at launch |
| 2020-11-11 | <https://blog.cloudflare.com/brotli-compression-using-a-reduced-dictionary/> | k=1 Bloom + hash + radix trie |
| 2021-03-30 | <https://blog.cloudflare.com/account-takeover-protection/> | keyed-hash credential lookup |
| 2022-03-29 | <https://blog.cloudflare.com/magic-firewall-optimizing-ip-lists/> | shared map vs per-namespace copies |
| 2023-02-28 | <https://blog.cloudflare.com/big-pineapple-intro/> | resolver + Wasm guests, ARC cache |
| 2023-05-12 | <https://blog.cloudflare.com/how-pingora-keeps-count/> | CM sketch numbers |
| 2023-06-19 | <https://blog.cloudflare.com/scalable-machine-learning-at-cloudflare/> | mmap + rkyv + left-right swap |
| 2024-03-08 | <https://blog.cloudflare.com/building-urlscanner> | scanner architecture; no URL set |
| 2024-09-10 | <https://blog.cloudflare.com/pingora-saving-compute-1-percent-at-a-time/> | trie-hard, FST, regex numbers |
| 2024-10-29 | <https://blog.cloudflare.com/migrating-billions-of-records-moving-our-active-dns-database-while-in-use/> | A/B cutover in 2 s |
| 2025-03-24 | <https://blog.cloudflare.com/improving-web-standards-urlpattern/> | Workers routing = 8 regexes |
| 2025-07-07 | <https://blog.cloudflare.com/egress-policies-by-hostname/> | wildcard domain, synthetic IP tags |
| 2025-07-10 | <https://blog.cloudflare.com/quicksilver-v2-evolution-of-a-globally-distributed-key-value-store-part-1/> | Bloom 6 GB vs Cuckoo 18 GB |
| 2025-10-21 | <https://blog.cloudflare.com/a-deep-dive-into-bpf-lpm-trie-performance-and-optimization/> | LPM trie numbers, dTLB wall |
| 2025-10-30 | <https://blog.cloudflare.com/agent-registry/> | registry/list format, no structure |
| 2026-08-27 | <https://blog.cloudflare.com/dns-cache-memory-optimization-1111/> | 953→420 B/entry |
| 2026-09-18 | <https://blog.cloudflare.com/saving-100-tb-of-ram-with-math/> | 8→6 byte packing, −100 TB |

### C. Repositories examined

| Repo | What I read | Verdict |
|---|---|---|
| <https://github.com/cloudflare/entropy-map> | README, `src/set.rs`, `src/mphf.rs` | **relevant**: exact MPHF set, 2.10–2.71 bits/key, 5–20 ns |
| <https://github.com/cloudflare/trie-hard> | README, repo tree, benches | **relevant**: contiguous bitmask trie, ≤37-byte alphabet |
| <https://github.com/cloudflare/mmap-sync> | README, tree, bench numbers | **relevant**: two-file left-right swap, rkyv |
| <https://github.com/cloudflare/wirefilter> | `list_matcher.rs`, `rhs_types/list.rs`, `range_set.rs`, `searcher.rs` | **relevant**: `RangeSet` sorted binary search; list is a trait |
| <https://github.com/cloudflare/pingora> | `pingora-ketama/src/lib.rs`, `pingora-limits/src/estimator.rs`, `tinyufo/src/estimation.rs`, `weighted.rs`; tree-wide grep | **relevant**: 6-byte Point, CM sketches; no trie/Bloom |
| <https://github.com/cloudflare/wildcard> | README, `src/lib.rs` head | exact wildcard matcher, no set |
| <https://github.com/cloudflare/ahocorasick> | `ahocorasick.go` node struct + tree | exact automaton, 256-way child/fail arrays (~4 KiB/node) |
| <https://github.com/cloudflare/go-ipfs-blocklist> | README | thin datastore wrapper |
| <https://github.com/cloudflare/foundations> | grep for set/filter code | nothing relevant |
| `cloudflare/quiche-mallard` | README | deprecated zero-copy fork, merged into quiche 0.24 |
| `cloudflare/lol-html`, `cloudflare/workerd` | repo descriptions; `workerd` covered via §4.3 | not set/trie work |

### D. Documentation pages

| Page | What it gave |
|---|---|
| <https://developers.cloudflare.com/cloudflare-one/traffic-controls/domain-categories/> | category IDs, parent-domain inheritance, IP/CNAME options, feed provenance |
| <https://developers.cloudflare.com/cloudflare-one/traffic-controls/dns-policies/> | first-match semantics, block responses |
| <https://developers.cloudflare.com/cloudflare-one/account-limits/> | 100 lists, 1,000/5,000 entries, 500 policies, 140,000-char expressions |
| <https://developers.cloudflare.com/cloudflare-one/reusable-components/lists/> | no wildcards in Gateway hostname lists, 2 MB CSV, 600 req/min |
| <https://developers.cloudflare.com/waf/tools/lists/custom-lists/> | WAF list types, `*.example.com`, IP range bounds |
| <https://developers.cloudflare.com/cache/how-to/cache-keys/> | cache key = identifier template, no set structure |
| <https://research.cloudflare.com/> + `/focus/fast`, `/focus/measurable`, `/presentations` | 21 publications, none on set structures |

### E. Explicitly absent or unverified

- `cloudflare/flowtrack`, `cloudflare/ipnet`, `cloudflare/cuckoofilter`,
  `cloudflare/bloomfilter`, `cloudflare/fst`, `cloudflare/mphf`, `cloudflare/radix`,
  `cloudflare/lpm`: **not in the org** (checked against all 580 names).
- Blog tags `cuckoo` and `bloom`: **do not exist** (404 pages).
- `cloudflare/entropy-map` production deployment: **UNVERIFIED** (README silent).
- MIGP details and the `tubular` LPM encoding: seen only as search snippets, not opened,
  therefore unused. **UNVERIFIED.**
- No Cloudflare publication gives a bytes-per-domain figure for any DNS block list.

---

## 13. Round 2: open-addressing hash tables

Round 1 read "When Bloom filters don't bloom" (2020-03-02) as a warning about filters. That
was incomplete: the post also reports a **membership set that stores nothing but 64-bit
hashes in a flat open-addressed array** — no bucket array, no `next` chain, no stored key —
and reports it beating the Bloom filter. This section reads that code at a pinned commit,
then looks for the same structure elsewhere in Cloudflare's public code and prose.

### 13.1 `mmuniq`: the exact structure, from the source

Pinned at commit `7c16f55ea6fd5681c141dffb4a70a1877058ee9b` (2020-03-04, the last commit
touching the directory; I fetched `master` and this SHA and compared them byte for byte —
identical). Files:

- <https://github.com/cloudflare/cloudflare-blog/blob/7c16f55ea6fd5681c141dffb4a70a1877058ee9b/2020-02-mmuniq/mmuniq.c> — the batch/prefetch version used for the 2.1 s figure
- <https://github.com/cloudflare/cloudflare-blog/blob/7c16f55ea6fd5681c141dffb4a70a1877058ee9b/2020-02-mmuniq/mmuniq-hash.c> — the first hash-table version, the one the "around 4 seconds" memory-hit estimate refers to
- `mmuniq-bloom.c`, `csiphash.c`, `Makefile` in the same directory

There is **no README** in `2020-02-mmuniq/` (that path 404s). The `Makefile` builds three
binaries: `mmuniq-bloom` (links `-lm`), `mmuniq-hash` (siphash24, no `-maes`), and `mmuniq`
(`-maes`, AES-NI hash). The post's links point at the same files.

| Property | `mmuniq-hash.c` | `mmuniq.c` |
|---|---|---|
| Slot | `uint64_t`, **8 B** | `uint64_t`, **8 B** |
| Content of a slot | the raw 64-bit hash | the raw 64-bit hash |
| Key stored? | **no** | **no** |
| Buckets / `next` links | none | none |
| Capacity | power of two | power of two |
| Slot index | `i & size_mask` (mask, not modulo) | same |
| Probing | linear, `i += 1` | linear, `i += 1` |
| Probe cap | 4096 | `OVERFLOW_AFTER` = 4096 |
| Empty marker | slot `== 0` | slot `== 0` |
| Sizing | fixed by `-n`, default 500,000,000 → 2²⁹ slots = **4 GiB** | L3-derived, fallback 4 M slots = **32 MiB** |
| Resize | none | double when items > 0.6 × capacity |
| Load factor | whatever `-n` implies | 0.6 default; outside [0.1, 0.9] resets to 0.6 |
| Allocation | anonymous `mmap` + `MAP_POPULATE` | same |
| Prefetch | none | batch of 128, first probe only |
| Hash | siphash24, fixed `k0 = k1 = 0xdeadbeeffadebabe` | AES-NI: 2× `aesenc` per 16 B |
| Overflow | `miss = 0` → line treated as duplicate | `miss = -1` → line not emitted |

#### Slot layout and sizing

`uint64_t *bm`, one 8-byte word per slot, holding only the hash:

```
 65  static uint64_t global_size_mask;
 ...
 80  static uint64_t *global_bm;
```

Sizing is a power-of-two mask, so the index is a single AND, never a division:

```
322     global_size_mask = 1;
323     while (global_size_mask < global_size) {
324         global_size_mask <<= 1;
326     global_size_mask -= 1;

328     size_t bm_sz = (global_size_mask + 1) * 8;
329     global_bm = mmap(NULL, bm_sz, PROT_READ | PROT_WRITE,
330                      MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
```

The default size is derived from L3, not from the input: `global_size = 4096`, then doubled
while `global_size * 2 * 8 < l3_cache` (lines 260–268). The factor `2*8` means the table is
sized to sit between L3/2 and L3 bytes. With no L3 (`sysconf` ≤ 0) it uses 4,194,304 slots =
32 MiB.

`mmuniq-hash.c` has no resize at all; `-n` (default 500,000,000) fixes the table, and the
mask loop uses `<=`, so the capacity is the next power of two **strictly greater** than `n`
(lines 157–161). The default therefore allocates 2²⁹ × 8 B = 4 GiB, which is why the post
frames the tool as "less than 64 Gigs of RAM" territory only for the k=1 Bloom; the hash
variant is sized by the hint.

#### Load factor and resize policy (`mmuniq.c` only)

```
 20  #define DEFAULT_FILL_RATE 0.6
...
336      uint64_t fill_threshold = fill_rate * (double)(global_size_mask + 1);
...
389      if (global_items > fill_threshold) {
391          uint64_t size_mask_new =
392              ((global_size_mask + 1) * 2) - 1;
393          size_t bm_sz_new = (size_mask_new + 1) * 8;
394          uint64_t *bm_new =
395              mmap(NULL, bm_sz_new, PROT_READ | PROT_WRITE,
396                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
399          for (j = 0; j < global_size_mask; j++) {
400              uint64_t h = global_bm[j];
401              if (h == 0) {
402                  continue;
403              }
404              hash_insert(h, bm_new, size_mask_new);
...
408          munmap(global_bm, bm_sz);
```

So: grow at 60 % full, double, rehash every non-zero slot by probing the new table, then
`munmap` the old one. `-f` resets the fill rate to 0.6 if it is outside [0.1, 0.9]
(lines 307–310). Peak during a resize is old + new = **1.5× the new table**, since the old
table is one power of two smaller — worth remembering when we size our own build.

#### Probing, wrap, empty marker, and the `h == 0` hole

```
102  static int hash_insert(uint64_t h, uint64_t *bm, uint64_t size_mask)
103  {
104      uint64_t i;
105      int miss = -1;
106      for (i = h; i < h + OVERFLOW_AFTER; i += 1) {
107          uint64_t *v = &bm[i & size_mask];
108          if (*v == 0) {
109              *v = h;
110              miss = 1;
111              break;
112          } else if (*v == h) {
113              miss = 0;
114              break;
115          }
116      }
117      if (miss == -1) {
118          overflow_count += 1;
119      }
120      return miss;
121  }
```

- **Wrap** is implicit: the loop counter grows monotonically and each access re-masks with
  `& size_mask`, so it wraps modulo the capacity with no branch.
- **Empty** is the all-zero slot. Nothing special-cases a hash that *is* 0: `*v == 0` fires,
  `*v = h` writes 0 back, and `miss = 1`, so a line hashing to 0 is emitted as unique every
  time and never stored (the resize loop at line 401 also skips it). Probability 1 in 2⁶⁴
  per line; it is a real hole in the design, not a theoretical one, and worth a
  `if (h == 0) h = 1;` in any port.
- **Overflow** (4096 probes) does not wrap or fall back to a chain: `mmuniq.c` returns −1 and
  `process_flush` then emits nothing for that line (both of its emit conditions test
  `miss == 1` or `miss == 0`), so the line is silently dropped; `mmuniq-hash.c` sets
  `miss = 0` (line 98), which also drops it under the default mode. Both print a warning at
  exit. With a resize at 0.6 this should not happen unless the hash is pathologically
  clustered; it is nonetheless a fail-silent path.

#### The batched prefetch: what is actually prefetched

```
 84  /* For better prefetching we first count hashes and prefetch the hash
 85   * table. This is how many items to prefetch before actually doing
 86   * hash table inserts. */
 87  #define C_LINE_SZ 128
 88  struct c_line {
 89      char *s;
 90      int l;
 91      uint64_t h;
 92  } c_lines[C_LINE_SZ];
...
145      if (s != NULL) {
146          line_count += 1;
147          // Issue the prefetch as soon as possible
148          __builtin_prefetch(&global_bm[h & global_size_mask]);
149
150          c_lines[c_pos] = (struct c_line){s, l, h};
151          c_pos += 1;
152      }
153
154      if (force || c_pos == C_LINE_SZ) {
155          int i;
156          for (i = 0; i < c_pos && i < C_LINE_SZ; i++) {
157              struct c_line *c = &c_lines[i];
158              process_flush(c->s, c->l, c->h);
159          }
160          c_pos = 0;
161      }
```

- Batch = **128 lines**, held in a static array of `{char*, int, uint64_t}` (24 B per entry
  on x86-64 after padding, 3,072 B total).
- **Only the first probe slot** `h & mask` is prefetched — not `+1`, not the rest of the
  chain. The comment says as much: one prefetch per item.
- The flow change is the point: the prefetch is issued **at parse time**, 128 lines before
  the insert touches the slot. That converts a dependent load (hash → address → load) into a
  load whose latency is overlapped with the parsing and hashing of the next 127 lines.
- The post is explicit that the instruction alone is not the trick: "Beware, sprinkling the
  code with 'prefetch' rarely works. Instead, I specifically changed the flow of algorithms
  to take advantage of this instruction."

### 13.2 The numbers, exactly as the post states them

Task: deduplicate 40 M lines / 600 MiB of IP-spoofing measurement data.

| Variant | Reported |
|---|---|
| `sort \| uniq` | "much more than two minutes"; the post's closing line is "from more than two minutes to 2 seconds" |
| Bloom k=8, 128 MiB | 12 s; 87.2 % of cycles in the hot loop |
| Bloom k=1 | needs **64 GiB** for the same FPR; 22 s kernel + 11 s user |
| 64-bit siphash open-addressing table | "40M memory hits take around 4 seconds" |
| Same + dynamic resize + batched prefetch | **2.1 s** |

The hash table's claim, verbatim: "The hash table code runs faster, has better memory
access patterns and better false positive probability than the Bloom filter approach."
Linear probing cost: "we had to skip over 0.7 buckets on average to find an empty slot". The
post does not say at what load factor that 0.7 was measured, and the code's own `-n` default
(500 M slots for 40 M lines, ≈8 %) would predict far fewer skips, so I do not derive α from
it. Prefetch gain: "by using batching, it can effectively use the 'prefetch' CPU hint,
speeding up the program by 35-40%".

What the post **does not** give: bytes per entry for the hash table, the capacity it actually
ran with, or a load-factor sweep. Those are absent, not estimated, and I have not filled
them in.

### 13.3 The same structure elsewhere in Cloudflare's public code

I grepped the repo trees and read the declarations; no Cloudflare component I found stores a
*flat array of raw fingerprints* the way `mmuniq` does. What exists is a set of
hash-map-backed indexes whose keys are already 64-bit hashes.

| Component | Container | Slot / entry | Load | Key stored in full? | Per-entry memory reported |
|---|---|---|---|---|---|
| `pingora-lru` shard | `hashbrown::HashMap<u64, Box<LruNode<T>>>` | hashbrown entry (`u64` + `Box` = 16 B) + ~1.1 control byte/entry at 87.5 %; node is a separate `Box` | **87.5 %** (hashbrown: "require 1/8 buckets to be empty") | No — the map key is a **u64 hash**, `LruNode` holds only data + `usize` list index + `usize` weight | dhat output in `pingora-cache/benches/lru_memory.rs`: **681,836,456 B for 5,242,880 items ≈ 130 B/item** (arithmetic mine) |
| `pingora-cache` LRU | `u64key()` = `ahash::AHasher::default()` → `u64`, fed to `pingora_lru` | as above | 87.5 % | No | as above |
| `pingora-cache` simple LRU | `lru::LruCache` (external crate) keyed by `DefaultHasher`-derived `u64` | external | n/a | No | its own bench file |
| TinyUFO "fast" | `flurry::HashMap<Key, Bucket<T>, RandomState>`, `type Key = u64` | Java-CHM-style bins, `Bucket<T>` inline in the node | **75 %** (flurry `load_factor!` = `n - (n>>2)`; "resize the table once it is 75% full") | No — "we currently don't store the Actual key in the cache" | README table: 2,290,635 B for 10,000 zero-sized assets ≈ **229 B/asset** (arithmetic mine) |
| TinyUFO "compact" | `Box<[SkipMap<Key, Bucket<T>>]>`, sharded by `key % shards` | skiplist nodes | n/a | No | README: 766,024 B for 10,000 ≈ **77 B/asset** (arithmetic mine) |
| `pingora-limits` | `Box<[(Box<[AtomicIsize]>, RandomState)]>` — count-min sketch, H rows × N `AtomicIsize` counters | 8 B per counter, `ahash` per row | n/a (not a set) | n/a | 26,184 B for 1 M keys / 100 M events |
| `foundations` | `std::collections::HashSet<Key>` for log-field dedup and redaction only | std | n/a | Yes | none |
| `boringtun` | `HashMap<PublicKey, …>`, `HashMap<u32, …>` | std | n/a | Yes | none |
| `rustracing` | `HashMap`/`BTreeMap` for baggage | std | n/a | Yes | none |
| `cloudflare-blog` (all 26 dirs) | `mmuniq` only. `mmdist` is AVX2 distance over 144-byte perceptual hashes, no table | — | — | — | — |
| Quicksilver | Bloom in RocksDB for negative lookups; then key/value separation. No open addressing described | — | — | **Yes** (keys kept, "approximately 11 times smaller than the full dataset") | Bloom 6 GB vs Cuckoo 18 GB at 5 B keys |

Reading: Cloudflare's production containers are *maps* (key → value), so they carry the key
explicitly and pay 4–16 B for it plus 1 B of control; the only component that drops the key
entirely is `mmuniq`, and the components that trust a 64-bit fingerprint as the identity are
TinyUFO and the two pingora LRUs (all in-memory caches; TinyUFO and `pingora-lru` use a
per-process random `ahash` seed, `simple_lru` uses `DefaultHasher`).

`mmuniq` is also the only place in the org where the **slot is the hash**; `pingora-lru`
hashes its `u64` key a second time through hashbrown's SipHash, and TinyUFO hashes its key
once into `u64` and then again inside flurry.

### 13.4 Hash choice, collision math, and what they accept

**The math, verbatim.** From the Bloom post, on the 64-bit table:

> "Adding a new item to a hash table containing, say 40M, entries has '40M/2^64' chances of
> hitting a hash collision. This is about one in 461 billion … But we are not adding one item
> to a pre-filled set! … As per birthday paradox this has much higher chances of hitting a
> collision at some point. A decent approximation is 'n^2/2m', which in our case is
> '(40M^2)/(2*(2^64))'. This is a chance of one in 23000. … This practical chance of hitting
> a collision is non-negligible, but it's still better than a Bloom filter and totally
> acceptable for my use case."

So the tool's own contract is: **at 40 M items, one in ~23,000 builds is expected to contain
a colliding pair**, and the author accepts it because the failure mode is a lost
deduplication line in a measurement file.

**Hash choice.** Two implementations, both in the same directory:

- `mmuniq.c`: an AES-NI hash — `_mm_aesenc_si128` twice per 16-byte block, plus a final
  `aesenc` mixing in the line length, then `hash[0] ^ hash[1]`. The usage text calls it "a
  simplified hash function" and warns about the birthday bound. Fixed round keys, no per-run
  seed.
- `mmuniq-hash.c`: `siphash24` with `k0 = k1 = 0xdeadbeeffadebabe` — fixed, therefore
  reproducible and adversarially predictable.
- `mmuniq-bloom.c`: the same siphash, re-keyed per iteration as `k0 + off`, `k1 + off` for
  the k=8 filter.

Cloudflare does distinguish "in-memory only" from "must be stable" hashing, in
`pingora-cache/src/key.rs`:

> "We use blake2 hashing, which is faster and more secure, to replace md5. … Note: we should
> avoid hashes like ahash which does not have consistent output across machines because it is
> designed purely for in memory hashtable"

That comment is about cache keys that must be comparable across machines; the LRU and
TinyUFO deliberately use `ahash` (randomised per process) because their u64 keys never leave
the process.

**Production systems that treat a 64-bit fingerprint as the identity.** Two, both caches, not
filters:

- TinyUFO: `type Key = u64;` and, in `KV<T>`: "NOTE: that we currently don't store the Actual
  key in the cache. This returned value is just the hash of it." `TinyUfo::get` computes
  `self.random_status.hash_one(key)` and looks that u64 up in the map. A collision returns
  the wrong cached object.
- `pingora-lru` / `pingora-cache`: the LRU's `lookup_table` is
  `HashMap<u64, Box<LruNode<T>>>` and the key is `u64key(&node.0)`, i.e. `ahash` of the real
  cache key. The real key is retained *inside* the node (for eviction), but **membership and
  identity are decided by the 64-bit hash**.
  [INFERENCE] A collision aliases two cache entries; they do not document the risk.

For a DNS *block list* the failure mode is the opposite of a cache: a false positive blocks
a legitimate domain for every client behind the resolver. That asymmetry is the whole argument
against copying this design wholesale, and it is the argument the post itself invites when it
says the collision risk was acceptable "for my use case."

### 13.5 Prefetching and memory-level parallelism

`mmuniq` is the only Cloudflare engineering publication I found that measures software
prefetch. I checked the LPM-trie post, the 2026 DNS-cache post, the Magic Firewall post and
the whole `pingora` tree for `prefetch`/`_mm_prefetch` — no hits. So there is exactly one
data point:

| Claim | Source |
|---|---|
| batching + prefetch is "35-40%" of the speedup | Bloom post (verbatim above) |
| batch size 128, one prefetch per item, at first probe only | `mmuniq.c` lines 84–92, 148 |
| the win comes from restructuring, not from adding the instruction | post: "I specifically changed the flow of algorithms" |

**Smallest transferable form for our loop.** Our query hashes each label suffix once per
list, so for one query and 21 lists we need 21 hash→address→load chains per suffix. Three
shapes, in increasing order of how much they change:

1. **Batch across lists within one query (x86).** Compute the 21 slot addresses for suffix
   *s* into a `stackalloc` buffer, issue 21 `Prefetch0` calls, then probe in a second loop.
   This mirrors `mmuniq`'s two-phase shape without needing 128 independent queries. Cost:
   21 cache-line touches per suffix, i.e. 21 × 64 B = 1.3 KiB of fetch per suffix — for 4–5
   suffixes that is ~6 KiB per query, which on a 1 GiB Pi is real bandwidth; only do it if the
   tables are hot.
2. **Batch across suffixes, one merged table.** With R2's single merged table, a query needs
   4–5 slot addresses, not 84. Prefetching those five, then probing, is the same trick at a
   scale that fits the fill buffers.
3. **No prefetch, but split the phases anyway (ARM).** Compute all candidate hashes and slot
   indices first, *then* perform the loads in a branch-free loop. The out-of-order window
   covers independent loads even without a hint; what breaks it is a branch between loads
   (the `if (*v == 0)` in the probe loop). A branchless probe that always computes
   `v == h`, `v == 0` and combines with `&`/`|` keeps the loads independent.
   [INFERENCE] I have not measured this; it follows from the same dependency argument the
   post makes, and from the fact that our target has no prefetch intrinsic (§13.6).

### 13.6 .NET: does a prefetch intrinsic exist, and on which architectures

**x86-64: yes.** `System.Runtime.Intrinsics.X86.Sse` exposes four methods, all taking
`void*`:

- `Sse.Prefetch0(Void*)` → `_mm_prefetch(p, 0)` / `PREFETCHT0 m8`
- `Sse.Prefetch1`, `Sse.Prefetch2`, `Sse.PrefetchNonTemporal` → `PREFETCHT1`/`T2`/`NTA`

Source: <https://learn.microsoft.com/en-us/dotnet/api/system.runtime.intrinsics.x86.sse.prefetch0>
and the method list on
<https://learn.microsoft.com/en-us/dotnet/api/system.runtime.intrinsics.x86.sse>. Available
since .NET Core 3.0 (the doc's monikers run `netcore-3.0` … `net-11.0`). It is `void*`, so it
needs `unsafe` and a `fixed` (or `Unsafe.AsPointer`) on the array; and it must be guarded by
`Sse.IsSupported`, because `Sse` is an x86-only class whose unsupported bodies throw
`PlatformNotSupportedException`.

**ARM64: no `PRFM` intrinsic.** I read the source of every Arm intrinsic class in
`dotnet/runtime` (`ArmBase.cs`, `AdvSimd.cs`, `Aes`, `Crc32`, `Dp`, `Rdm`, `Sha1/256/3`,
`Sm4`, `Sve*`): the only `Prefetch` members are in **`Sve`** —
`Sve.Prefetch8Bit/16Bit/32Bit/64Bit(Vector<…> mask, void* address, SvePrefetchType)` and the
`Sve.GatherPrefetch*` family — plus the `SvePrefetchType` enum
(`LoadL1Temporal`, `LoadL1NonTemporal`, `LoadL2Temporal`, …). Sources:

- <https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/Runtime/Intrinsics/Arm/Sve.cs> (methods at lines 7951–7978)
- <https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/Runtime/Intrinsics/Arm/Enums.cs> (`SvePrefetchType`)
- `ArmBase.cs` and `AdvSimd.cs` contain the string `Prefetch` zero times.

Consequence for our targets: SVE is optional, and `Sve.IsSupported` is the runtime answer. On
an ARM64 core without SVE there is **no managed prefetch at all** in .NET 10; the x86 path is
unavailable (`Sse.IsSupported == false`). So for the Pi-class devices we must rely on option
3 above (phase splitting and branch-free probes), not on a hint. (Arm's Cortex-A76 page
(<https://www.arm.com/products/silicon-ip-cpu/cortex-a/cortex-a76>) lists "advanced
instruction and data prefetching" as a core feature; that is hardware prefetch, not an
instruction we can emit, and I did not verify SVE presence for any specific SoC.)

### 13.7 Many small sets in one flat allocation

What Cloudflare actually publishes here is only the *sharing* argument, not a partitioning
scheme:

- **Magic Firewall**: one eBPF `BPF_MAP_TYPE_LPM_TRIE` per list, shared across all customer
  namespaces, replacing one nftables set copy per namespace — "eBPF maps exist regardless of
  a network namespace … eBPF gives us a way to share this data across all the network
  namespaces we create for our customers". The motivation was exactly per-tenant duplication,
  not per-set overhead.
- **`mmuniq`**: a single `mmap`'d array for the whole set, sized once (or doubled).
- **`pingora-limits`**: `Box<[(Box<[AtomicIsize]>, RandomState)]>` — one boxed slice of rows,
  but each row is a *separate* allocation, so it is not one flat array.
- **TinyUFO compact**: `Box<[SkipMap<…>]>` — an array of independent maps, not a partition of
  one array.

I found **no** Cloudflare source that carves N independent sets out of a single flat
allocation (no offset table over one array, no "arena of sets"). `wirefilter`'s `Scheme`
registers list names and their matchers in one shared registry, which is the nearest idea —
shared identity, separate storage — and `entropy-map`'s `Set` keeps one `Box<[K]>` per set.
So §9 R2 (one blob, per-entry mask) remains the right answer for per-set overhead, and
Cloudflare supports the *shared* half of it (Magic Firewall) but has nothing to say about the
*partitioned* half.

### 13.8 What this means for a per-list `ulong[]` / `(ulong, mask)[]` table in C#

**The size arithmetic, for our numbers** (`n = 2,292,355` unique names; `m = 2,670,703`
per-list entries):

| Shape | Capacity at α=0.6 | Bytes | MiB | Notes |
|---|---|---|---|---|
| one `ulong[]`, membership only | 4,194,304 slots | 33,554,432 | **32.0** | no attribution; α actual 0.547 |
| one `(ulong hash, ulong mask)[]` merged | 4,194,304 slots | 67,108,864 | **64.0** | attribution for ≤64 lists |
| one `ulong[]` per list (23 lists), α=0.6 | one power of two per list | ~34 MiB ideal × rounding | **~48–53** | attribution is the table; power-of-two rounding ≈1.44× on average [INFERENCE] |
| `HashSet<ulong>` per list (measured by us) | — | 20 B/entry | **~51** | what the current patches do |

For comparison, the exact structures from §9: 84.0 MiB sorted-only, 89.4 MiB with the Bloom,
64 MiB for the merged compact index, 57.8 MiB floor.

So the honest ranking on bytes: **32 MiB (probabilistic, no attribution) < 48–53 MiB (per-list
tables) < 64 MiB (merged exact index) < 84 MiB (today)**. The `ulong[]` idea is a genuine
~35–40 % saving over today's exact structure *only* in the per-list form, and it costs
exactness. Merged with attribution it lands exactly where the exact merged index already is
(64 MiB) while adding collision risk — no win at all.

**Probe cost matters more than bytes here.** At α=0.6 the textbook expectations for linear
probing are **3.6 probes for a miss** and 1.75 for a hit; at α=0.75 it is **8.5 for a miss**.
Our lookup is miss-dominated (most queried names are not blocked), and we do it 4–5 times per
query (one per suffix) × 21–44 times (one per list). That is why the merged shape is the only
one that makes sense: 4–5 misses total, not 84–220.

**Exactness.** At `n = 2.29 M`, `n²/2m = (2,292,355)²/(2·2⁶⁴) = 1.42 × 10⁻⁷`, i.e. **one in
about 7.0 million builds** of the full union would contain a colliding pair (arithmetic mine,
same formula the post uses). That is 300× rarer than the post's 40 M case, and the chances
per *query* are negligible; but the consequence is a permanently blocked legitimate domain,
not a lost dedup line. If we go this way it should be a documented, opt-in compromise, not a
silent replacement for an exact structure.

**Smallest C# shape that is actually faithful to `mmuniq`** (~45 lines):

```csharp
sealed class HashTable64              // mmuniq.c, minus the resizing
{
    private readonly ulong[] _slots;  // 0 = empty; 8 B/slot
    private readonly int _mask;       // capacity - 1, capacity is a power of two

    public HashTable64(int expected)
    {
        int cap = 4;
        while (cap < expected / 0.6) cap <<= 1;   // α ≤ 0.6, like DEFAULT_FILL_RATE
        _slots = new ulong[cap];                  // CLR zeroes it; 0 is the sentinel
        _mask = cap - 1;
    }

    private static ulong Mix(ulong h)             // splitmix64 finalizer
    {
        h ^= h >> 30; h *= 0xbf58476d1ce4e5b9UL;
        h ^= h >> 27; h *= 0x94d049bb133111ebUL;
        h ^= h >> 31;
        return h == 0 ? 1UL : h;   // 0 is the empty sentinel; do NOT just OR 1
    }

    public bool Contains(ulong hash)
    {
        ulong h = Mix(hash);
        for (int i = 0; i < 4096; i++, h++)        // linear probe, wraps by mask
        {
            ulong v = _slots[(int)h & _mask];
            if (v == h) return true;               // hit
            if (v == 0) return false;              // empty slot: miss
        }
        return false;                              // over-full: treat as miss, like mmuniq
    }

    public bool Add(ulong hash)                    // true if newly inserted
    {
        ulong h = Mix(hash);
        for (int i = 0; i < 4096; i++, h++)
        {
            ref ulong v = ref _slots[(int)h & _mask];
            if (v == h) return false;              // already present
            if (v == 0) { v = h; return true; }    // claim the empty slot
        }
        return false;                              // over-full; caller sized it at 0.6
    }
}
```

Differences from `mmuniq` that a port must make consciously:

- **`Mix` + a zero check** removes the `h == 0` hole. Do **not** map it with `h |= 1`: the
  slot index is `h & mask`, so forcing bit 0 would make every first probe land in an odd
  slot and leave half the table reachable only by probing. `mmuniq` has this hole (a line
  hashing to 0 is emitted every time and never stored).
- **Size once from a known count**, not by doubling: we parse all lists before publishing, so
  we can avoid `mmuniq`'s 1.5× resize peak entirely (and its 4096-probe failure mode).
- **`int` index, not `ulong` counter**: `(int)h & _mask` avoids 64-bit address arithmetic;
  capacity ≤ 2³¹ is far beyond our size.
- **Store the list mask in a parallel `ulong[] _masks`**, not interleaved in a struct. A probe
  that misses only touches `_slots`, so the mask array contributes no cache traffic on the
  miss path (which dominates); two arrays also keep the slot type 8 bytes and the index
  arithmetic identical to `mmuniq`. Interleaved `(hash, mask)` is 16 B/slot with no padding
  either, but it doubles the bytes fetched per probe.
- **No `HashSet<ulong>`**: the current 20 B/entry is the `Entry{int hashCode, int next,
  ulong key}` (16 B) plus a `int[] buckets` (4 B/slot), i.e. exactly the bucket/next/key
  fields the flat table deletes.

**Verdict.** The `mmuniq` structure is the right *shape* for a fingerprint set and it is
trivially portable, but for our problem it only helps if we (a) accept ~1-in-7M collision
risk, and (b) merge the lists so the 21-fold lookup multiplicity disappears. If we keep
exactness, R1 (front-coding) and R2 (merged exact index) still dominate it on every axis
except code size.

### 13.9 Round-2 verification status

Verified by reading the code and docs quoted above: slot size/layout, mask indexing, probe
order and wrap, empty marker and the unhandled zero hash, 0.6 load and doubling, 4096-probe
cap, batch size and what is prefetched, both hash functions, `MAP_POPULATE`, `hashbrown`'s
87.5 % and 1-byte-control overhead, flurry's 0.75, TinyUFO's `Key = u64` and double hashing,
the README memory tables (totals only — the per-item figures are my division), the dhat
totals in `lru_memory.rs`, the `Sse` API surface, and the absence of `Prefetch` in
`ArmBase`/`AdvSimd`.

Not verified, and therefore not used: the load factor at which `mmuniq` measured 0.7 skipped
buckets (not stated); bytes per entry for `mmuniq`'s table (not stated); whether TinyUFO's
"fast"/"compact" modes are both in production (README compares them, no deployment claim);
`cloudflare/quicksilver` source (not public); and SVE presence on any specific Raspberry Pi /
Orange Pi SoC (check `Sve.IsSupported` at runtime).
