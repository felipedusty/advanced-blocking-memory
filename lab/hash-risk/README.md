# Hash risk lab

Measures how the hash behind `patch/hash64` and `patch/hash128` behaves against the real
block lists, and what a 64-bit, 96-bit or 128-bit key costs. One program, one mode per
test. The recorded runs are `results/hash-risk/hash-risk-20261102.txt` and `hash-risk-wide-20261102.txt`.

A 64-bit collision cannot be observed (about 1e-7 per run over the real lists), so the
hash is truncated to k bits, where collisions are frequent, and the observed number of
colliding pairs (or of false positives among unlisted names) is compared with the ideal
model: `C(n,2)/2^k` pairs, or `probes * n / 2^k` hits. If the hash tracks the model from
32 down to 44 bits, the 64-bit behaviour follows the same curve. A SHA-256 truncated to
the same width is the control: it must match the model, or the method is wrong.

| mode | what it measures |
|---|---|
| `collide` | colliding pairs among the 2.1 M real entries, 100 random bases, widths 32 to 48 (top and low bits); FNV-1a, FNV-1a with an xorshift per step, SHA-256 control |
| `persist` | whether pairs that collide under one basis collide under another (a new process) |
| `probe` | false positives of unlisted names against the real entries: 60 M random names, 44 M neighbours of every entry, 24 M counters, 5.8 M short labels |
| `dense` | every string of 1 to 5 characters over 38 characters (81 M), two bases |
| `longsub` | every one- and two-position substitution in a 250-character name (40 M), two bases |
| `scale-string N`, `scale-u64 N` | memory and lookup of one set of N synthetic names (15 M and 50 M recorded) |
| `shape` | worst-case query shapes against 21 per-list sets |
| `width-string`, `width-u64`, `width-u128`, `width-tuple`, `width-tuple-cmp`, `width-tuple3`, `width-tuple3-cmp`, `width-dict96` | memory and lookup of the 21 per-list sets with a string, a 64-bit, a 128-bit or a 96-bit key (lane B is the golden-ratio multiplier) |
| `pair128` | colliding pairs of the joint key of two lanes, truncated to 32 to 44 bits (top and low bits), 100 base pairs; the first design (FNV-1a lane B with another basis) fails it by 100x to 8,000x |
| `pair96` | the same for the low bits of lane A with the top bits of lane B |
| `probe128`, `dense128`, `longsub128` | `probe`, `dense` and `longsub` on the joint key of the two lanes |

```sh
lab/fetch-lists.sh
mkdir -p /tmp/risk/lists
python3 lab/hash-risk/dump-lists.py "$PWD" /tmp/risk/lists     # 21 per-list files and union.txt
cp lab/hash-risk/Program.cs lab/hash-risk/risk.csproj /tmp/risk/
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e DOTNET_NOLOGO=1 -e DOTNET_CLI_HOME=/tmp/dotnet \
  -v /tmp/risk:/b -w /b mcr.microsoft.com/dotnet/sdk:10.0 bash -lc \
  'dotnet build -c Release -o out && dotnet out/risk.dll collide && dotnet out/risk.dll probe'
```

The 128-bit and 96-bit rows of the first recorded run (`width-u128`, `hash-risk-20261102.txt`)
used an xorshift second lane and are superseded by `hash-risk-wide-20261102.txt`, which
uses the validated second lane: FNV-1a with the multiplier 0x9E3779B97F4A7C15. Two FNV-1a
lanes with the same multiplier and different bases are not independent (`pair128`).
