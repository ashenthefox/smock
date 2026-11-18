#!/bin/sh
# Tests of the check of the conditions under which CI's jobs run and the
# release binaries are kept (scripts/check-ci-artifacts.sh). The check must
# pass on the workflows as they are. Each other test copies them, changes
# one thing in a copy with yq, and expects the check to fail and to say what
# is wrong: each change would keep a binary from a run in which a check
# failed or did not run, or would let a run pass without a check.
#
# It needs what the check needs: yq (mikefarah/yq v4) and jq.
#
# usage: scripts/test-check-ci-artifacts.sh
#
# The ${{ ... }} below is the workflows' own syntax, which the shell must
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

# What the workflows write, for the yq expressions below (strenv).
export HANDED='release-linux-${{ matrix.arch }}'
export PINNED="inputs.toolchain == 'pinned'"
export GATED='${{ !cancelled() && needs.plan.outputs.full != '"'false'"' }}'
export KEEP='${{ !cancelled() && needs.build-test.result == '"'success'"' && needs.coverage.result == '"'success'"' && needs.scripts.result == '"'success'"' && needs.yaml-test-suite.result == '"'success'"' }}'
# The coverage job's commands (#297), and the condition of its upload.
export COVERAGE='scripts/coverage.sh >coverage-report.txt'
export RATCHET='python3 scripts/coverage-ratchet.py check --base origin/main --summary "$GITHUB_STEP_SUMMARY" _coverage/coverage.bisect'
export UNCANCELLED='${{ !cancelled() }}'

# check <name>: runs the check on the copies, its output into
# $tmp/<name>.out and its exit status into $tmp/<name>.status.
check() {
  status=0
  scripts/check-ci-artifacts.sh "$tmp/build-test.yml" "$tmp/ci.yml" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# refuses <name> <workflow|caller> <yq expression> <message>...: with the
# expression applied to a fresh copy of that file, the check exits 1 and
# prints each message.
refuses() {
  name=$1
  file=$2
  expression=$3
  shift 3
  cp .github/workflows/build-test.yml .github/workflows/ci.yml "$tmp/"
  case $file in
  workflow) yq --inplace "$expression" "$tmp/build-test.yml" ;;
  caller) yq --inplace "$expression" "$tmp/ci.yml" ;;
  esac
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

# --- The workflows as they are -------------------------------------------------

cp .github/workflows/build-test.yml .github/workflows/ci.yml "$tmp/"
check unchanged
if [ "$(cat "$tmp/unchanged.status")" = 0 ]; then
  pass "unchanged: the workflows pass"
else
  fail "unchanged: the workflows do not pass: $(cat "$tmp/unchanged.out")"
fi

