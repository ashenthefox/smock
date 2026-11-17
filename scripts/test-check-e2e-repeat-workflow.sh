#!/bin/sh
# Tests of the check of the e2e repeat workflow
# (scripts/check-e2e-repeat-workflow.sh). The check must pass on the
# workflow as it is. Each other test copies it, changes one thing in the
# copy with yq, and expects the check to fail and to say what is wrong:
# each change would start the workflow without anyone asking, give it more
# than read access, or run the tests on another machine, another number of
# times, or without keeping what they printed.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-e2e-repeat-workflow.sh
#
# The ${{ ... }} below is the workflow's own syntax, which the shell must
# leave as it is.
# shellcheck disable=SC2016
set -eu
cd "$(dirname "$0")/.."

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

# The step that runs the repeats, as yq selects it.
repeat_step='.jobs.repeat.steps[] | select((.run // "") | test("repeat-e2e"))'
upload_step='.jobs.repeat.steps[] | select((.uses // "") | test("upload-artifact"))'
setup_step='.jobs.repeat.steps[] | select(.uses == "./.github/actions/native-setup")'

# check <name>: runs the check on the copy, its output into $tmp/<name>.out
# and its exit status into $tmp/<name>.status.
check() {
  status=0
  scripts/check-e2e-repeat-workflow.sh "$tmp/e2e-repeat.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <yq expression> <message>...: with the expression applied
# to a fresh copy of the workflow, the check exits 1 and prints each
# message.
refuses() {
  name=$1
  expression=$2
  shift 2
  cp .github/workflows/e2e-repeat.yml "$tmp/"
  yq --inplace "$expression" "$tmp/e2e-repeat.yml"
  if cmp -s .github/workflows/e2e-repeat.yml "$tmp/e2e-repeat.yml"; then
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

cp .github/workflows/e2e-repeat.yml "$tmp/"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflow passes"
else
  fail "unchanged: the workflow does not pass: $(cat "$tmp/unchanged.out")"
fi

# The values this test changes are the ones the workflow has: a test that
# changed nothing would pass for the wrong reason.
# has <yq expression> <value>: the workflow has the value there.
has() {
  if [ "$(yq "$1" .github/workflows/e2e-repeat.yml)" = "$2" ]; then
    pass "unchanged: $1 is as this test expects"
  else
    fail "unchanged: $1 is not: $2"
  fi
}
has .jobs.repeat.runs-on "\${{ inputs.arch == 'arm64' && 'ubuntu-24.04-arm' || 'ubuntu-24.04' }}"
has "$setup_step | .with.machine" "\${{ inputs.arch == 'arm64' && 'aarch64' || 'x86_64' }}"
has "$repeat_step | .env.RUNS" "\${{ inputs.runs }}"
has "$upload_step | .if" "always()"

if scripts/check-e2e-repeat-workflow.sh "$tmp/nowhere.yml" >"$tmp/missing.out" 2>&1; then
  fail "missing: passes on a workflow that does not exist"
elif grep -qF "$tmp/nowhere.yml does not exist" "$tmp/missing.out"; then
  pass "missing: says the workflow does not exist"
else
  fail "missing: says: $(cat "$tmp/missing.out")"
fi

# --- When it runs ----------------------------------------------------------------

refuses on-push '.on.push = {}' \
  "it should run only when started by hand (workflow_dispatch), not on: push workflow_dispatch"

refuses on-a-schedule '.on.schedule = [{"cron": "0 3 * * *"}]' \
  "it should run only when started by hand (workflow_dispatch), not on: schedule workflow_dispatch"

refuses on-pull-requests '.on.pull_request = {}' \
  "it should run only when started by hand (workflow_dispatch), not on: pull_request workflow_dispatch"

refuses only-on-push '.on = "push"' \
  "it should run only when started by hand (workflow_dispatch), not on: push"

refuses when-called '.on = {"workflow_call": {}}' \
  "it should run only when started by hand (workflow_dispatch), not on: workflow_call"

# --- What it may do ----------------------------------------------------------------

refuses write-permission '.permissions.contents = "write"' \
  "its permissions should be read-only"

refuses job-write-permission '.jobs.repeat.permissions = {"actions": "write"}' \
  "its permissions should be read-only"

refuses no-permissions 'del(.permissions)' \
  "its permissions should be read-only"

refuses a-secret "($repeat_step | .env.TOKEN) = \"\${{ secrets.GITHUB_TOKEN }}\"" \
  "it should use no secrets"

# --- What it asks for ----------------------------------------------------------------

refuses one-architecture '.on.workflow_dispatch.inputs.arch.options = ["amd64"]' \
  "it should ask for the architecture as a choice of amd64 and arm64 (inputs.arch)"

refuses architecture-as-text '.on.workflow_dispatch.inputs.arch.type = "string"' \
  "it should ask for the architecture as a choice of amd64 and arm64 (inputs.arch)"

refuses no-architecture 'del(.on.workflow_dispatch.inputs.arch)' \
  "it should ask for the architecture as a choice of amd64 and arm64 (inputs.arch)"

refuses runs-as-text '.on.workflow_dispatch.inputs.runs.type = "string"' \
  "it should ask for the number of runs as a number (inputs.runs)"

refuses no-runs 'del(.on.workflow_dispatch.inputs.runs)' \
  "it should ask for the number of runs as a number (inputs.runs)"

# --- How it runs the tests ----------------------------------------------------------

refuses no-repeats "del($repeat_step)" \
  "a job should run the e2e tests again and again with scripts/repeat-e2e.sh"

refuses one-runner '.jobs.repeat.runs-on = "ubuntu-24.04"' \
  "job repeat should run on the runner of the chosen architecture (runs-on: \${{ inputs.arch == 'arm64' && 'ubuntu-24.04-arm' || 'ubuntu-24.04' }}), not on ubuntu-24.04"

refuses runners-swapped ".jobs.repeat.runs-on = \"\${{ inputs.arch == 'arm64' && 'ubuntu-24.04' || 'ubuntu-24.04-arm' }}\"" \
  "job repeat should run on the runner of the chosen architecture"

refuses one-machine "($setup_step | .with.machine) = \"x86_64\"" \
  "job repeat should check that its runner is the machine of the chosen architecture, once, with the native setup (machine: \${{ inputs.arch == 'arm64' && 'aarch64' || 'x86_64' }})"

refuses no-native-setup "del($setup_step)" \
  "job repeat should check that its runner is the machine of the chosen architecture"

refuses a-fixed-number "($repeat_step | .env.RUNS) = \"30\"" \
  'job repeat should run the e2e tests the number of times asked for (scripts/repeat-e2e.sh "$RUNS" with RUNS: ${{ inputs.runs }}), not: scripts/repeat-e2e.sh "$RUNS" "$RUNNER_TEMP/e2e-repeat" with RUNS: 30'

refuses runs-not-passed "($repeat_step | .run) = \"scripts/repeat-e2e.sh 1 \\\"\$RUNNER_TEMP/e2e-repeat\\\"\"" \
  'job repeat should run the e2e tests the number of times asked for (scripts/repeat-e2e.sh "$RUNS" with RUNS: ${{ inputs.runs }}), not: scripts/repeat-e2e.sh 1 "$RUNNER_TEMP/e2e-repeat" with RUNS: ${{ inputs.runs }}'

# --- What it keeps -------------------------------------------------------------------

refuses upload-only-on-success "del($upload_step | .if)" \
  "job repeat should upload what the runs printed as an artifact with if: always()"

refuses upload-on-failure-only "($upload_step | .if) = \"failure()\"" \
  "job repeat should upload what the runs printed as an artifact with if: always()"

refuses no-upload "del($upload_step)" \
  "job repeat should upload what the runs printed as an artifact with if: always()"

echo
echo "test-check-e2e-repeat-workflow: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
