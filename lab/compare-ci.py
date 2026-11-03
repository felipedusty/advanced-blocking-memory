#!/usr/bin/env python3
"""Compare the lab artifacts of the original and the candidate; fail on any behavioural difference."""
import json
import os
import statistics
import sys

ROOT = "results"
REPORT_SAMPLE = 500
LATENCY_ROUNDS = 3  # rounds per variant run by lab/latency-rounds.sh
CANDIDATE = os.environ.get("CANDIDATE", "")  # set by the workflow: hash or exact
TITLE = "## Lab" + (f" ({CANDIDATE})" if CANDIDATE else "")

problems = []
notes = []
summary_written = False


def load(name):
    try:
        with open(f"{ROOT}/{name}") as f:
            return json.load(f)
    except (OSError, ValueError) as exc:
        fail([*problems, f"cannot read {name}: {exc}"])


def load_text(name):
    try:
        with open(f"{ROOT}/{name}") as f:
            return f.read()
    except (OSError, ValueError) as exc:
        fail([*problems, f"cannot read {name}: {exc}"])


def mib(value):
    return f"{value / 1048576:.1f} MiB"


def rcodes(value):
    if not isinstance(value, dict):
        return repr(value)
    return ", ".join(f"{rcode}:{count}" for rcode, count in sorted(value.items()))


def require(condition, message):
    if not condition:
        problems.append(message)


def require_size(condition, message):
    # experiments run with SIZE_GATES=report: the memory thresholds are listed, not enforced
    if not condition:
        (notes if os.environ.get("SIZE_GATES") == "report" else problems).append(message)


def fail(messages):
    for message in messages:
        print(f"FAIL: {message}", file=sys.stderr)
    if not summary_written:
        body = TITLE + "\n\n**Failed gates**\n\n" + "".join(
            f"- {message}\n" for message in messages
        )
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a") as f:
                f.write(body)
    raise SystemExit(1)


def check_keys(label, row, keys):
    missing = [key for key in keys if key not in row]
    if missing:
        fail([f"{label} artifact misses keys {missing}"])


runs_raw = os.environ.get("STARTUP_RUNS", "3")
try:
    runs = int(runs_raw)
except ValueError:
    fail([f"STARTUP_RUNS is not an integer: {runs_raw!r}"])
if runs < 1:
    fail([f"STARTUP_RUNS must be at least 1, got {runs}"])
expected_lists = len(load_text("lists.sha256").splitlines())
if expected_lists <= 0:
    fail(["lists.sha256 is empty"])
orig_runs = [load(f"original-run{i}.json") for i in range(1, runs + 1)]
pat_runs = [load(f"patched-run{i}.json") for i in range(1, runs + 1)]

RUN_KEYS = (
    "lists_expected",
    "lists_parsed",
    "peak_bytes",
    "cgroup_memory_peak_bytes",
    "app_sha256",
    "image",
    "grace_s",
    "memory_limit",
    "memory_swap",
)
for name, rows in (("original", orig_runs), ("patched", pat_runs)):
    for row in rows:
        check_keys(f"{name} startup", row, RUN_KEYS)

for name, rows in (("original", orig_runs), ("patched", pat_runs)):
    for row in rows:
        require(
            row["lists_expected"] == expected_lists,
            f"{name} lists expected {row['lists_expected']} != {expected_lists}",
        )
        require(
            row["lists_parsed"] == row["lists_expected"],
            f"{name} lists parsed {row['lists_parsed']} != expected {row['lists_expected']}",
        )
        require(
            row.get("memory_limit") == "none",
            f"{name} memory limit {row.get('memory_limit')!r} != 'none'",
        )
        require(
            row.get("memory_swap") == "none",
            f"{name} memory swap {row.get('memory_swap')!r} != 'none'",
        )
    for key in ("app_sha256", "image", "grace_s"):
        values = {row.get(key) for row in rows}
        require(
            len(values) == 1,
            f"{name} startup runs mix {key}: {sorted(values)!r}",
        )

