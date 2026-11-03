#!/usr/bin/env bash
# Boundary tests for the bucketed DomainSet (patch/experiments/exact-csr and exact-offsets) in the built app.
#
# The class is a private nested type, so the test loads the real assembly and drives it
# through reflection. Its contract differs from the sorted DomainSet: only names that
# DnsClient.IsDomainNameValid accepts are added (ASCII letters, digits, '-', '_', '/', a '*'
# label, at most 255 characters), and Seal() replaces Sort(). The test therefore adds valid
# names only, and checks that queries the parsers would never store (non-ASCII, over 255
# characters, unusual bytes) are answered "not found" without throwing.
#
#   lab/name-set-test.sh
#
# Requires lab/.work/out-patched built with PATCH_DIR=patch/experiments/exact-csr (or exact-offsets).
# The record goes to results/exact-csr.boundary.txt, or to $NAME_SET_OUT.
set -euo pipefail
cd "$(dirname "$0")/.."

out=lab/.work/out-patched
[ -f "$out/AdvancedBlockingApp.dll" ] || {
	echo "missing $out/AdvancedBlockingApp.dll; run PATCH_DIR=patch/experiments/exact-csr lab/build-app.sh patched" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$out"/*.dll "$tmp"/
work=$PWD/lab/.work
cp "$work/DnsServer/DnsServerCore.ApplicationCommon/bin/Release/DnsServerCore.ApplicationCommon.dll" "$tmp"/ 2>/dev/null || true
cp "$work"/TechnitiumLibrary/bin/TechnitiumLibrary.Net.dll "$tmp"/ 2>/dev/null || true
[ -f "$tmp/DnsServerCore.ApplicationCommon.dll" ] && [ -f "$tmp/TechnitiumLibrary.Net.dll" ] || {
	echo "missing DnsServerCore.ApplicationCommon.dll or TechnitiumLibrary.Net.dll; run lab/build-app.sh patched" >&2
	exit 1
}

cat >"$tmp/name-set-test.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>name-set-test</AssemblyName>
  </PropertyGroup>
</Project>
EOF

cat >"$tmp/Program.cs" <<'EOF'
using System.Reflection;
using System.Runtime.Loader;

string dllPath = Environment.GetEnvironmentVariable("DOMAIN_SET_DLL")
    ?? throw new InvalidOperationException("DOMAIN_SET_DLL is not set");
string dllDir = Path.GetDirectoryName(Path.GetFullPath(dllPath))!;

AssemblyLoadContext.Default.Resolving += (context, name) =>
{
    string candidate = Path.Combine(dllDir, name.Name + ".dll");
    return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
};

Type type = Assembly.LoadFrom(dllPath).GetType("AdvancedBlocking.App+DomainSet", throwOnError: true)!;
const BindingFlags All = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

int failures = 0;

void Check(bool ok, string what)
{
    if (ok)
    {
        Console.WriteLine($"ok: {what}");
    }
    else
    {
        failures++;
        Console.Error.WriteLine($"FAIL: {what}");
    }
}

object Create() => Activator.CreateInstance(type, All, null, Array.Empty<object>(), null)!;
void EnsureCapacity(object set, int capacity) => type.GetMethod("EnsureCapacity", All)!.Invoke(set, new object[] { capacity });
void Add(object set, string domain) => type.GetMethod("Add", All)!.Invoke(set, new object[] { domain });
void Seal(object set) => type.GetMethod("Seal", All)!.Invoke(set, null);
bool Contains(object set, string domain) => (bool)type.GetMethod("Contains", All)!.Invoke(set, new object[] { domain })!;
int Count(object set) => (int)type.GetProperty("Count", All)!.GetValue(set)!;

object Build(params string[] names)
{
    object set = Create();
    foreach (string name in names)
        Add(set, name);
    Seal(set);
    return set;
}

static string Name(params int[] labels) => string.Join(".", labels.Select(n => new string('a', n)));

Check(!Contains(Build(), "x.example"), "an empty set sealed contains nothing");
Check(!Contains(Build(), ""), "an empty set does not contain the empty name");
Check(!Contains(Create(), "x.example"), "an unsealed empty set contains nothing");

object single = Build("example.com");
Check(Contains(single, "example.com") && !Contains(single, "example.co") && !Contains(single, "xexample.com")
        && !Contains(single, "ample.com") && !Contains(single, "example.com.") && !Contains(single, "com"),
    "a one-entry set finds only the entry, not its prefixes, suffixes or neighbours");

object prefixed = Build("ab", "abc");
Check(Contains(prefixed, "ab") && Contains(prefixed, "abc") && !Contains(prefixed, "a")
        && !Contains(prefixed, "abcd") && !Contains(prefixed, "abd") && !Contains(prefixed, "b"),
    "entries that are prefixes of each other stay distinct");

object emptyName = Build("");
Check(Contains(emptyName, "") && !Contains(emptyName, "a") && Count(emptyName) == 1,
    "the empty name (root) is stored and found, and nothing else is");

object cased = Build("Edge.Example");
Check(Contains(cased, "Edge.Example") && !Contains(cased, "edge.example"),
    "membership is ordinal, so case is significant");

object mixed = Build("a-b.example", "a_b.example", "a/b.example", "*.example", "0.9");
Check(Contains(mixed, "a-b.example") && Contains(mixed, "a_b.example") && Contains(mixed, "a/b.example")
        && Contains(mixed, "*.example") && Contains(mixed, "0.9") && !Contains(mixed, "a.b.example"),
    "hyphen, underscore, slash, wildcard label and digits are stored and found");

string n253 = Name(63, 63, 63, 61);
string n254 = Name(63, 63, 63, 62);
string n255 = Name(63, 63, 63, 63);
Check(n253.Length == 253 && n254.Length == 254 && n255.Length == 255, "test names have the expected lengths");
object longest = Build(n253, n254, n255, "short.example");
Check(Contains(longest, n253) && Contains(longest, n254) && Contains(longest, n255) && Contains(longest, "short.example"),
    "names of 253, 254 and 255 characters (the largest length byte is 255) are stored and found");
Check(!Contains(longest, n255 + "a") && !Contains(longest, new string('a', 400)),
    "a query over 255 characters is not found and does not throw");

object populated = Build("example.com", "ads.example.net", "tracker.test");
string[] foreign =
{
    "exámple.com", "例え.jp", "ex\0mple.com", "ex?mple.com", "\ud800.example", "example.com\u00e9",
    new string('\u00e9', 255), "EXAMPLE.COM",
};
foreach (string probe in foreign)
{
    bool found;
    try
    {
        found = Contains(populated, probe);
    }
    catch (Exception ex)
    {
        Check(false, $"query {probe.Length} chars threw {ex.GetType().Name}");
        continue;
    }
    Check(!found, $"a query the parsers never store is not found ({probe.Length} chars, first char U+{(int)probe[0]:X4})");
}

object duplicated = Build("a.example", "b.example", "a.example", "a.example");
Check(Count(duplicated) == 4 && Contains(duplicated, "a.example") && Contains(duplicated, "b.example")
        && !Contains(duplicated, "c.example"),
    "Count keeps the raw parser count and duplicates do not break lookups");

object grown = Create();
for (int i = 0; i < 5000; i++)
    Add(grown, $"grow-{i}.example");
Seal(grown);
bool allFound = true;
for (int i = 0; i < 5000 && allFound; i++)
    allFound = Contains(grown, $"grow-{i}.example");
Check(Count(grown) == 5000 && allFound && !Contains(grown, "grow-5000.example"),
    "5000 entries added past the initial buffer are all found, the next one is not");

object preSized = Create();
EnsureCapacity(preSized, 1 << 20);
for (int i = 0; i < 100; i++)
    Add(preSized, $"pre-{i}.example");
Seal(preSized);
Check(Enumerable.Range(0, 100).All(i => Contains(preSized, $"pre-{i}.example")) && !Contains(preSized, "pre-100.example"),
    "a pre-sized buffer larger than the names is trimmed correctly by Seal");

string common = new('a', 240);
List<string> longNames = Enumerable.Range(0, 100).Select(i => common + i.ToString("D3")).ToList();
object longShared = Build(longNames.ToArray());
Check(longNames.All(n => Contains(longShared, n)) && !Contains(longShared, common)
        && !Contains(longShared, common + "100") && !Contains(longShared, common + "00") && !Contains(longShared, common + "0000"),
    "entries sharing 240 bytes are all found, and their prefix and neighbours are not");

// set sizes around the bucket count (count / 4) and a few that put several names in one bucket
foreach (int size in new[] { 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 63, 64, 65, 1000 })
{
    object set = Create();
    for (int i = 0; i < size; i++)
        Add(set, $"n{i}.size{size}.example");
    Seal(set);
    bool ok = Enumerable.Range(0, size).All(i => Contains(set, $"n{i}.size{size}.example"))
        && !Contains(set, $"n{size}.size{size}.example") && !Contains(set, $"n0.size{size + 1}.example");
    if (!ok)
        Check(false, $"set of {size} names");
}
Console.WriteLine("ok: sets of 1 to 1000 names (around every bucket-count boundary) find all names and no neighbours");

static string RandomName(Random rng, string alphabet, int maxLabels, int maxLabelLength)
{
    int labels = rng.Next(1, maxLabels + 1);
    return string.Join(".", Enumerable.Range(0, labels)
        .Select(_ => new string(Enumerable.Range(0, rng.Next(1, maxLabelLength + 1)).Select(__ => alphabet[rng.Next(alphabet.Length)]).ToArray())));
}

Random rng = new Random(20261102);
foreach ((string alphabet, int entries, int probes) in new[] { ("abc", 3000, 100000), ("abcdefghijklmnopqrstuvwxyz0123456789-_", 200000, 400000) })
{
    HashSet<string> model = new HashSet<string>();
    object differential = Create();
    for (int i = 0; i < entries; i++)
    {
        string name = RandomName(rng, alphabet, 4, alphabet.Length == 3 ? 4 : 12);
        model.Add(name);
        Add(differential, name);
    }
    Seal(differential);
    int mismatches = 0, present = 0, absent = 0;
    for (int i = 0; i < probes; i++)
    {
        string probe = i % 3 == 0 && model.Count > 0
            ? model.ElementAt(rng.Next(model.Count))
            : RandomName(rng, alphabet, 4, alphabet.Length == 3 ? 4 : 12);
        bool expected = model.Contains(probe);
        if (Contains(differential, probe) != expected)
            mismatches++;
        if (expected)
            present++;
        else
            absent++;
    }
    Check(mismatches == 0 && present > 1000 && absent > 1000,
        $"seeded differential against HashSet<string> ({entries} entries, alphabet {alphabet.Length}): {present} present and {absent} absent probes, {mismatches} mismatches");
}

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} boundary check(s) failed");
    return 1;
}

Console.WriteLine("all bucketed DomainSet boundary checks passed");
return 0;
EOF

out_file=${NAME_SET_OUT:-results/exact-csr.boundary.txt}
mkdir -p results
{
	printf 'variant: exact-csr\n'
	printf 'app_sha256: %s\n\n' "$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)"
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		-e HOME=/tmp -e DOTNET_CLI_HOME=/tmp/dotnet -e DOTNET_NOLOGO=1 \
		-e DOMAIN_SET_DLL=/test/AdvancedBlockingApp.dll \
		-v "$tmp":/test -w /test \
		mcr.microsoft.com/dotnet/sdk:10.0 \
		dotnet run --project name-set-test.csproj -c Release 2>&1
} | tee "$out_file"
