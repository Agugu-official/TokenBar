#!/usr/bin/env bash
# Refuse to release a commit whose main-branch CI is not green.
#
#   scripts/check_ci_gate.sh <commit-sha>
#
# release.yml runs this first. CI does not run on tags, so without it a tag
# on the wrong commit, or one pushed before main's runs finish, reaches the
# build, the signing key and publication with no CI result in between. Both
# workflows must have a push run on main for this exact commit, and the newest
# run of each must have concluded `success`:
#
#   ci.yml          debug build, selftest, FFI smoke test
#   ci-release.yml  release-configuration build, bundled selftest
#
# A mistake guard, not a security boundary: the tagged commit carries this
# script and release.yml, so a commit that removes the gate is not gated.
#
# Waits while a run is queued or in progress (up to CI_GATE_TIMEOUT seconds),
# and while no run exists yet (up to CI_GATE_GRACE seconds: a tag pushed right
# after a merge can arrive before GitHub creates the runs). Anything else that
# is not an explicit success fails, including an API error.
#
# Needs GH_TOKEN and GITHUB_REPOSITORY. The CI_GATE_* variables exist for
# scripts/check_ci_gate_test.sh.
set -euo pipefail

sha="${1:-}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
interval="${CI_GATE_INTERVAL:-30}"
timeout="${CI_GATE_TIMEOUT:-1800}"
grace="${CI_GATE_GRACE:-300}"
workflows=(ci.yml ci-release.yml)

if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::check_ci_gate: expected a 40-character commit SHA, got '$sha'"
  exit 2
fi

recovery="Once both runs for $sha are green, re-run this Release run (Re-run jobs, or gh run rerun). Re-run a failed CI run with Re-run too: a workflow_dispatch run is not a push run and this gate does not count it. If the tag is on the wrong commit, it needs a new commit and a new tag."

# Prints "<status>\t<conclusion>\t<html_url>" for the newest push run of the
# workflow on main at $sha, or "none" when there is no such run. Returns
# non-zero when the API call or the JSON is unusable.
newest_run() {
  local file="$1" body
  body=$(gh api "repos/$repo/actions/workflows/$file/runs?head_sha=$sha&event=push&branch=main&per_page=100") || return 1
  jq -er '
    [.workflow_runs[] | select(.head_sha == $sha and .head_branch == "main" and .event == "push")]
    | if length == 0 then "none"
      else (sort_by(.created_at) | last | [.status, (.conclusion // "none"), .html_url] | @tsv)
      end' --arg sha "$sha" <<<"$body" || return 1
}

# Every pass queries both workflows again: a run already seen green can be
# re-run (same run, new attempt) and turn red while the gate waits on the
# other one. The gate passes only in an iteration where both read success.
start=$(date +%s)
api_failures=0   # consecutive passes in which some API answer was unreadable
while :; do
  now=$(date +%s)
  elapsed=$((now - start))
  green=0
  read_ok=1
  for wf in "${workflows[@]}"; do
    if ! line=$(newest_run "$wf"); then
      # A single 5xx or rate-limit blip should not refuse a release the gate
      # is already prepared to wait 30 minutes for; three in a row does.
      api_failures=$((api_failures + 1))
      if (( api_failures >= 3 )); then
        echo "::error::check_ci_gate: could not read the runs of $wf for $sha from the GitHub API (3 attempts)."
        echo "$recovery"
        exit 1
      fi
      echo "check_ci_gate: could not read the runs of $wf for $sha; retrying (${api_failures}/3)."
      read_ok=0
      break   # green cannot reach the total in this pass
    fi
    IFS=$'\t' read -r status conclusion url <<<"$line"
    if [[ "$status" == "none" ]]; then
      if (( elapsed >= grace )); then
        echo "::error::check_ci_gate: no CI run of $wf on main for $sha after ${grace}s."
        echo "GitHub starts CI only for the head commit of each push to main. Tag the merge commit, not a commit inside the merged branch or the middle of a multi-commit push. Other causes: the runs were never created, the commit is not on main, it only changed landing/ (CI skips those), or it is the appcast commit release.yml pushes itself (a GITHUB_TOKEN push starts no CI)."
        echo "$recovery"
        exit 1
      fi
      echo "check_ci_gate: $wf has no run for $sha yet (waited ${elapsed}s of ${grace}s)."
    elif [[ "$status" != "completed" ]]; then
      if (( elapsed >= timeout )); then
        echo "::error::check_ci_gate: $wf for $sha is still $status after ${timeout}s: $url"
        echo "$recovery"
        exit 1
      fi
      echo "check_ci_gate: $wf for $sha is $status (waited ${elapsed}s): $url"
    elif [[ "$conclusion" == "success" ]]; then
      echo "check_ci_gate: $wf for $sha passed: $url"
      green=$((green + 1))
    else
      echo "::error::check_ci_gate: $wf for $sha concluded '$conclusion': $url"
      echo "$recovery"
      exit 1
    fi
  done
  # Reset only after a pass that read every workflow: resetting on each
  # successful call let a first workflow that always reads fine hide a second
  # that never does, and the gate polled forever.
  if (( read_ok )); then api_failures=0; fi
  if (( green == ${#workflows[@]} )); then
    echo "check_ci_gate: both CI workflows are green for $sha."
    exit 0
  fi
  sleep "$interval"
done
