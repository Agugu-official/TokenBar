#!/usr/bin/env bash
# Tests for scripts/check_ci_gate.sh against a fake `gh` that replays canned
# API responses, so every branch runs without the network.
#
#   scripts/check_ci_gate_test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/check_ci_gate.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sha=0123456789abcdef0123456789abcdef01234567
fails=0

# Fake gh: `gh api repos/<repo>/actions/workflows/<file>/runs?...`. Each call
# for <file> reads $SCENARIO/<file>.<n> (n counts calls per file, the last file
# repeats). A response file whose first line is "EXIT <code>" makes gh fail
# with that code and print nothing.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
file=$(sed -E 's#.*/workflows/([^/]+)/runs.*#\1#' <<<"$2")
count_file="$SCENARIO/.count.$file"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$count_file"
resp="$SCENARIO/$file.$n"
[[ -f "$resp" ]] || resp="$SCENARIO/$file.$(cd "$SCENARIO" && ls "$file".* | sed "s/^$file\\.//" | sort -n | tail -1)"
if [[ "$(head -1 "$resp")" == EXIT* ]]; then exit "$(head -1 "$resp" | cut -d' ' -f2)"; fi
cat "$resp"
EOF
chmod +x "$work/bin/gh"

run_json() { # status conclusion [branch] [created_at]
  printf '{"head_sha":"%s","head_branch":"%s","event":"push","status":"%s","conclusion":%s,"created_at":"%s","html_url":"https://example.invalid/%s"}' \
    "$sha" "${3:-main}" "$1" "$([[ $2 == null ]] && echo null || echo "\"$2\"")" "${4:-2026-09-27T00:00:00Z}" "$1"
}
runs() { printf '{"workflow_runs":[%s]}' "$(IFS=,; echo "$*")"; }

