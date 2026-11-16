#!/usr/bin/env bash
# =============================================================================
#  AI Warden - CI status watchdog (host driver)
# -----------------------------------------------------------------------------
#  The weekly `schedule` run is the only thing in this project that notices
#  upstream drift: a HIGH/CRITICAL landing in the Debian base, an npm float
#  moving, an agent CLI rewording its own output. It went RED for three weeks
#  (2026-10-26, 11-02, 11-09) and nothing rang - found only because a session
#  happened to run `gh run list`. A cron that nobody reads is a control that
#  reports itself armed while enforcing nothing: this project's recurring bug
#  shape, one level up from the cage.
#
#  Two halves close that hole. The alarm job in .github/workflows/ci.yml opens
#  or updates a `ci-red` issue on any failure and closes it on recovery, so the
#  issue's state IS the suite's state. This script is the other half: it is run
#  at session start (CLAUDE.md step 1) and asserts the things the alarm job
#  structurally CANNOT.
#
#    C1  the newest run on main concluded success
#    C2  a `schedule` run exists inside the window - catches a cron that never
#        fired at all (GitHub disables scheduled workflows after 60 days of
#        repo inactivity). `if: failure()` cannot alarm on a run that does not
#        exist.
#    C3  the newest `schedule` run concluded success - the weekly gate itself,
#        not just whatever was last pushed
#    C4  a failing newest run must have an open `ci-red` issue behind it - this
#        is the ALARM'S OWN WITNESS. An alarm job that 403s on a missing
#        `issues: write` goes red inside a run that was already red, where
#        nobody sees it. C4 is what makes that silence audible.
#    C5  a green newest run must leave no `ci-red` issue open - an alarm that
#        never closes trains the reader to ignore it
#
#  Every assertion checks that it got data first and says "nothing was
#  measured" when it did not: a probe that never ran looks exactly like a
#  guard that held.
#
#  Usage:  ./scripts/ci-status.sh [--self-test] [--window-days N] [--quiet]
#
#  Exit:   0  every assertion passed
#          1  an assertion failed (CI is red, or stale, or unwitnessed)
#          2  nothing could be measured (no gh, not logged in, no runs)
#         64  bad usage
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# A weekly cron plus GitHub's own queue delay. The three runs before the fix
# landed at 06:00 UTC + 6-9 hours, so a day of slack is not generous, it is
# measured.
WINDOW_DAYS=8
SELF_TEST=0
QUIET=0
CI_RED_LABEL="ci-red"
readonly CI_RED_LABEL

while [ $# -gt 0 ]; do
    case "$1" in
        --self-test)   SELF_TEST=1 ;;
        --window-days) shift; WINDOW_DAYS="${1:-}" ;;
        --quiet)       QUIET=1 ;;
        -h|--help)     sed -n '2,45p' "$0"; exit 0 ;;
        *)             printf 'unknown option: %s\n' "$1" >&2; exit 64 ;;
    esac
    shift
done

case "$WINDOW_DAYS" in
    ''|*[!0-9]*) printf '--window-days needs a whole number of days\n' >&2; exit 64 ;;
esac

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
fi