orig_peaks = [max(row["peak_bytes"], row["cgroup_memory_peak_bytes"]) for row in orig_runs]
pat_peaks = [max(row["peak_bytes"], row["cgroup_memory_peak_bytes"]) for row in pat_runs]
orig_med = statistics.median(orig_peaks)
pat_med = statistics.median(pat_peaks)
require_size(
    pat_med < orig_med * 0.6,
    f"startup peak not lower enough: {mib(pat_med)} vs {mib(orig_med)}",
)
require(
    orig_runs[0]["app_sha256"] != pat_runs[0]["app_sha256"],
    "original and candidate use the same app assembly",
)

reload_orig = load("reload-original-reload.json")
reload_pat = load("reload-patched-reload.json")
RELOAD_KEYS = ("lists_expected", "list_reads_total", "peak_bytes", "cgroup_memory_peak_bytes")
for name, row in (("original", reload_orig), ("patched", reload_pat)):
    check_keys(f"reload {name}", row, RELOAD_KEYS)
reload_reads = 2 * expected_lists
for name, row in (("original", reload_orig), ("patched", reload_pat)):
    require(
        row["lists_expected"] == expected_lists,
        f"reload {name} lists expected {row['lists_expected']} != {expected_lists}",
    )
    require(
        row["list_reads_total"] == reload_reads,
        f"reload {name} list reads {row['list_reads_total']} != {reload_reads}",
    )
    require(
        row.get("memory_limit") == "none",
        f"reload {name} memory limit {row.get('memory_limit')!r} != 'none'",
    )
    require(
        row.get("memory_swap") == "none",
        f"reload {name} memory swap {row.get('memory_swap')!r} != 'none'",
    )
reload_orig_peak = max(reload_orig["peak_bytes"], reload_orig["cgroup_memory_peak_bytes"])
reload_pat_peak = max(reload_pat["peak_bytes"], reload_pat["cgroup_memory_peak_bytes"])
require_size(
    reload_pat_peak < reload_orig_peak * 0.6,
    f"reload peak not lower enough: {mib(reload_pat_peak)} vs {mib(reload_orig_peak)}",
)

# check-function.sh writes one line per sampled domain: the domain, a tab, and
# the TXT report (empty when the app did not answer). Identical files mean the
# parser kept the same decision and the same source list for every sample.
report_suffix = f"-run{runs}.reports.txt"
reports_orig = load_text(f"original{report_suffix}")
reports_pat = load_text(f"patched{report_suffix}")
report_lines = reports_orig.splitlines()
report_lines_pat = reports_pat.splitlines()
require(reports_orig == reports_pat, f"functional reports differ: {report_suffix}")
require(
    len(report_lines) == REPORT_SAMPLE and len(report_lines_pat) == REPORT_SAMPLE,
    f"functional sample {len(report_lines)}/{len(report_lines_pat)} lines != {REPORT_SAMPLE}",
)
report_blocked = sum("source=advanced-blocking-app" in line for line in report_lines)
report_blocked_pat = sum("source=advanced-blocking-app" in line for line in report_lines_pat)
require(
    report_blocked == REPORT_SAMPLE,
    f"expected {REPORT_SAMPLE} blocked functional reports, got {report_blocked}",
)

run_orig = load("original-exhaustive.json")
run_pat = load("patched-exhaustive.json")
for name, row in (("original", run_orig), ("patched", run_pat)):
    check_keys(f"{name} exhaustive run", row, ("lists_expected", "app_sha256"))
    require(
        row["lists_expected"] == expected_lists,
        f"{name} exhaustive lists expected {row['lists_expected']} != {expected_lists}",
    )
    require(
        row["lists_parsed"] == row["lists_expected"],
        f"{name} exhaustive lists parsed {row['lists_parsed']} != expected {row['lists_expected']}",
    )
require(
    run_orig["app_sha256"] != run_pat["app_sha256"],
    "exhaustive run used the same app assembly",
)

exh_orig = load("original-exhaustive.exhaustive.json")
exh_pat = load("patched-exhaustive.exhaustive.json")
exhaustive_keys = (
    "domains",
    "answers",
    "blocked",
    "unblocked",
    "unblocked_answers",
    "errors",
    "digest",
    "limit",
    "txt_mode",
    "txt_answers",
    "txt_blocked",
    "txt_unblocked",
    "txt_errors",
    "txt_digest",
    "allow_covered",
    "allow_answers",
    "allow_reported",
    "allow_errors",
    "allow_digest",
    "list_counts",
)
missing = sorted(
    {key for key in exhaustive_keys if key not in exh_orig}
    | {key for key in exhaustive_keys if key not in exh_pat}
)
require(not missing, f"old-format exhaustive artifact, missing: {', '.join(missing)}")
for key in exhaustive_keys:
    if key in exh_orig and key in exh_pat:
        require(
            exh_orig[key] == exh_pat[key],
            f"exhaustive {key} differs: {exh_orig[key]!r} vs {exh_pat[key]!r}",
        )