# scenario <name> <expected exit> <expected output substring> then files.
# Each run gets 30 s (perl alarm, exit 142): a gate that loops forever fails
# its scenario instead of hanging the CI step.
check() {
  local name="$1" want_rc="$2" want_text="$3" arg="${4:-$sha}" out rc
  out=$(PATH="$work/bin:$PATH" SCENARIO="$work/$name" GITHUB_REPOSITORY=o/r \
        CI_GATE_INTERVAL=0 CI_GATE_TIMEOUT="${TIMEOUT:-5}" CI_GATE_GRACE="${GRACE:-5}" \
        perl -e 'alarm shift; exec @ARGV' 30 bash "$gate" "$arg" 2>&1)
  rc=$?
  if [[ $rc -eq $want_rc && "$out" == *"$want_text"* ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: rc=$rc (want $want_rc), output:"; sed 's/^/     /' <<<"$out"
    fails=$((fails + 1))
  fi
}
scenario() { mkdir -p "$work/$1"; }
put() { printf '%s\n' "$3" >"$work/$1/$2"; }

scenario both-green
put both-green ci.yml.1 "$(runs "$(run_json completed success)")"
put both-green ci-release.yml.1 "$(runs "$(run_json completed success)")"
check both-green 0 "both CI workflows are green"

scenario one-failed
put one-failed ci.yml.1 "$(runs "$(run_json completed success)")"
put one-failed ci-release.yml.1 "$(runs "$(run_json completed failure)")"
check one-failed 1 "ci-release.yml for $sha concluded 'failure'"

scenario cancelled
put cancelled ci.yml.1 "$(runs "$(run_json completed cancelled)")"
put cancelled ci-release.yml.1 "$(runs "$(run_json completed success)")"
check cancelled 1 "concluded 'cancelled'"

# Two runs for one commit (e.g. a second push of the same SHA): the newer one,
# still in progress, decides; the older success must not pass it.
scenario newest-in-progress
put newest-in-progress ci.yml.1 "$(runs "$(run_json completed success main 2026-09-27T00:00:00Z)" "$(run_json in_progress null main 2026-09-27T01:00:00Z)")"
put newest-in-progress ci-release.yml.1 "$(runs "$(run_json completed success)")"
TIMEOUT=0 check newest-in-progress 1 "still in_progress"

# A re-run reuses the same run: ci.yml reads success, is re-run while the gate
# waits on ci-release.yml, and ends in failure. The gate must see the failure.
scenario rerun-turns-red
put rerun-turns-red ci.yml.1 "$(runs "$(run_json completed success)")"
put rerun-turns-red ci.yml.2 "$(runs "$(run_json in_progress null)")"
put rerun-turns-red ci.yml.3 "$(runs "$(run_json completed failure)")"
put rerun-turns-red ci-release.yml.1 "$(runs "$(run_json in_progress null)")"
put rerun-turns-red ci-release.yml.2 "$(runs "$(run_json in_progress null)")"
put rerun-turns-red ci-release.yml.3 "$(runs "$(run_json completed success)")"
check rerun-turns-red 1 "ci.yml for $sha concluded 'failure'"

# More than ten polls: the fake must replay the highest-numbered response, not
# the lexically last one.
scenario many-polls
for i in 1 2 3 4 5 6 7 8 9 10; do put many-polls "ci.yml.$i" "$(runs "$(run_json queued null)")"; done
put many-polls ci.yml.11 "$(runs "$(run_json completed success)")"
put many-polls ci-release.yml.1 "$(runs "$(run_json completed success)")"
check many-polls 0 "both CI workflows are green"

scenario wait-then-green
put wait-then-green ci.yml.1 "$(runs "$(run_json queued null)")"
put wait-then-green ci.yml.2 "$(runs "$(run_json in_progress null)")"
put wait-then-green ci.yml.3 "$(runs "$(run_json completed success)")"
put wait-then-green ci-release.yml.1 "$(runs "$(run_json completed success)")"
check wait-then-green 0 "both CI workflows are green"

# A tag pushed right after a merge: no run yet, then one appears.
scenario empty-then-green
put empty-then-green ci.yml.1 "$(runs)"
put empty-then-green ci.yml.2 "$(runs "$(run_json in_progress null)")"
put empty-then-green ci.yml.3 "$(runs "$(run_json completed success)")"
put empty-then-green ci-release.yml.1 "$(runs)"
put empty-then-green ci-release.yml.2 "$(runs "$(run_json completed success)")"
check empty-then-green 0 "both CI workflows are green"

scenario never-a-run
put never-a-run ci.yml.1 "$(runs)"
put never-a-run ci-release.yml.1 "$(runs "$(run_json completed success)")"
GRACE=0 check never-a-run 1 "no CI run of ci.yml on main for $sha"

scenario other-branch
put other-branch ci.yml.1 "$(runs "$(run_json completed success feature)")"
put other-branch ci-release.yml.1 "$(runs "$(run_json completed success)")"
GRACE=0 check other-branch 1 "no CI run of ci.yml on main"

scenario api-error
put api-error ci.yml.1 "EXIT 1"
put api-error ci-release.yml.1 "$(runs "$(run_json completed success)")"
check api-error 1 "could not read the runs of ci.yml for $sha from the GitHub API (3 attempts)"

# One failed call is retried; three in a row refuse.
scenario api-blip
put api-blip ci.yml.1 "EXIT 1"
put api-blip ci.yml.2 "$(runs "$(run_json completed success)")"
put api-blip ci-release.yml.1 "$(runs "$(run_json completed success)")"
check api-blip 0 "both CI workflows are green"

# The second workflow failing every time must still refuse after three passes,
# even though the first one reads fine in each of them.
scenario second-api-error
put second-api-error ci.yml.1 "$(runs "$(run_json completed success)")"
put second-api-error ci-release.yml.1 "EXIT 1"
check second-api-error 1 "could not read the runs of ci-release.yml for $sha from the GitHub API (3 attempts)"

# A newer green workflow_dispatch run beside a red push run must not pass: the
# gate counts push runs only.
scenario dispatch-beside-push
put dispatch-beside-push ci.yml.1 "$(runs "$(run_json completed failure main 2026-09-27T00:00:00Z)" "$(run_json completed success main 2026-09-27T01:00:00Z | sed 's/"event":"push"/"event":"workflow_dispatch"/')")"
put dispatch-beside-push ci-release.yml.1 "$(runs "$(run_json completed success)")"
check dispatch-beside-push 1 "ci.yml for $sha concluded 'failure'"

# A run for a different commit in the response must not count either.
scenario other-sha
put other-sha ci.yml.1 "$(runs "$(run_json completed success | sed "s/$sha/ffffffffffffffffffffffffffffffffffffffff/")")"
put other-sha ci-release.yml.1 "$(runs "$(run_json completed success)")"
GRACE=0 check other-sha 1 "no CI run of ci.yml on main"

scenario bad-json
put bad-json ci.yml.1 '{"message":"Not Found"}'
put bad-json ci-release.yml.1 "$(runs "$(run_json completed success)")"
check bad-json 1 "could not read the runs of ci.yml"

scenario bad-sha
check bad-sha 2 "expected a 40-character commit SHA" "v1.0.0"

# The recovery instruction is part of every CI-state failure.
check one-failed 1 "re-run this Release run"

if (( fails > 0 )); then echo "$fails failed"; exit 1; fi
echo "all passed"