info() { [ "$QUIET" -eq 1 ] || printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
good() { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()  { printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$*"; }
note() { printf '  %s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }

FAILURES=0
UNMEASURED=0

# -----------------------------------------------------------------------------
#  Data access. Both sources are read into flat TSV so that every assertion
#  below reads the same shape, whether it came from gh or from a fixture.
#
#    runs    event <TAB> conclusion <TAB> status <TAB> age_days <TAB> id <TAB> url
#    issues  number <TAB> url <TAB> title
#
#  WARDEN_CI_FIXTURE points at a directory holding runs.json / issues.json and
#  makes the whole script offline and deterministic, which is what --self-test
#  uses to prove each assertion has teeth. WARDEN_CI_NOW pins the clock.
# -----------------------------------------------------------------------------
RUNS_TSV=""
ISSUES_TSV=""

flatten_runs() {
    # stdin: the JSON array gh returns.  stdout: TSV, newest first.
    PYTHONIOENCODING=utf-8 python3 -c '
import json, sys, os, datetime
now = os.environ.get("WARDEN_CI_NOW", "")
if now:
    ref = datetime.datetime.fromisoformat(now.replace("Z", "+00:00"))
else:
    ref = datetime.datetime.now(datetime.timezone.utc)
try:
    rows = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("runs json unreadable: %s" % exc + chr(10))
    sys.exit(3)
if not isinstance(rows, list):
    sys.stderr.write("runs json is not a list" + chr(10))
    sys.exit(3)
tab = chr(9)
out = []
for r in rows:
    created = r.get("createdAt") or ""
    try:
        age = (ref - datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))).total_seconds() / 86400.0
        age = "%.2f" % age
    except Exception:
        age = "-1"
    out.append(tab.join([
        str(r.get("event") or "?"),
        str(r.get("conclusion") or ""),
        str(r.get("status") or "?"),
        age,
        str(r.get("databaseId") or "?"),
        str(r.get("url") or "?"),
    ]))
sys.stdout.write(chr(10).join(out))
if out:
    sys.stdout.write(chr(10))
'
}

flatten_issues() {
    PYTHONIOENCODING=utf-8 python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("issues json unreadable: %s" % exc + chr(10))
    sys.exit(3)
if not isinstance(rows, list):
    sys.stderr.write("issues json is not a list" + chr(10))
    sys.exit(3)
tab = chr(9)
out = [tab.join([str(r.get("number") or "?"), str(r.get("url") or "?"),
                 str(r.get("title") or "?")]) for r in rows]
sys.stdout.write(chr(10).join(out))
if out:
    sys.stdout.write(chr(10))
'
}

load_data() {
    local fixture="${WARDEN_CI_FIXTURE:-}"
    local raw_runs raw_issues

    if [ -n "$fixture" ]; then
        if [ ! -f "$fixture/runs.json" ]; then
            note "fixture $fixture has no runs.json - nothing was measured"
            return 2
        fi
        raw_runs="$(cat "$fixture/runs.json")"
        raw_issues='[]'
        [ -f "$fixture/issues.json" ] && raw_issues="$(cat "$fixture/issues.json")"
    else
        if ! command -v gh >/dev/null 2>&1; then
            note "gh is not installed - nothing was measured"
            return 2
        fi
        if ! gh auth status >/dev/null 2>&1; then
            note "gh is not authenticated - nothing was measured"
            return 2
        fi
        raw_runs="$(gh run list --branch main --limit 40 \
            --json event,conclusion,status,createdAt,databaseId,url 2>&1)" || {
            note "gh run list failed: $raw_runs"
            return 2
        }
        raw_issues="$(gh issue list --label "$CI_RED_LABEL" --state open --limit 30 \
            --json number,url,title 2>&1)" || {
            note "gh issue list failed: $raw_issues"
            return 2
        }
    fi

    RUNS_TSV="$(printf '%s' "$raw_runs" | flatten_runs)" || return 2
    ISSUES_TSV="$(printf '%s' "$raw_issues" | flatten_issues)" || return 2

    if [ -z "$RUNS_TSV" ]; then
        note "no CI runs on main at all - nothing was measured"
        return 2
    fi
    return 0
}

# newest_run [event]  ->  the newest COMPLETED run, optionally of one event
newest_run() {
    local want="${1:-}"
    printf '%s' "$RUNS_TSV" | awk -F'\t' -v want="$want" '
        $3 != "completed" { next }
        want != "" && $1 != want { next }
        { print; exit }
    '
}

field() { printf '%s' "$1" | cut -d"$(printf '\t')" -f"$2"; }

# -----------------------------------------------------------------------------
#  Assertions
# -----------------------------------------------------------------------------
assert_c1() {
    local row conclusion id url event
    row="$(newest_run)"
    if [ -z "$row" ]; then
        bad "C1: no completed run on main - nothing was measured"
        FAILURES=$((FAILURES + 1)); UNMEASURED=$((UNMEASURED + 1)); return
    fi
    event="$(field "$row" 1)"; conclusion="$(field "$row" 2)"
    id="$(field "$row" 5)"; url="$(field "$row" 6)"
    if [ "$conclusion" = "success" ]; then
        good "C1: newest run on main is green (${event}, run ${id})"
    else
        bad "C1: newest run on main concluded '${conclusion}' (${event}, run ${id})"
        note "     $url"
        FAILURES=$((FAILURES + 1))
    fi
}

assert_c2() {
    local row age id
    row="$(newest_run schedule)"
    if [ -z "$row" ]; then
        bad "C2: no completed schedule run in the last 40 runs on main"
        note "     the weekly cron may be disabled - GitHub stops scheduled"
        note "     workflows after 60 days of repo inactivity. Check the"
        note "     Actions tab and re-enable, then workflow_dispatch once."
        FAILURES=$((FAILURES + 1)); return
    fi
    age="$(field "$row" 4)"; id="$(field "$row" 5)"
    if awk -v a="$age" -v w="$WINDOW_DAYS" 'BEGIN { exit !(a <= w) }'; then
        good "C2: a schedule run fired ${age} days ago (run ${id}, window ${WINDOW_DAYS}d)"
    else
        bad "C2: the newest schedule run is ${age} days old (window ${WINDOW_DAYS}d, run ${id})"
        note "     the weekly cron has stopped firing. An 'if: failure()' job"
        note "     cannot alarm on a run that never happened - this assertion"
        note "     is the only thing that sees it."
        FAILURES=$((FAILURES + 1))
    fi
}

assert_c3() {
    local row conclusion id url age later
    row="$(newest_run schedule)"
    if [ -z "$row" ]; then
        note "C3: skipped - C2 already reported no schedule run to judge"
        return
    fi
    conclusion="$(field "$row" 2)"; id="$(field "$row" 5)"; url="$(field "$row" 6)"
    age="$(field "$row" 4)"
    if [ "$conclusion" = "success" ]; then
        good "C3: the weekly gate is green (schedule run ${id})"
        return
    fi
    # Every push runs the same five jobs with the same --pull rebuilds, so a
    # LATER green run is proof that the drift which reddened the schedule run
    # is gone. Without this, a fixed CI stays red here until the next Monday
    # and the alarm teaches its reader to ignore it.
    later="$(printf '%s' "$RUNS_TSV" | awk -F'	' -v a="$age" '
        $3 == "completed" && $2 == "success" && ($4 + 0) < (a + 0) { print; exit }')"
    if [ -n "$later" ]; then
        good "C3: the last schedule run was ${conclusion} (${id}), but a later $(field "$later" 1) run is green ($(field "$later" 5))"
    else
        bad "C3: the newest schedule run concluded '${conclusion}' (run ${id})"
        note "     a push can be green while the weekly gate is red: only the"
        note "     schedule run rebuilds with --pull and sees upstream drift."
        note "     $url"
        FAILURES=$((FAILURES + 1))
    fi
}

open_issue_count() {
    if [ -z "$ISSUES_TSV" ]; then printf '0'; else printf '%s' "$ISSUES_TSV" | grep -c '' ; fi
}

assert_c4() {
    local row conclusion n first
    row="$(newest_run)"
    [ -z "$row" ] && return   # C1 already said nothing was measured
    conclusion="$(field "$row" 2)"
    if [ "$conclusion" = "success" ]; then
        note "C4: skipped - the newest run is green, so no alarm was due"
        return
    fi
    n="$(open_issue_count)"
    if [ "$n" -gt 0 ]; then
        first="$(printf '%s' "$ISSUES_TSV" | head -1)"
        good "C4: the red run is witnessed by ${n} open ${CI_RED_LABEL} issue(s)"
        note "     $(field "$first" 2)"
    else
        bad "C4: CI is red and NO open ${CI_RED_LABEL} issue exists - the alarm said nothing"
        note "     either the alarm job is missing from ci.yml, or it ran and"
        note "     failed silently inside an already-red run (a missing"
        note "     'permissions: issues: write' returns 403). Read the alarm"
        note "     job's own log in the failing run before anything else."
        FAILURES=$((FAILURES + 1))
    fi
}

assert_c5() {
    local row conclusion n first
    row="$(newest_run)"
    [ -z "$row" ] && return
    conclusion="$(field "$row" 2)"
    if [ "$conclusion" != "success" ]; then
        note "C5: skipped - CI is red, so an open issue is correct"
        return
    fi
    n="$(open_issue_count)"
    if [ "$n" -eq 0 ]; then
        good "C5: no stale ${CI_RED_LABEL} issue left open behind a green run"
    else
        first="$(printf '%s' "$ISSUES_TSV" | head -1)"
        bad "C5: CI is green but ${n} ${CI_RED_LABEL} issue(s) are still open"
        note "     the alarm's recovery path did not close them. An alarm that"
        note "     never clears teaches the reader to ignore it."
        note "     $(field "$first" 2)"
        FAILURES=$((FAILURES + 1))
    fi
}

run_assertions() {
    assert_c1
    assert_c2
    assert_c3
    assert_c4
    assert_c5
}

# -----------------------------------------------------------------------------
#  Self-test. Each fixture violates exactly ONE assertion, so a guard that
#  silently did nothing shows up as a case that passed when it should not.
#  No network, no gh: this runs in CI's static job on every push.
# -----------------------------------------------------------------------------
NOW='2026-11-16T12:00:00Z'
readonly NOW

fixture_dir() {
    local d="$1" runs="$2" issues="$3"
    mkdir -p "$d"
    printf '%s\n' "$runs"   > "$d/runs.json"
    printf '%s\n' "$issues" > "$d/issues.json"
}

self_test() {
    local tmp st_fail=0
    tmp="$(mktemp -d)" || { printf 'mktemp failed\n' >&2; exit 2; }
    chmod 755 "$tmp"

    local green_sched='{"event":"schedule","conclusion":"success","status":"completed","createdAt":"2026-11-16T06:30:00Z","databaseId":1,"url":"u/1"}'
    local red_sched='{"event":"schedule","conclusion":"failure","status":"completed","createdAt":"2026-11-16T06:30:00Z","databaseId":2,"url":"u/2"}'
    local old_sched='{"event":"schedule","conclusion":"success","status":"completed","createdAt":"2026-10-05T06:30:00Z","databaseId":3,"url":"u/3"}'
    local green_push='{"event":"push","conclusion":"success","status":"completed","createdAt":"2026-11-16T09:00:00Z","databaseId":4,"url":"u/4"}'
    local red_sched_late='{"event":"schedule","conclusion":"failure","status":"completed","createdAt":"2026-11-16T10:30:00Z","databaseId":8,"url":"u/8"}'
    local red_push='{"event":"push","conclusion":"failure","status":"completed","createdAt":"2026-11-16T09:00:00Z","databaseId":5,"url":"u/5"}'
    local running='{"event":"push","conclusion":null,"status":"in_progress","createdAt":"2026-11-16T11:00:00Z","databaseId":6,"url":"u/6"}'
    local issue='{"number":7,"url":"u/i7","title":"CI is red"}'

    # name | runs.json | issues.json | expected exit | assertion it must name
    fixture_dir "$tmp/ok"          "[$green_push,$green_sched]"   "[]"        # 0
    fixture_dir "$tmp/c1"          "[$red_push,$green_sched]"     "[$issue]"  # 1, C1
    fixture_dir "$tmp/c2"          "[$green_push,$old_sched]"     "[]"        # 1, C2
    fixture_dir "$tmp/c3"          "[$red_sched_late,$green_push]" "[$issue]" # 1, C3
    fixture_dir "$tmp/c3recovered" "[$green_push,$red_sched]"     "[]"        # 0, C3 recovered
    fixture_dir "$tmp/c4"          "[$red_push,$green_sched]"     "[]"        # 1, C4 (and C1)
    fixture_dir "$tmp/c5"          "[$green_push,$green_sched]"   "[$issue]"  # 1, C5
    fixture_dir "$tmp/noschedule"  "[$green_push]"                "[]"        # 1, C2
    fixture_dir "$tmp/empty"       "[]"                           "[]"        # 2
    fixture_dir "$tmp/inflight"    "[$running,$green_push,$green_sched]" "[]" # 0, the running one is ignored

    local case_name want_rc want_marker
    while IFS='|' read -r case_name want_rc want_marker; do
        [ -z "$case_name" ] && continue
        local out rc
        out="$(WARDEN_CI_FIXTURE="$tmp/$case_name" WARDEN_CI_NOW="$NOW" \
               NO_COLOR=1 QUIET=1 "$0" --quiet 2>&1)"
        rc=$?
        local ok=1
        [ "$rc" -eq "$want_rc" ] || ok=0
        if [ -n "$want_marker" ]; then
            printf '%s' "$out" | grep -q "$want_marker" || ok=0
        fi
        if [ "$ok" -eq 1 ]; then
            good "self-test ${case_name}: exit ${rc}, saw '${want_marker}'"
        else
            bad "self-test ${case_name}: exit ${rc} (want ${want_rc}), marker '${want_marker}' not found"
            printf '%s\n' "$out" | sed 's/^/        | /'
            st_fail=$((st_fail + 1))
        fi
    done <<'CASES'
ok|0|PASS C1
c1|1|FAIL C1
c2|1|FAIL C2
c3|1|FAIL C3
c3recovered|0|PASS C3: the last schedule run was failure
c4|1|FAIL C4
c5|1|FAIL C5
noschedule|1|FAIL C2
empty|2|nothing was measured
inflight|0|PASS C1
CASES

    rm -rf "$tmp"
    if [ "$st_fail" -eq 0 ]; then
        info "self-test: 10/10 cases behaved as specified"
        return 0
    fi
    info "self-test: ${st_fail} case(s) did NOT behave as specified"
    return 1
}

# -----------------------------------------------------------------------------
#  main
# -----------------------------------------------------------------------------
if [ "$SELF_TEST" -eq 1 ]; then
    info "AI Warden - CI watchdog self-test (fixtures, offline)"
    self_test
    exit $?
fi

cd "$PROJECT_ROOT" || exit 2

info "AI Warden - CI status (branch main, window ${WINDOW_DAYS}d)"
load_data
rc=$?
if [ "$rc" -ne 0 ]; then
    bad "nothing was measured - this is NOT a green CI"
    exit 2
fi

run_assertions

if [ "$UNMEASURED" -gt 0 ]; then
    info "CI status: ${UNMEASURED} assertion(s) had no data - treat as unknown, not green"
    exit 2
fi
if [ "$FAILURES" -eq 0 ]; then
    info "CI status: all assertions passed"
    exit 0
fi
info "CI status: ${FAILURES} assertion(s) failed - fix CI before new work (NEXT_PROMPT step 1b)"
exit 1