require(exh_orig.get("limit") == 0, f"exhaustive limit {exh_orig.get('limit')} != 0")
require(exh_orig.get("domains", 0) > 0, "exhaustive pass covered no domains")
require(
    exh_orig.get("variant") == "original" and exh_pat.get("variant") == "patched",
    "exhaustive variants are swapped or wrong",
)
require(
    exh_orig.get("txt_mode") == "full",
    f"exhaustive TXT mode {exh_orig.get('txt_mode')} != full",
)
require(
    exh_orig.get("errors") == 0 and exh_orig.get("answers") == exh_orig.get("domains"),
    f"exhaustive errors {exh_orig.get('errors')}, answers {exh_orig.get('answers')}, "
    f"domains {exh_orig.get('domains')}",
)
require(
    exh_orig.get("blocked") == exh_orig.get("domains") and exh_orig.get("unblocked") == 0,
    f"exhaustive A pass not fully blocked: {exh_orig.get('blocked')} blocked, "
    f"{exh_orig.get('unblocked')} unblocked of {exh_orig.get('domains')}",
)
require(
    not exh_orig.get("unblocked_answers"),
    f"exhaustive unblocked answers: {exh_orig.get('unblocked_answers')!r}",
)
require(
    exh_orig.get("txt_answers") == exh_orig.get("domains")
    and exh_orig.get("txt_blocked", 0) + exh_orig.get("txt_unblocked", -1)
    == exh_orig.get("domains"),
    f"exhaustive TXT answers {exh_orig.get('txt_answers')} != domains "
    f"{exh_orig.get('domains')}, or blocked {exh_orig.get('txt_blocked')} + "
    f"unblocked {exh_orig.get('txt_unblocked')} do not add up",
)
# A name whose label is longer than the DNS limit cannot match a list suffix.
# Both builds leave the same names unblocked; that identity is the gate, not a
# zero count, so a real regression on either side still fails.
require(
    exh_orig.get("txt_unblocked") == 0
    or exh_orig.get("txt_unblocked_answers") == exh_pat.get("txt_unblocked_answers"),
    f"exhaustive TXT unblocked differ: "
    f"{exh_orig.get('txt_unblocked_answers')!r} vs "
    f"{exh_pat.get('txt_unblocked_answers')!r}",
)
require(
    exh_orig.get("txt_errors") == 0,
    f"exhaustive TXT errors {exh_orig.get('txt_errors')}",
)
require(
    exh_orig.get("allow_covered", 0) > 0,
    "exhaustive allow pass covered no domains",
)
require(
    exh_orig.get("allow_answers") == exh_orig.get("allow_covered")
    and exh_pat.get("allow_answers") == exh_pat.get("allow_covered"),
    f"exhaustive allow answers {exh_orig.get('allow_answers')}/"
    f"{exh_pat.get('allow_answers')} != covered "
    f"{exh_orig.get('allow_covered')}/{exh_pat.get('allow_covered')}",
)
require(
    exh_orig.get("allow_reported") == 0 and exh_pat.get("allow_reported") == 0,
    f"exhaustive allow pass reported blocks: "
    f"{exh_orig.get('allow_reported')}/{exh_pat.get('allow_reported')}",
)
require(
    exh_orig.get("allow_errors") == 0 and exh_pat.get("allow_errors") == 0,
    f"exhaustive allow errors {exh_orig.get('allow_errors')}/"
    f"{exh_pat.get('allow_errors')}",
)
for name, row in (("original", exh_orig), ("patched", exh_pat)):
    require(
        len(row.get("list_counts", [])) == run_orig["lists_expected"],
        f"exhaustive {name} list counts {len(row.get('list_counts', []))} "
        f"!= {run_orig['lists_expected']}",
    )

with open("lab/config/dnsApp.config") as config_file:
    config = json.load(config_file)
