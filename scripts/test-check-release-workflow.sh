#!/bin/sh
# Tests of the check of the release workflow
# (scripts/check-release-workflow.sh). The check must pass on the workflow
# as it is. Each other test copies it, changes one thing in the copy with
# yq, and expects the check to fail and to say what is wrong: each change
# would let a run publish where it should not, or publish without the
# checks a release waits for (docs/releasing.md, "What a tag does"): that
# the tag names moon.mod's version, that CI passed on the tagged commit,
# and that the latest weekly mutation run is clean in the packages at L4
# (#316).
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-release-workflow.sh
#
# The ${{ ... }} and $(...) below are the workflow's own syntax, which the
# shell must leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

workflow=.github/workflows/release.yml

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
pass() {
  passed=$((passed + 1))
  echo "ok   $*"
}
fail() {
  failed=$((failed + 1))
  echo "FAIL $*"
}

# The plan's steps, as yq selects them.
tag_step='.jobs.plan.steps[] | select((.run // "") | test("check-tag-version"))'
ci_step='.jobs.plan.steps[] | select((.run // "") | test("check-ci-passed"))'
weekly_step='.jobs.plan.steps[] | select((.run // "") | test("check-weekly-run"))'
checkout_step='.jobs.plan.steps[] | select((.uses // "") | test("^actions/checkout@"))'

# check <name>: runs the check on the copy, its output into $tmp/<name>.out
# and its exit status into $tmp/<name>.status.
check() {
  status=0
  scripts/check-release-workflow.sh "$tmp/release.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each
# message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp "$workflow" "$tmp/release.yml"
  yq --inplace "$expression" "$tmp/release.yml"
  if cmp -s "$workflow" "$tmp/release.yml"; then
    fail "$name: the change left the workflow as it was"
    return
  fi
  check "$name"
  if [ "$(cat "$tmp/$name.status")" != 1 ]; then
    fail "$name: exits with $(cat "$tmp/$name.status"), not 1: $(cat "$tmp/$name.out")"
    return
  fi
  for message in "$@"; do
    if grep -qF -- "$message" "$tmp/$name.out"; then
      pass "$name: says \"$message\""
    else
      fail "$name: does not say \"$message\" but: $(cat "$tmp/$name.out")"
    fi
  done
}

# --- The workflow as it is -----------------------------------------------------

cp "$workflow" "$tmp/release.yml"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

# --- Only for pushed version tags, and by hand ------------------------------------

refuses on-pull-requests \
  '.on.pull_request = {}' \
  "it should run on push and workflow_dispatch only, not on: pull_request push workflow_dispatch"

refuses on-pushed-branches \
  '.on.push.branches = ["main"]' \
  "it should run on pushed tags only, but on.push has: branches tags"

refuses on-other-tags \
  '.on.push.tags = ["release-*"]' \
  "it should run on version tags (v*) only, not on release-*"

refuses default-write-permission \
  '.permissions.contents = "write"' \
  "its default permissions should be read-only"

refuses a-secret \
  '.jobs.build.env.TOKEN = "${{ secrets.TOKEN }}"' \
  "it should use no secrets, only its own token"

refuses a-job-that-publishes-on-a-run-by-hand \
  'del(.jobs."publish-image".if)' \
  "job publish-image gets a write permission, so it should run only if: github.event_name == 'push' && github.ref_type == 'tag'"

# --- The checks a release waits for -----------------------------------------------

refuses publishes-without-the-plan \
  '.jobs."publish-image".needs = ["build"]' \
  "job publish-image gets a write permission, so it should need plan, whose checks a release waits for"

refuses releases-without-the-plan \
  '.jobs.release.needs = ["publish-image", "publish-chart"]' \
  "job release gets a write permission, so it should need plan, whose checks a release waits for"

refuses no-tag-check \
  "del($tag_step)" \
  "job plan should check that the tag names the version in moon.mod, for a pushed tag: scripts/check-tag-version.sh \"\$VERSION\""

refuses no-ci-check \
  "del($ci_step)" \
  "job plan should check that CI passed on the tagged commit, for a pushed tag: scripts/check-ci-passed.sh \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses no-weekly-run-check \
  "del($weekly_step)" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-on-another-commit \
  "($weekly_step | .run) = \"python3 scripts/check-weekly-run.py \\\"\$(git rev-parse HEAD~1)\\\"\"" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-by-hand-only \
  "($weekly_step | .if) = \"github.event_name == 'workflow_dispatch'\"" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-without-a-token \
  "del($weekly_step | .env.GH_TOKEN)" \
  "job plan should check the latest weekly mutation run, for a pushed tag: python3 scripts/check-weekly-run.py \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses weekly-run-check-that-may-fail \
  "($weekly_step | .\"continue-on-error\") = true" \
  "job plan should not continue on error, nor any of its steps"

refuses ci-check-hidden \
  "($ci_step | .run) |= . + \" || true\"" \
  "job plan should check that CI passed on the tagged commit, for a pushed tag: scripts/check-ci-passed.sh \"\$(git rev-parse HEAD)\", with GH_TOKEN"

refuses a-plan-that-may-fail \
  '.jobs.plan."continue-on-error" = true' \
  "job plan should not continue on error, nor any of its steps"

refuses a-shallow-plan \
  "del($checkout_step | .with)" \
  "job plan should check out the whole history (fetch-depth: 0), which scripts/check-weekly-run.py reads"

refuses a-plan-that-cannot-read-runs \
  'del(.jobs.plan.permissions.actions)' \
  "job plan should read the Actions API (actions: read), which its checks of CI's run and of the weekly run ask"

echo
echo "test-check-release-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