# The conditions this test changes are the ones the workflows have: a test
# that changed nothing would pass for the wrong reason.
for written in \
  "build-test.yml|.jobs.test.if|$GATED" \
  "build-test.yml|.jobs.checks.if|$GATED" \
  "build-test.yml|.jobs.release-test.if|$GATED" \
  "build-test.yml|.jobs.llm-sdks.if|$PINNED" \
  "ci.yml|.jobs.keep.if|$KEEP"; do
  file=${written%%|*}
  rest=${written#*|}
  if [ "$(yq "${rest%%|*}" ".github/workflows/$file")" = "${rest#*|}" ]; then
    pass "unchanged: ${rest%%|*} of $file is as this test expects"
  else
    fail "unchanged: ${rest%%|*} of $file is not: ${rest#*|}"
  fi
done
if [ "$(yq '.jobs.coverage.steps[] | select(.with.name == "coverage-report") | .if' .github/workflows/ci.yml)" = "$UNCANCELLED" ]; then
  pass "unchanged: the condition of coverage-report's upload in ci.yml is as this test expects"
else
  fail "unchanged: the condition of coverage-report's upload in ci.yml is not: $UNCANCELLED"
fi

# --- The jobs that build the release binary ----------------------------------

refuses one-architecture workflow \
  'del(.jobs.release.strategy.matrix.include[] | select(.arch == "arm64"))' \
  "the release binary should be built for amd64 on x86_64 and for arm64 on aarch64, not for: amd64 on x86_64"

refuses architecture-on-the-other-machine workflow \
  '(.jobs.release.strategy.matrix.include[] | select(.arch == "arm64") | .machine) = "x86_64"' \
  "the release binary should be built for amd64 on x86_64 and for arm64 on aarch64, not for: amd64 on x86_64, arm64 on x86_64"

refuses build-on-one-runner workflow \
  '.jobs.release.runs-on = "ubuntu-24.04"' \
  'job release should run on the runner its matrix names (runs-on: ${{ matrix.runner }}), not on ubuntu-24.04'

refuses build-on-an-unchecked-runner workflow \
  'del(.jobs.release.steps[] | select(.uses == "./.github/actions/native-setup") | .with.machine)' \
  'job release should set up the machine of its matrix and the toolchain of the call (machine: ${{ matrix.machine }}, toolchain: ${{ inputs.toolchain }}), not {"toolchain":"${{ inputs.toolchain }}"}'

refuses build-without-the-native-setup workflow \
  'del(.jobs.release.steps[] | select(.uses == "./.github/actions/native-setup"))' \
  'job release should check its runner with the native setup (machine: ${{ matrix.machine }})'

# The call says pinned, so the binary would be handed over and kept.
refuses build-with-the-latest-toolchain workflow \
  '(.jobs.release.steps[] | select(.uses == "./.github/actions/native-setup") | .with.toolchain) = "latest"' \
  'job release should set up the machine of its matrix and the toolchain of the call'

refuses build-with-a-condition workflow \
  '.jobs.release.if = strenv(PINNED)' \
  "job release builds the release binary, so it should run in every run, not if: inputs.toolchain == 'pinned'"

refuses build-waits-for-plan workflow \
  '.jobs.release.needs = "plan"' \
  "job release builds the release binary, so it should need no other job, not plan"

# On main, plan may skip checks, and release would then be skipped with it.
refuses build-waits-for-the-checks workflow \
  '.jobs.release.needs = "checks"' \
  "job release builds the release binary, so it should need no other job, not checks"

refuses no-hand-over workflow \
  'del(.jobs.release.steps[] | select(.with.name == strenv(HANDED)))' \
  "job release should hand over dist/smock as $HANDED once, not 0 times"

refuses hand-over-twice workflow \
  '.jobs.release.steps += [.jobs.release.steps[] | select(.with.name == strenv(HANDED))]' \
  "job release should hand over dist/smock as $HANDED once, not 2 times"

refuses hand-over-before-the-build workflow \
  '.jobs.release.steps = [.jobs.release.steps[] | select(.with.name == strenv(HANDED))] + [.jobs.release.steps[] | select(.with.name != strenv(HANDED))]' \
  "job release hands over release-linux-<arch> before it builds the release binary"

refuses hand-over-another-file workflow \
  '(.jobs.release.steps[] | select(.with.name == strenv(HANDED)) | .with.path) = "_build"' \
  "job release should hand over dist/smock, which scripts/build-release.sh writes, not _build"

# The documents say that the failed jobs of a run can be run again within
# 7 days: the binary must still be there.
refuses hand-over-kept-one-day workflow \
  '(.jobs.release.steps[] | select(.with.name == strenv(HANDED)) | .with.retention-days) = 1' \
  "release-linux-<arch> of job release should be kept for 7 days (retention-days), not 1"

refuses hand-over-kept-too-long workflow \
  '(.jobs.release.steps[] | select(.with.name == strenv(HANDED)) | .with.retention-days) = 30' \
  "release-linux-<arch> of job release should be kept for 7 days (retention-days), not 30"

refuses hand-over-whatever-happened workflow \
  '(.jobs.release.steps[] | select(.with.name == strenv(HANDED)) | .if) = "always() && " + strenv(PINNED)' \
  "job release should hand over release-linux-<arch> with the pinned toolchain only, and only when every step before it passed"

refuses hand-over-with-any-toolchain workflow \
  'del(.jobs.release.steps[] | select(.with.name == strenv(HANDED)) | .if)' \
  "job release should hand over release-linux-<arch> with the pinned toolchain only, and only when every step before it passed (if: inputs.toolchain == 'pinned'), not none"

refuses build-job-keeps-the-binary workflow \
  '(.jobs.release.steps[] | select(.with.name == strenv(HANDED)) | .with.name) = "smock-linux-${{ matrix.arch }}"' \
  'job release should not upload smock-linux-${{ matrix.arch }} itself'

# --- The SDK job -----------------------------------------------------------------

refuses no-sdk-job workflow \
  'del(.jobs.llm-sdks.steps[] | select(.with.name == "release-linux-amd64"))' \
  "one job, the SDK job, should download release-linux-amd64, not 0"

refuses sdk-job-without-the-build workflow \
  'del(.jobs.llm-sdks.needs)' \
  "job llm-sdks should need the job that builds the release binary and nothing else, not nothing"

refuses sdk-job-waits-for-plan workflow \
  '.jobs.llm-sdks.needs = ["release", "plan"]' \
  "job llm-sdks should need the job that builds the release binary and nothing else, not release, plan"

refuses sdk-job-on-arm workflow \
  '.jobs.llm-sdks.runs-on = "ubuntu-24.04-arm"' \
  "job llm-sdks should run on an amd64 runner, not ubuntu-24.04-arm"

refuses sdk-job-without-the-sdks workflow \
  'del(.jobs.llm-sdks.steps[] | select(.run == "scripts/check-llm-sdks.sh dist/smock"))' \
  "job llm-sdks should run scripts/check-llm-sdks.sh"

refuses sdk-job-builds workflow \
  '.jobs.llm-sdks.steps += [{"run": "moon build --target native"}]' \
  "job llm-sdks should build nothing, but a step runs moon or scripts/build-release.sh"

refuses sdk-job-with-any-toolchain workflow \
  'del(.jobs.llm-sdks.if)' \
  "job llm-sdks should run with the pinned toolchain only, and only when the build passed (if: inputs.toolchain == 'pinned'), not none"

refuses sdk-job-whatever-happened workflow \
  '.jobs.llm-sdks.if = "always() && " + strenv(PINNED)' \
  "job llm-sdks should run with the pinned toolchain only, and only when the build passed"

# --- The job plan ------------------------------------------------------------------

refuses plan-on-every-branch workflow \
  '.jobs.plan.if = "inputs.toolchain == '"'"'pinned'"'"' && github.event_name == '"'"'push'"'"'"' \
  "job plan should run only for a push to main with the pinned toolchain"

refuses plan-says-false workflow \
  '(.jobs.plan.steps[] | select(has("run")) | .run) = "echo full=false >>\"$GITHUB_OUTPUT\""' \
  'job plan should run one command, scripts/ci-plan.sh >>"$GITHUB_OUTPUT", not: echo full=false'

refuses plan-says-more workflow \
  '.jobs.plan.steps += [{"run": "echo full=false >>\"$GITHUB_OUTPUT\""}]' \
  'job plan should run one command, scripts/ci-plan.sh >>"$GITHUB_OUTPUT", not: '

refuses plan-with-another-output workflow \
  '.jobs.plan.outputs.full = "false"' \
  "job plan should have one output, full, which is what scripts/ci-plan.sh said"

refuses plan-with-another-action workflow \
  '.jobs.plan.steps += [{"uses": "actions/github-script@v8"}]' \
  "job plan should only check out the commit and run scripts/ci-plan.sh, not actions/github-script@v8"

# --- The jobs that plan may skip, and the others ---------------------------------

for job in checks test release-test; do
  # plan is skipped on every branch but main, and a job that needs a skipped
  # job is skipped with it unless its condition has a status function.
  refuses "$job-with-no-condition" workflow \
    "del(.jobs.$job.if)" \
    "job $job should run unless plan said false (if: $GATED), not none"

  refuses "$job-never" workflow \
    ".jobs.$job.if = false" \
    "job $job should run unless plan said false (if: $GATED), not if: false"
done

refuses tests-only-when-plan-says-so workflow \
  '.jobs.test.if = "${{ needs.plan.outputs.full == '"'"'true'"'"' }}"' \
  "job test should run unless plan said false"

refuses tests-skipped-with-plan workflow \
  '.jobs.checks.if = "${{ needs.plan.outputs.full != '"'"'false'"'"' }}"' \
  "job checks should run unless plan said false"

refuses tests-on-pull-requests-only workflow \
  '.jobs.test.if |= sub(" }}$"; " && github.event_name == '"'"'pull_request'"'"' }}")' \
  "job test should run unless plan said false"

# Where plan is skipped, its output is the empty string.
refuses checks-only-where-plan-ran workflow \
  '.jobs.checks.if |= sub(" }}$"; " && needs.plan.outputs.full != '"''"' }}")' \
  "job checks should run unless plan said false"

refuses checks-or-not workflow \
  '.jobs.checks.if |= sub(" }}$"; " || false }}")' \
  "job checks should run unless plan said false"

refuses tests-with-the-pinned-toolchain-only workflow \
  '.jobs.release-test.if = strenv(PINNED)' \
  "job release-test should run unless plan said false"

refuses tests-wait-for-more workflow \
  '.jobs.test.needs = ["plan", "checks"]' \
  "job test, which plan may skip, should need plan alone, not plan, checks"

refuses conformance-with-a-condition workflow \
  '.jobs.protobuf-conformance.if = strenv(GATED)' \
  "job protobuf-conformance does not wait for plan, so it should run in every run"

refuses tests-apart-from-plan-never workflow \
  'del(.jobs.test.needs) | .jobs.test.if = false' \
  "job test does not wait for plan, so it should run in every run, not if: false"

refuses conformance-skipped-with-the-tests workflow \
  '.jobs.protobuf-conformance.needs = "plan" | .jobs.protobuf-conformance.if = strenv(GATED)' \
  "the jobs that plan may skip should be checks, release-test and test, not: checks, protobuf-conformance, release-test, test"

refuses no-release-mode-tests workflow \
  'del(.jobs.release-test)' \
  "the jobs that plan may skip should be checks, release-test and test, not: checks, test"

# --- Both machines ---------------------------------------------------------------

for job in test release-test; do
  # The slip of copying the amd64 entry and changing its arch alone: the job
  # named arm64 would run on amd64, and the native setup would agree.
  refuses "$job-arm64-on-the-other-machine" workflow \
    "(.jobs.$job.strategy.matrix.include[] | select(.arch == \"arm64\")) |= (.runner = \"ubuntu-24.04\" | .machine = \"x86_64\")" \
    "job $job should run once for amd64 on x86_64 and once for arm64 on aarch64 (strategy.matrix.include alone), not for: amd64 on x86_64, arm64 on x86_64"

  refuses "$job-on-one-machine" workflow \
    "del(.jobs.$job.strategy.matrix.include[] | select(.arch == \"arm64\"))" \
    "job $job should run once for amd64 on x86_64 and once for arm64 on aarch64 (strategy.matrix.include alone), not for: amd64 on x86_64"

  refuses "$job-on-one-runner" workflow \
    ".jobs.$job.runs-on = \"ubuntu-24.04\"" \
    "job $job should run on the runner its matrix names (runs-on: \${{ matrix.runner }}), not on ubuntu-24.04"

  refuses "$job-with-the-latest-toolchain" workflow \
    "(.jobs.$job.steps[] | select(.uses == \"./.github/actions/native-setup\") | .with.toolchain) = \"latest\"" \
    "job $job should set up the machine of its matrix and the toolchain of the call"
done

refuses tests-without-a-machine workflow \
  '.jobs.test.strategy.matrix.exclude = [{"arch": "arm64"}]' \
  "job test should run once for amd64 on x86_64 and once for arm64 on aarch64 (strategy.matrix.include alone)"

refuses checks-with-the-latest-toolchain workflow \
  '(.jobs.checks.steps[] | select(.run == "scripts/install-moonbit.sh \"$TOOLCHAIN\"") | .env.TOOLCHAIN) = "latest"' \
  'job checks should install the toolchain of the call (scripts/install-moonbit.sh "$TOOLCHAIN" with TOOLCHAIN: ${{ inputs.toolchain }})'

# --- What governs the mutation runner (#309, #302) --------------------------------

# The runner's tests, its self-test on the fixture module, the site-count
# check and the check of the exclusion list run in job checks, which the
# weekly run with the latest MoonBit runs too, once each.
export SELF_TEST='python3 scripts/mutation/run.py --root scripts/mutation/fixture --self-test-only calc log'
export SITE_COUNTS='python3 scripts/mutation/ratchet.py check --base origin/main'
export RUNNER_TESTS='python3 -m unittest discover -s scripts/mutation -v'
export EXCLUSIONS_CHECK='python3 scripts/mutation/exclusions.py check'
for named in "self-test|$SELF_TEST" "site-counts|$SITE_COUNTS" "runner-tests|$RUNNER_TESTS" \
  "exclusions|$EXCLUSIONS_CHECK"; do
  export COMMAND="${named#*|}"
  refuses "no-${named%%|*}" workflow \
    'del(.jobs.checks.steps[] | select(.run == strenv(COMMAND)))' \
    "job checks should run $COMMAND once, not 0 times"
done

refuses the-self-test-twice workflow \
  '.jobs.checks.steps += [{"name": "Again", "run": strenv(SELF_TEST)}]' \
  "job checks should run $SELF_TEST once, not 2 times"

# On a machine of its own, it would not run in the weekly run's job checks.
refuses the-site-counts-in-another-job workflow \
  '(.jobs.test.steps += [.jobs.checks.steps[] | select(.run == strenv(SITE_COUNTS))]) | del(.jobs.checks.steps[] | select(.run == strenv(SITE_COUNTS)))' \
  "job checks should run $SITE_COUNTS once, not 0 times"

refuses the-site-counts-against-another-base workflow \
  '(.jobs.checks.steps[] | select(.run == strenv(SITE_COUNTS)) | .run) = "python3 scripts/mutation/ratchet.py check --base HEAD"' \
  "job checks should run $SITE_COUNTS once, not 0 times"

refuses the-self-test-with-the-pinned-toolchain-only workflow \
  '(.jobs.checks.steps[] | select(.run == strenv(SELF_TEST)) | .if) = strenv(PINNED)' \
  "the step \"Run the mutation runner's self-test on its fixture\" of job checks should run whenever its job does, not if: inputs.toolchain =="

# The check of the exclusion list reads the definitions with the compiler's
# parser, so it runs where the toolchain is, in job checks, not elsewhere.
refuses the-exclusion-list-in-another-job workflow \
  '(.jobs.test.steps += [.jobs.checks.steps[] | select(.run == strenv(EXCLUSIONS_CHECK))]) | del(.jobs.checks.steps[] | select(.run == strenv(EXCLUSIONS_CHECK)))' \
  "job checks should run $EXCLUSIONS_CHECK once, not 0 times"

refuses checks-without-the-history workflow \
  'del(.jobs.checks.steps[] | select(.uses == "actions/checkout@v7") | .with)' \
  "job checks should check out the whole history (fetch-depth: 0), so that the site-count check finds the merge base with main"

refuses checks-with-one-commit workflow \
  '(.jobs.checks.steps[] | select(.uses == "actions/checkout@v7") | .with.fetch-depth) = 1' \
  "job checks should check out the whole history (fetch-depth: 0)"

# --- Each step runs whenever its job does --------------------------------------

refuses a-test-step-never workflow \
  '(.jobs.test.steps[] | select(.run == "moon test --target native") | .if) = false' \
  'the step "Test every module natively" of job test should run whenever its job does, not if: false'

# Push runs on branches would skip the step, and scripts/ci-plan.sh trusts
# exactly those runs.
refuses a-test-step-on-pull-requests-only workflow \
  '(.jobs.test.steps[] | select(.run == "moon test --target native") | .if) = "github.event_name == '"'"'pull_request'"'"'"' \
  'the step "Test every module natively" of job test should run whenever its job does, not if: github.event_name =='

# The condition of the h2spec steps, copied to a step it is not for.
refuses a-test-step-on-amd64-only workflow \
  '(.jobs.test.steps[] | select(.run == "moon test --target native") | .if) = "matrix.arch == '"'"'amd64'"'"'"' \
  'the step "Test every module natively" of job test should run whenever its job does, not if: matrix.arch =='

refuses a-check-with-the-pinned-toolchain-only workflow \
  '(.jobs.checks.steps[] | select(.run == "moon check --deny-warn --target all") | .if) = strenv(PINNED)' \
  'the step "Check every target" of job checks should run whenever its job does, not if: inputs.toolchain =='

refuses the-suite-on-a-cache-miss-only workflow \
  '(.jobs.protobuf-conformance.steps[] | select(.name == "Run protobuf'"'"'s conformance suite against smock/protobuf") | .if) = "steps.runner.outputs.cache-hit != '"'"'true'"'"'"' \
  "of job protobuf-conformance should run whenever its job does, not if: steps.runner.outputs.cache-hit !="

refuses a-step-after-a-failure-only workflow \
  '(.jobs.release.steps[] | select(.run == "scripts/check-schema.sh dist/smock") | .if) = "failure()"' \
  'the step "Cross-check the JSON Schema with smock" of job release should run whenever its job does, not if: failure()'

# --- Nothing hides a failure -----------------------------------------------------

refuses a-command-that-may-fail workflow \
  '(.jobs.test.steps[] | select(.run == "moon test --target native") | .run) = "moon test --target native || true"' \
  'the step "Test every module natively" of job test should fail when a command of it fails: no || and no set +e'

refuses commands-that-may-fail workflow \
  '(.jobs.release.steps[] | select(.name == "Make the image'"'"'s SBOM as the release workflow does") | .run) |= "set +e\n" + .' \
  "of job release should fail when a command of it fails: no || and no set +e"

refuses a-shell-that-goes-on workflow \
  '(.jobs.release.steps[] | select(.name == "Make the image'"'"'s SBOM as the release workflow does") | .shell) = "bash {0}"' \
  "of job release should not set its shell or working directory"

refuses tests-of-one-module workflow \
  '(.jobs.test.steps[] | select(.run == "moon test --target native") | .working-directory) = "yaml"' \
  'the step "Test every module natively" of job test should not set its shell or working directory'

refuses default-shell workflow \
  '.defaults.run.shell = "bash {0}"' \
  "it should set no defaults: a shell of another kind may not stop at a failed command"

refuses a-job-with-a-default-shell workflow \
  '.jobs.release.defaults.run.shell = "bash {0}"' \
  "it should set no defaults: a shell of another kind may not stop at a failed command"

refuses a-group-in-the-called-workflow workflow \
  '.concurrency = {"group": "ci-${{ github.ref }}", "cancel-in-progress": true}' \
  "it should set no concurrency group: it would be shared with the calling workflow, and cancel its runs"

refuses a-group-for-the-build workflow \
  '.jobs.release.concurrency = {"group": "release-${{ matrix.arch }}", "cancel-in-progress": true}' \
  "it should set no concurrency group: it would be shared with the calling workflow, and cancel its runs"

refuses another-artifact workflow \
  '.jobs.test.steps += [{"uses": "actions/upload-artifact@v7", "with": {"name": "${{ format('"'"'smock-linux-{0}'"'"', matrix.arch) }}", "path": "dist/smock"}}]' \
  'job test should upload release-linux-${{ matrix.arch }} or protobuf-conformance, not ${{ format('

refuses sdk-job-reads-another-run workflow \
  '(.jobs.llm-sdks.steps[] | select(.with.name == "release-linux-amd64") | .with.run-id) = "1"' \
  "job llm-sdks should download this run's release-linux-amd64 into dist, not"

refuses plan-told-the-time workflow \
  '(.jobs.plan.steps[] | select(has("run")) | .env.PLAN_NOW) = "0"' \
  "job plan should give scripts/ci-plan.sh the token and nothing else (env: GH_TOKEN), not"

refuses a-job-that-continues-on-error workflow \
  '.jobs.test.continue-on-error = true' \
  "job test should not continue on error: a failed check would pass"

refuses a-step-that-continues-on-error workflow \
  '(.jobs.release.steps[] | select(.run == "scripts/check-h2spec.sh dist/smock plain tls") | .continue-on-error) = true' \
  'the step "Run h2spec against the plain port (h2c) and the TLS port (h2)" of job release should not continue on error'

refuses a-step-of-plan-that-continues-on-error workflow \
  '(.jobs.plan.steps[] | select(has("run")) | .continue-on-error) = true' \
  'of job plan should not continue on error'

refuses a-keeper-in-the-called-workflow workflow \
  '.jobs.keep = {"runs-on": "ubuntu-24.04", "steps": [{"uses": "actions/upload-artifact/merge@v7", "with": {"name": "smock-linux-amd64", "pattern": "release-linux-amd64"}}]}' \
  "job keep should not keep the binaries: the calling workflow does, once its every job passed"

refuses a-scripts-step-that-continues-on-error caller \
  '(.jobs.scripts.steps[] | select(.run == "scripts/check-openapi.sh") | .continue-on-error) = true' \
  'the step "Check that the Admin API document is valid OpenAPI" of job scripts should not continue on error'

refuses a-call-that-continues-on-error caller \
  '.jobs.build-test.continue-on-error = true' \
  "job build-test should not continue on error: a failed check would pass"

# --- The calling workflow ----------------------------------------------------------

# The group as the documentation of GitHub writes it: a push to main would
# cancel the run of the commit before, which then keeps no binaries.
refuses one-group-for-main caller \
  '.concurrency.group = "${{ github.workflow }}-${{ github.ref }}"' \
  "it should cancel an older run of the same branch or pull request, and never a run on main"

refuses nothing-cancelled caller \
  'del(.concurrency)' \
  "it should cancel an older run of the same branch or pull request, and never a run on main" \
  "not null"

refuses a-group-for-keep caller \
  '.jobs.keep.concurrency = "keep"' \
  "job keep should set no concurrency group: it could cancel a run on main"

# A push that changes documents alone would get no run and no binaries.
refuses no-run-for-documents caller \
  '.on.push.paths-ignore = ["**.md"]' \
  "it should run on a push to any branch but dependabot/** and on a pull request, not on:"

refuses no-run-on-main caller \
  '.on.push.branches-ignore += ["main"]' \
  "it should run on a push to any branch but dependabot/** and on a pull request, not on:"

refuses pull-requests-with-the-base-token caller \
  'del(.on.pull_request) | .on.pull_request_target = null' \
  "it should run on a push to any branch but dependabot/** and on a pull request, not on:"

refuses called-for-each-of-a-matrix caller \
  '.jobs.build-test.strategy.matrix.n = [1, 2]' \
  "job build-test calls build-test.yml, so it should run in every run, once: no condition, no needs and no matrix"

refuses scripts-on-pull-requests-only caller \
  '.jobs.scripts.if = "github.event_name == '"'"'pull_request'"'"'"' \
  "job scripts should run in every run, once: no condition, no needs and no matrix"

refuses a-scripts-step-never caller \
  '(.jobs.scripts.steps[] | select(.run == "scripts/check-openapi.sh") | .if) = false' \
  'the step "Check that the Admin API document is valid OpenAPI" of job scripts should run whenever its job does'

refuses a-scripts-command-that-may-fail caller \
  '(.jobs.scripts.steps[] | select(.run == "scripts/test-helm-chart.sh") | .run) = "scripts/test-helm-chart.sh || true"' \
  "of job scripts should fail when a command of it fails: no || and no set +e"

refuses this-check-not-run caller \
  'del(.jobs.scripts.steps[] | select(.run == "scripts/check-ci-artifacts.sh"))' \
  "a job that the binaries wait for should run scripts/check-ci-artifacts.sh once, not 0 times"

refuses this-test-not-run caller \
  'del(.jobs.scripts.steps[] | select(.run == "scripts/test-check-ci-artifacts.sh"))' \
  "a job that the binaries wait for should run scripts/test-check-ci-artifacts.sh once, not 0 times"

refuses this-check-may-fail caller \
  '(.jobs.scripts.steps[] | select(.run == "scripts/check-ci-artifacts.sh") | .run) = "scripts/check-ci-artifacts.sh || true"' \
  "a job that the binaries wait for should run scripts/check-ci-artifacts.sh once, not 0 times"

# yaml-test-suite runs against smock's YAML parser in every run, and its
# verdict's test too: a run without them would keep binaries whose parser
# no suite checked.
refuses yaml-test-suite-not-run caller \
  'del(.jobs.yaml-test-suite.steps[] | select(.run == "scripts/check-yaml-test-suite.sh"))' \
  "a job that the binaries wait for should run scripts/check-yaml-test-suite.sh once, not 0 times"

refuses yaml-test-suite-run-twice caller \
  '.jobs.scripts.steps += [{"run": "scripts/check-yaml-test-suite.sh"}]' \
  "a job that the binaries wait for should run scripts/check-yaml-test-suite.sh once, not 2 times"

refuses yaml-test-suite-may-fail caller \
  '(.jobs.yaml-test-suite.steps[] | select(.run == "scripts/check-yaml-test-suite.sh") | .run) = "scripts/check-yaml-test-suite.sh || true"' \
  "a job that the binaries wait for should run scripts/check-yaml-test-suite.sh once, not 0 times"

refuses yaml-test-suite-verdict-not-tested caller \
  'del(.jobs.scripts.steps[] | select(.run == "scripts/test-yaml-test-suite-verdict.sh"))' \
  "a job that the binaries wait for should run scripts/test-yaml-test-suite-verdict.sh once, not 0 times"

refuses yaml-test-suite-on-pull-requests-only caller \
  '.jobs.yaml-test-suite.if = "github.event_name == '"'"'pull_request'"'"'"' \
  "job yaml-test-suite should run in every run, once: no condition, no needs and no matrix"

refuses yaml-test-suite-after-the-build caller \
  '.jobs.yaml-test-suite.needs = "build-test"' \
  "job yaml-test-suite should run in every run, once: no condition, no needs and no matrix"

# --- The coverage job (#297) ---------------------------------------------------------

# The coverage ratchet runs in every run, after the coverage run of the
# same job, against the merge base with main: a run without it would keep
# binaries whose floors nothing checked.
refuses coverage-not-run caller \
  'del(.jobs.coverage.steps[] | select(.run == strenv(COVERAGE)))' \
  "a job that the binaries wait for should run $COVERAGE once, not 0 times"

refuses ratchet-not-run caller \
  'del(.jobs.coverage.steps[] | select(.run == strenv(RATCHET)))' \
  "a job that the binaries wait for should run $RATCHET once, not 0 times"

refuses ratchet-may-fail caller \
  '(.jobs.coverage.steps[] | select(.run == strenv(RATCHET)) | .run) = strenv(RATCHET) + " || true"' \
  "a job that the binaries wait for should run $RATCHET once, not 0 times"

refuses ratchet-against-another-base caller \
  '(.jobs.coverage.steps[] | select(.run == strenv(RATCHET)) | .run) |= sub("origin/main"; "HEAD")' \
  "a job that the binaries wait for should run $RATCHET once, not 0 times"

refuses ratchet-test-not-run caller \
  'del(.jobs.scripts.steps[] | select(.run == "scripts/test-coverage-ratchet.sh"))' \
  "a job that the binaries wait for should run scripts/test-coverage-ratchet.sh once, not 0 times"

# The ratchet reads the bisect report that the coverage run wrote on the
# same runner.
refuses ratchet-in-another-job caller \
  '.jobs.scripts.steps += [.jobs.coverage.steps[] | select(.run == strenv(RATCHET))] | del(.jobs.coverage.steps[] | select(.run == strenv(RATCHET)))' \
  "job coverage should check the floors (python3 scripts/coverage-ratchet.py check) after scripts/coverage.sh"

refuses ratchet-before-the-run caller \
  '.jobs.coverage.steps = [.jobs.coverage.steps[] | select(.run == strenv(RATCHET))] + [.jobs.coverage.steps[] | select(.run != strenv(RATCHET))]' \
  "job coverage should check the floors (python3 scripts/coverage-ratchet.py check) after scripts/coverage.sh"

# Off the arm64 native tests' path: amd64's native builds are about six
# times faster (#276).
refuses coverage-on-arm caller \
  '.jobs.coverage.runs-on = "ubuntu-24.04-arm"' \
  "job coverage should run on an amd64 runner, not ubuntu-24.04-arm"

refuses coverage-without-the-history caller \
  'del(.jobs.coverage.steps[] | select(.uses == "actions/checkout@v7") | .with)' \
  "job coverage should check out the whole history (fetch-depth: 0), so that the ratchet finds the merge base with main"

refuses coverage-on-pull-requests-only caller \
  '.jobs.coverage.if = "github.event_name == '"'"'pull_request'"'"'"' \
  "job coverage should run in every run, once: no condition, no needs and no matrix"

refuses coverage-after-the-build caller \
  '.jobs.coverage.needs = "build-test"' \
  "job coverage should run in every run, once: no condition, no needs and no matrix"

refuses coverage-that-continues-on-error caller \
  '.jobs.coverage.continue-on-error = true' \
  "job coverage should not continue on error: a failed check would pass"

refuses ratchet-that-continues-on-error caller \
  '(.jobs.coverage.steps[] | select(.run == strenv(RATCHET)) | .continue-on-error) = true' \
  'of job coverage should not continue on error'

# The report is kept, also when the ratchet failed, under one name.
refuses no-coverage-report caller \
  'del(.jobs.coverage.steps[] | select(.with.name == "coverage-report"))' \
  "job coverage should keep the coverage report as coverage-report once, not 0 times"

refuses coverage-report-twice caller \
  '.jobs.coverage.steps += [.jobs.coverage.steps[] | select(.with.name == "coverage-report")]' \
  "job coverage should keep the coverage report as coverage-report once, not 2 times"

refuses coverage-report-only-after-success caller \
  'del(.jobs.coverage.steps[] | select(.with.name == "coverage-report") | .if)' \
  "job coverage should keep coverage-report also when a step before it failed (if: !cancelled()), not none"

refuses coverage-report-kept-one-day caller \
  '(.jobs.coverage.steps[] | select(.with.name == "coverage-report") | .with.retention-days) = 1' \
  "coverage-report of job coverage should be kept for 7 days (retention-days), not 1"

refuses coverage-report-without-the-report caller \
  '(.jobs.coverage.steps[] | select(.with.name == "coverage-report") | .with.path) = "_coverage/coverage.bisect"' \
  "job coverage should keep coverage-report.txt and _coverage/coverage.bisect as coverage-report"

refuses another-artifact-in-the-caller caller \
  '.jobs.scripts.steps += [{"uses": "actions/upload-artifact@v7", "with": {"name": "scripts-logs", "path": "logs"}}]' \
  "job scripts should upload only coverage-report, from job coverage, not scripts-logs"

refuses called-with-the-latest-toolchain caller \
  '.jobs.build-test.with.toolchain = "latest"' \
  "it should call build-test.yml with toolchain: pinned, with which the release binaries are handed over"

refuses called-twice caller \
  '.jobs.again = .jobs.build-test' \
  "it should call build-test.yml once, not 2 times"

refuses not-called caller \
  'del(.jobs.build-test)' \
  "it should call build-test.yml once, not 0 times"

refuses called-on-pull-requests-only caller \
  '.jobs.build-test.if = "github.event_name == '"'"'pull_request'"'"'"' \
  "job build-test calls build-test.yml, so it should run in every run, once: no condition, no needs and no matrix"

refuses called-after-the-scripts caller \
  '.jobs.build-test.needs = "scripts"' \
  "job build-test calls build-test.yml, so it should run in every run, once: no condition, no needs and no matrix"

# --- The job that keeps the binaries -----------------------------------------

refuses no-keep-job caller \
  'del(.jobs.keep)' \
  "one job should keep the binaries (actions/upload-artifact/merge), not 0"

refuses one-binary-kept caller \
  'del(.jobs.keep.steps[] | select(.with.name == "smock-linux-arm64"))' \
  "job keep should make smock-linux-arm64 once, not 0 times"

refuses kept-of-the-other-architecture caller \
  '(.jobs.keep.steps[] | select(.with.name == "smock-linux-arm64") | .with.pattern) = "release-linux-amd64"' \
  "job keep should make smock-linux-arm64 of release-linux-arm64, not of release-linux-amd64"

refuses kept-of-everything caller \
  '(.jobs.keep.steps[] | select(.with.name == "smock-linux-amd64") | .with.pattern) = "*"' \
  "job keep should make smock-linux-amd64 of release-linux-amd64, not of *"

refuses kept-too-long caller \
  '(.jobs.keep.steps[] | select(.with.name == "smock-linux-amd64") | .with.retention-days) = 90' \
  "smock-linux-amd64 should be kept for 7 days (retention-days), not 90"

refuses kept-with-no-limit caller \
  'del(.jobs.keep.steps[] | select(.with.name == "smock-linux-amd64") | .with.retention-days)' \
  "smock-linux-amd64 should be kept for 7 days (retention-days), not null"

refuses kept-beside-the-handed-over-copy caller \
  'del(.jobs.keep.steps[] | select(.with.name == "smock-linux-amd64") | .with.delete-merged)' \
  "job keep should only make smock-linux-<arch> of release-linux-<arch> and remove the latter"

# The binary would lie in a directory of the artifact, not at its root.
refuses kept-in-a-directory caller \
  '(.jobs.keep.steps[] | select(.with.name == "smock-linux-amd64") | .with.separate-directories) = true' \
  "job keep should only make smock-linux-<arch> of release-linux-<arch> and remove the latter"

refuses keep-does-more caller \
  '.jobs.keep.steps += [{"run": "true"}]' \
  "job keep should only make smock-linux-<arch> of release-linux-<arch> and remove the latter"

refuses kept-whatever-happened caller \
  '(.jobs.keep.steps[] | select(.with.name == "smock-linux-arm64") | .if) = "always()"' \
  "job keep should make smock-linux-arm64 whenever it runs, not if: always()"

for job in build-test scripts yaml-test-suite coverage; do
  refuses "keep-without-$job" caller \
    ".jobs.keep.needs -= [\"$job\"]" \
    "job keep should need job $job, so that it keeps nothing when that job fails"

  refuses "keep-whatever-$job-did" caller \
    ".jobs.keep.if |= sub(\" && needs[.]${job}[.]result == 'success'\"; \"\")" \
    "job keep should run only when the run was not cancelled and every other job succeeded (if: $KEEP)"
done

refuses a-job-that-keep-does-not-need caller \
  '.jobs.extra = {"runs-on": "ubuntu-24.04", "steps": [{"run": "true"}]}' \
  "job keep should need job extra, so that it keeps nothing when that job fails" \
  "job keep should run only when the run was not cancelled and every other job succeeded"

refuses keep-when-cancelled caller \
  '.jobs.keep.if |= sub("!cancelled[(][)] && "; "")' \
  "job keep should run only when the run was not cancelled and every other job succeeded"

refuses keep-or-anything caller \
  '.jobs.keep.if |= sub(" }}$"; " || true }}")' \
  "job keep should run only when the run was not cancelled and every other job succeeded"

refuses keep-or-after-a-failure caller \
  '.jobs.keep.if |= sub(" }}$"; " || failure() }}")' \
  "job keep should run only when the run was not cancelled and every other job succeeded"

refuses keep-unless-a-job-failed caller \
  '.jobs.keep.if = "${{ !cancelled() && !contains(needs.*.result, '"'"'failure'"'"') }}"' \
  "job keep should run only when the run was not cancelled and every other job succeeded"

refuses keep-always caller \
  '.jobs.keep.if = "always()"' \
  "job keep should run only when the run was not cancelled and every other job succeeded"

refuses keep-with-no-condition caller \
  'del(.jobs.keep.if)' \
  "job keep should run only when the run was not cancelled and every other job succeeded" \
  "not none"

refuses another-job-keeps-a-binary caller \
  '.jobs.scripts.steps += [{"uses": "actions/upload-artifact@v7", "with": {"name": "smock-linux-amd64", "path": "dist/smock"}}]' \
  "job scripts should not upload smock-linux-amd64 itself"

echo
echo "test-check-ci-artifacts: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