allow_urls = {
    url
    for group in config["groups"]
    for url in group.get("allowListUrls", [])
}
for name, row in (("original", exh_orig), ("patched", exh_pat)):
    empty = [
        url
        for count, url in row.get("list_counts", [])
        if count == 0 and url not in allow_urls
    ]
    require(
        not empty,
        f"exhaustive {name} block list(s) parsed to 0 domains: {empty}",
    )

edge_orig = load_text("original-edge.edge.txt")
edge_pat = load_text("patched-edge.edge.txt")
require(edge_orig == edge_pat, "edge-case reports differ")
edge_blocked = sum("source=advanced-blocking-app" in line for line in edge_orig.splitlines())
edge_blocked_pat = sum("source=advanced-blocking-app" in line for line in edge_pat.splitlines())
require(edge_blocked == 12, f"expected 12 blocked edge domains, got {edge_blocked}")
require(edge_blocked_pat == 12, f"expected 12 blocked edge domains, got {edge_blocked_pat}")

for name in ("original", "patched"):
    state = load_text(f"{name}-exhaustive.pass.state.txt")
    require(
        "oom_killed=false" in state and "exit_code=0" in state,
        f"{name} exhaustive container state is not clean: {state!r}",
    )

nm_orig = load("original-near-miss.near-miss.json")
nm_pat = load("patched-near-miss.near-miss.json")
NEAR_MISS_KEYS = (
    "variant",
    "names",
    "answers",
    "errors",
    "blocked",
    "forwarded",
    "other",
    "retried",
    "model_mismatches",
    "digest",
    "per_kind",
)
for name, row in (("original", nm_orig), ("patched", nm_pat)):
    check_keys(f"{name} near-miss", row, NEAR_MISS_KEYS)
for key in ("names", "blocked", "forwarded", "digest", "per_kind"):
    require(
        nm_orig[key] == nm_pat[key],
        f"near-miss {key} differs: {nm_orig[key]!r} vs {nm_pat[key]!r}",
    )
require(
    nm_orig["variant"] == "original" and nm_pat["variant"] == "patched",
    "near-miss variants are swapped or wrong",
)
for name, row in (("original", nm_orig), ("patched", nm_pat)):
    require(
        row["names"] > 0 and row["errors"] == 0 and row["answers"] == row["names"],
        f"near-miss {name}: {row['errors']} errors, {row['answers']} answers for {row['names']} names",
    )
    require(row["other"] == 0, f"near-miss {name} has {row['other']} undecided names")
    require(
        row["model_mismatches"] == 0,
        f"near-miss {name} disagrees with the list model on {row['model_mismatches']} names",
    )
require(
    nm_orig["blocked"] > 0 and nm_orig["forwarded"] > 0,
    "near-miss names reached only one kind of decision",
)

LATENCY_KEYS = ("queries", "errors", "p50_us", "p99_us", "qps")
lat_rounds = {}
for name in ("original", "patched"):
    rows = [load(f"lat-{name}-{n}.latency.json") for n in range(1, LATENCY_ROUNDS + 1)]
    for row in rows:
        check_keys(f"{name} latency", row, LATENCY_KEYS)
        require(
            row.get("queries", 0) > 0,
            f"{name} latency has no queries: {row.get('queries')!r}",
        )
        require(
            row.get("errors", -1) == 0,
            f"{name} latency errors: {row.get('errors')!r}",
        )
    lat_rounds[name] = rows
latency_queries = {row["queries"] for rows in lat_rounds.values() for row in rows}
require(
    len(latency_queries) == 1,
    f"latency query counts differ across rounds or variants: {sorted(latency_queries)!r}",
)


def lat_median(name, key):
    return statistics.median(row[key] for row in lat_rounds[name])


def lat_range(name, key):
    values = [row[key] for row in lat_rounds[name]]
    return f"{min(values)}–{max(values)}"

