#!/usr/bin/env bash
# Tests for the hash sets in the built Advanced Blocking app (HASH_BITS=64 or 128).
#
# GetDomainHash and the HashSet<key> overload of IsZoneFound are private, so the
# test loads the real assembly and drives them through reflection. It checks that
# the hash is the canonical FNV-1a-64 (public test vectors) started from the
# process's random basis, and for 128 bits a second lane with the golden-ratio
# multiplier against values computed independently; that membership through the
# app's own IsZoneFound agrees with a HashSet<string> on a seeded differential
# (parent walk, case, near misses); and, by running twice, that the basis changes
# with the process.
#
#   HASH_BITS=128 lab/hash-test.sh [patched]   (default 64, variant patched)
#
# Requires lab/.work/out-<variant> (lab/build-app.sh) and the .NET SDK image.
set -euo pipefail
cd "$(dirname "$0")/.."

variant=${1:-patched}
case "$variant" in
original)
	echo "original has no hash sets; use patched" >&2
	exit 2
	;;
patched) ;;
*)
	echo "usage: $0 [patched]" >&2
	exit 2
	;;
esac

bits=${HASH_BITS:-64}
case "$bits" in
64) wide=0 ;;
128) wide=1 ;;
*)
	echo "HASH_BITS must be 64 or 128, got '$bits'" >&2
	exit 2
	;;
esac