summary = [
    TITLE,
    "",
    "| Metric | original | candidate |",
    "|---|---|---|",
    f"| startup peak, median of {runs} | {mib(orig_med)} | {mib(pat_med)} |",
    f"| startup peak, min–max | {mib(min(orig_peaks))}–{mib(max(orig_peaks))} | {mib(min(pat_peaks))}–{mib(max(pat_peaks))} |",
    f"| reload peak | {mib(reload_orig_peak)} | {mib(reload_pat_peak)} |",
    f"| reload list reads | {reload_orig['list_reads_total']} | {reload_pat['list_reads_total']} |",
    f"| lists parsed | {orig_runs[-1]['lists_parsed']}/{orig_runs[-1]['lists_expected']} | {pat_runs[-1]['lists_parsed']}/{pat_runs[-1]['lists_expected']} |",
    f"| functional reports ({REPORT_SAMPLE}) | {report_blocked} blocked | {report_blocked_pat} blocked |",
    f"| exhaustive limit | {exh_orig.get('limit')} | {exh_pat.get('limit')} |",
    f"| exhaustive A domains | {exh_orig.get('domains')} | {exh_pat.get('domains')} |",
    f"| exhaustive A blocked | {exh_orig.get('blocked')} | {exh_pat.get('blocked')} |",
    f"| exhaustive A digest | `{exh_orig.get('digest')}` | `{exh_pat.get('digest')}` |",
    f"| exhaustive TXT mode | {exh_orig.get('txt_mode')} | {exh_pat.get('txt_mode')} |",
    f"| exhaustive TXT domains | {exh_orig.get('txt_answers')} | {exh_pat.get('txt_answers')} |",
    f"| exhaustive TXT blocked | {exh_orig.get('txt_blocked')} | {exh_pat.get('txt_blocked')} |",
    f"| exhaustive TXT digest | `{exh_orig.get('txt_digest')}` | `{exh_pat.get('txt_digest')}` |",
    f"| exhaustive allow domains | {exh_orig.get('allow_covered')} | {exh_pat.get('allow_covered')} |",
    f"| exhaustive allow reported | {exh_orig.get('allow_reported')} | {exh_pat.get('allow_reported')} |",
    f"| exhaustive allow digest | `{exh_orig.get('allow_digest')}` | `{exh_pat.get('allow_digest')}` |",
    f"| exhaustive retried A/TXT/allow | {exh_orig.get('retried', 0)}/{exh_orig.get('txt_retried', 0)}/{exh_orig.get('allow_retried', 0)} | {exh_pat.get('retried', 0)}/{exh_pat.get('txt_retried', 0)}/{exh_pat.get('allow_retried', 0)} |",
    f"| allow rcodes (rcode:count) | {rcodes(exh_orig.get('allow_rcodes'))} | {rcodes(exh_pat.get('allow_rcodes'))} |",
    f"| exhaustive list counts | {len(exh_orig.get('list_counts', []))} | {len(exh_pat.get('list_counts', []))} |",
    f"| edge blocked | {edge_blocked} | {edge_blocked_pat} |",
    f"| near-miss names | {nm_orig['names']} | {nm_pat['names']} |",
    f"| near-miss blocked / forwarded | {nm_orig['blocked']} / {nm_orig['forwarded']} | {nm_pat['blocked']} / {nm_pat['forwarded']} |",
    f"| near-miss undecided answers retried | {nm_orig['retried']} | {nm_pat['retried']} |",
    f"| near-miss model mismatches | {nm_orig['model_mismatches']} | {nm_pat['model_mismatches']} |",
    f"| near-miss digest | `{nm_orig['digest']}` | `{nm_pat['digest']}` |",
    f"| latency p50 µs, median of {LATENCY_ROUNDS} | {lat_median('original', 'p50_us')} | {lat_median('patched', 'p50_us')} |",
    f"| latency p99 µs, median of {LATENCY_ROUNDS} | {lat_median('original', 'p99_us')} | {lat_median('patched', 'p99_us')} |",
    f"| latency qps, median of {LATENCY_ROUNDS} | {lat_median('original', 'qps')} | {lat_median('patched', 'qps')} |",
    f"| latency qps, min–max | {lat_range('original', 'qps')} | {lat_range('patched', 'qps')} |",
]
if problems:
    summary += ["", "**Failed gates**", ""] + [f"- {message}" for message in problems]
if notes:
    summary += ["", "**Size gates not met (reported only)**", ""] + [f"- {message}" for message in notes]
text = "\n".join(summary) + "\n"
summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_path:
    with open(summary_path, "a") as f:
        f.write(text)
print(text)
summary_written = True

if problems:
    for message in problems:
        print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)