out=lab/.work/out-$variant
[ -f "$out/AdvancedBlockingApp.dll" ] || {
	echo "missing $out/AdvancedBlockingApp.dll; run lab/build-app.sh $variant" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$out"/*.dll "$tmp"/
# The declaring type implements IDnsApplication, whose base interfaces live in
# DnsServerCore.ApplicationCommon; the type lookup therefore loads that assembly.
work=$PWD/lab/.work
cp "$work/DnsServer/DnsServerCore.ApplicationCommon/bin/Release/DnsServerCore.ApplicationCommon.dll" "$tmp"/ 2>/dev/null || true
cp "$work"/TechnitiumLibrary/bin/TechnitiumLibrary.Net.dll "$tmp"/ 2>/dev/null || true
[ -f "$tmp/DnsServerCore.ApplicationCommon.dll" ] || {
	echo "missing DnsServerCore.ApplicationCommon.dll; run lab/build-app.sh $variant" >&2
	exit 1
}
[ -f "$tmp/TechnitiumLibrary.Net.dll" ] || {
	echo "missing TechnitiumLibrary.Net.dll; run lab/build-app.sh $variant" >&2
	exit 1
}

cat >"$tmp/hash-test.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>hash-test</AssemblyName>
    <DefineConstants Condition="'$(HASH_WIDE)' == '1'">$(DefineConstants);WIDE</DefineConstants>
  </PropertyGroup>
</Project>
EOF

cat >"$tmp/Program.cs" <<'EOF'
#if WIDE
using Key = (ulong, ulong);
#else
using Key = ulong;
#endif
using System.Reflection;
using System.Runtime.Loader;

string dllPath = Environment.GetEnvironmentVariable("HASH_TEST_DLL")
    ?? throw new InvalidOperationException("HASH_TEST_DLL is not set");
string dllDir = Path.GetDirectoryName(Path.GetFullPath(dllPath))!;

AssemblyLoadContext.Default.Resolving += (context, name) =>
{
    string candidate = Path.Combine(dllDir, name.Name + ".dll");
    return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
};

Type app = Assembly.LoadFrom(dllPath).GetType("AdvancedBlocking.App", throwOnError: true)!;
const BindingFlags Static = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;

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

MethodInfo hashMethod = app.GetMethod("GetDomainHash", Static)
    ?? throw new InvalidOperationException("GetDomainHash was not found: is this the hash patch?");
Func<string, Key> hash = (Func<string, Key>)Delegate.CreateDelegate(typeof(Func<string, Key>), hashMethod);
#if WIDE
ulong basis1 = (ulong)app.GetField("_domainHashBasis1", Static)!.GetValue(null)!;
ulong basis2 = (ulong)app.GetField("_domainHashBasis2", Static)!.GetValue(null)!;
Key basis = (basis1, basis2);
Console.WriteLine($"basis={basis1:x16}:{basis2:x16}");
#else
ulong basis = (ulong)app.GetField("_domainHashBasis", Static)!.GetValue(null)!;
Console.WriteLine($"basis={basis:x16}");
#endif

MethodInfo findMethod = app.GetMethods(Static)
    .Single(m => m.Name == "IsZoneFound" && m.GetParameters()[0].ParameterType == typeof(HashSet<Key>));

(bool, string?) Find(HashSet<Key> set, string domain)
{
    object?[] arguments = [set, domain, null];
    bool found = (bool)findMethod.Invoke(null, arguments)!;
    return (found, (string?)arguments[2]);
}

static ulong Fnv(ulong start, string s, ulong mul = 1099511628211UL)
{
    ulong h = start;
    foreach (char c in s)
        h = unchecked((h ^ c) * mul);

    return h;
}

const ulong Golden = 11400714819323198485UL;

static Key Ref(Key basis, string s) =>
#if WIDE
    (Fnv(basis.Item1, s), Fnv(basis.Item2, s, Golden));
#else
    Fnv(basis, s);
#endif

static string? Parent(string d)
{
    int i = d.IndexOf('.');
    return i > -1 ? d.Substring(i + 1) : null;
}

(bool, string?) Model(HashSet<string> set, string domain)
{
    string? d = domain;
    do
    {
        if (set.Contains(d))
            return (true, d);

        d = Parent(d);
    }
    while (d is not null);

    return (false, null);
}

// the reference is the canonical FNV-1a-64: public vectors from the FNV reference and the fnv1a-64 package
const ulong Standard = 0xcbf29ce484222325UL;
Check(Fnv(Standard, "") == Standard, "reference: the empty string hashes to the standard basis");
Check(Fnv(Standard, "a") == 0xaf63dc4c8601ec8cUL, "reference: 'a' is the published FNV-1a-64 vector");
Check(Fnv(Standard, "foobar") == 0x85944171f73967e8UL, "reference: 'foobar' is the published FNV-1a-64 vector");
Check(Fnv(Standard, "hello world") == 0x779a65e7023cd2e7UL, "reference: 'hello world' is the vector of the fnv1a-64 package");

#if WIDE
Check((basis1 & 1) == 1 && (basis2 & 1) == 1 && basis1 != Standard && basis2 != Standard && basis1 != basis2, "both bases are odd, differ from each other and from the published constant");
// the second lane has no public vectors: these were computed independently (Python integers, same recurrence)
Check(Fnv(Standard, "a", Golden) == 0x217350404d89d494UL, "reference: lane 2 of 'a' matches the independent computation");
Check(Fnv(Standard, "foobar", Golden) == 0x2bf86ed5c6f03a96UL, "reference: lane 2 of 'foobar' matches the independent computation");
Check(Fnv(Standard, "hello world", Golden) == 0x6484863ea6ede321UL, "reference: lane 2 of 'hello world' matches the independent computation");
Check(Golden == 0x9E3779B97F4A7C15UL && (Golden & 1) == 1, "the second multiplier is the odd 64-bit golden ratio constant");
#else
Check((basis & 1) == 1 && basis != Standard, "the basis is odd and is not the published constant");
#endif

// the app's function is the reference started from its own basis
Random rng = new Random(20261101);
string RandomChars(int length, string alphabet) => new string(Enumerable.Range(0, length).Select(_ => alphabet[rng.Next(alphabet.Length)]).ToArray());

List<string> samples =
[
    "", "a", "A", "example.com", "Example.COM", new string('a', 255), string.Join(".", Enumerable.Repeat("a", 127)),
    new string('z', 1000), "é.example", "日本語.example", "😀.example", "xn--bcher-kva.example",
];
for (int c = 0; c < 128; c++)
    samples.Add(((char)c).ToString());

for (int i = 0; i < 20000; i++)
    samples.Add(RandomChars(rng.Next(1, 64), "abcdefghijklmnopqrstuvwxyz0123456789-._"));

Check(samples.All(s => hash(s) == Ref(basis, s)), $"GetDomainHash equals the reference from its basis on {samples.Count:N0} names (empty, 255 and 1000 characters, non-ASCII, every ASCII character)");
Check(hash("") == basis, "the empty name hashes to the basis");
Check(hash("example.com") != hash("Example.com") && hash("a") != hash("A"), "the hash is case sensitive, like the ordinal HashSet<string>");
Check(hash("é.example") != hash("e.example") && hash("日本語.example") != hash("😀.example"), "non-ASCII names hash apart");

HashSet<string> distinct = new HashSet<string>(Enumerable.Range(0, 200_000).Select(i => RandomChars(rng.Next(3, 30), "abcdefghijklmnopqrstuvwxyz0123456789-.") + i));
Check(distinct.Select(hash).ToHashSet().Count == distinct.Count, $"no collision among {distinct.Count:N0} distinct random names");

// membership through the app's own IsZoneFound, against a HashSet<string>
HashSet<Key> tiny = [hash("example.com")];
Check(Find(tiny, "a.b.example.com") == (true, "example.com"), "a subdomain is found through its parent, with the parent as the found zone");
Check(Find(tiny, "example.org") == (false, null) && Find(tiny, "com") == (false, null), "other names and the parent of a listed name are not found");
HashSet<Key> comOnly = [hash("com")];
Check(Find(comOnly, "a.com") == (true, "com") && Find(comOnly, "com") == (true, "com"), "a listed top-level name matches itself and its subdomains");
HashSet<Key> cased = [hash("Edge.Example")];
Check(Find(cased, "Edge.Example") == (true, "Edge.Example") && Find(cased, "edge.example") == (false, null), "membership is ordinal, so case is significant");
HashSet<Key> empty = [];
Check(Find(empty, "a.b") == (false, null) && Find(empty, "") == (false, null), "an empty set finds nothing");
HashSet<Key> emptyName = [hash("")];
Check(Find(emptyName, "") == (true, ""), "the empty name is found when it is listed");
Check(Find(tiny, new string('a', 255)) == (false, null) && Find(tiny, string.Join(".", Enumerable.Repeat("a", 127))) == (false, null), "255-character names are handled");

string Label(int max) => RandomChars(rng.Next(1, max + 1), "abc");
string RandomName() => string.Join(".", Enumerable.Range(0, rng.Next(1, 5)).Select(_ => Label(4)));

HashSet<string> model = [];
HashSet<Key> hashed = [];
for (int i = 0; i < 3000; i++)
{
    string name = RandomName();
    model.Add(name);
    hashed.Add(hash(name));
}

List<string> probes = [];
for (int i = 0; i < 100_000; i++)
    probes.Add(RandomName());

foreach (string entry in model.Take(20_000))
{
    probes.Add(entry.ToUpperInvariant());
    probes.Add("x" + entry);
    probes.Add(entry + "x");
    probes.Add("sub." + entry);
    if (entry.Length > 1)
    {
        probes.Add(entry.Substring(1));
        probes.Add(entry.Substring(0, entry.Length - 1));
    }
}

int mismatches = 0, present = 0, absent = 0;
foreach (string probe in probes)
{
    (bool, string?) expected = Model(model, probe);
    (bool, string?) actual = Find(hashed, probe);
    if (expected != actual)
        mismatches++;

    if (expected.Item1)
        present++;
    else
        absent++;
}

Check(mismatches == 0 && present > 1000 && absent > 1000,
    $"differential against HashSet<string> through IsZoneFound: {probes.Count:N0} probes ({present:N0} found, {absent:N0} not found), found zone included, {mismatches} mismatches");

if (failures > 0)
{
    Console.Error.WriteLine($"{failures} hash check(s) failed");
    return 1;
}

Console.WriteLine("all hash checks passed");
return 0;
EOF

out_file=results/$variant.boundary.txt
mkdir -p results
run_test() {
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		-e HOME=/tmp -e DOTNET_CLI_HOME=/tmp/dotnet -e DOTNET_NOLOGO=1 -e HASH_WIDE="$wide" \
		-e HASH_TEST_DLL=/test/AdvancedBlockingApp.dll \
		-v "$tmp":/test -w /test \
		mcr.microsoft.com/dotnet/sdk:10.0 \
		dotnet run --project hash-test.csproj -c Release "$@" 2>&1
}

{
	printf 'variant: %s (%s-bit key)\n' "$variant" "$bits"
	printf 'app_sha256: %s\n\n' "$(sha256sum "$out/AdvancedBlockingApp.dll" | cut -d' ' -f1)"
	first=$(run_test) || {
		printf '%s\n' "$first"
		exit 1
	}
	printf '%s\n' "$first"
	second=$(run_test --no-build) || {
		printf '%s\n' "$second"
		exit 1
	}
	basis1=$(printf '%s\n' "$first" | sed -n 's/^basis=//p')
	basis2=$(printf '%s\n' "$second" | sed -n 's/^basis=//p')
	if [ -n "$basis1" ] && [ -n "$basis2" ] && [ "$basis1" != "$basis2" ]; then
		echo "ok: the basis changes with the process ($basis1 then $basis2)"
	else
		echo "FAIL: two processes got the same basis ('$basis1' and '$basis2')" >&2
		exit 1
	fi
} | tee "$out_file"
