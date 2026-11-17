#!/bin/sh
# Checks the conditions under which CI's jobs run and CI keeps the release
# binary of each architecture as a workflow artifact, which the GKE run of
# the benchmark takes for an architecture its machine cannot build for
# (scripts/gke-bench.sh --arch, docs/merging-into-main.md). A kept binary
# must come from a run whose every check passed, and a run must not skip a
# check and still pass, but for the tests that the job plan skips on main:
# scripts/ci-plan.sh skips them there because the merged branch's run, which
# never skips them, passed them on the same tree.
#
# A condition is compared whole, not searched for a part: a condition with
# one more term, such as `|| true`, is another condition.
#
# In the workflow that builds and tests (.github/workflows/build-test.yml):
#
# - The jobs that build the release binary with scripts/build-release.sh
#   run on linux/amd64 and on linux/arm64, each on a runner that the native
#   setup checks to be that machine. They run in every run: they have no
#   condition and need no other job. After the build they hand over
#   dist/smock, which the script writes and the image packs, as
#   release-linux-<arch>, kept for 7 days, with the pinned toolchain only.
# - One job, the SDK job (llm-sdks/README.md), downloads
#   release-linux-amd64. It needs the job that builds it and nothing else,
#   runs on an amd64 runner with the pinned toolchain only, runs
#   scripts/check-llm-sdks.sh, and builds nothing: no step runs moon or
#   scripts/build-release.sh.
# - The job plan runs only for a push to main with the pinned toolchain,
#   and its one command is scripts/ci-plan.sh, whose answer is the job's
#   output.
# - A job that needs plan needs nothing else and runs unless plan said
#   full=false: when plan did not run, failed or said nothing, it runs.
#   Every other job runs in every run: it has no condition.
# - The jobs that plan may skip are checks, test and release-test, and no
#   other.
# - The job checks, which runs with either toolchain, runs the mutation
#   runner's tests, its self-test on the fixture module and the site-count
#   check against the merge base with main, each once (#309), and checks
#   out the whole history, so that the check finds that merge base.
# - Every job with a matrix runs once for amd64 on x86_64 and once for arm64
#   on aarch64, on the runner its matrix names, and every native setup
#   checks that machine and installs the toolchain of the call.
# - A step runs whenever its job does, but for the few that are for one
#   architecture, for the pinned toolchain, or for a cache miss, each named
#   below with its condition. No job or step continues on error, but for the
#   job plan, whose failure skips nothing; no command ends in `|| ...` or
#   turns off `set -e`; no step sets its shell or working directory.
# - No job keeps a binary here: none uploads smock-linux-<arch> or merges
#   artifacts, and the artifacts' names are release-linux-<arch> and
#   protobuf-conformance. Nothing sets a concurrency group here: one would
#   be shared with the calling workflow.
#
# In the workflow that runs on each push and pull request
# (.github/workflows/ci.yml):
#
# - It runs on a push to any branch but dependabot/** and on a pull
#   request, and cancels an older run of the same branch or pull request,
#   but never a run on main: every commit of main gets its binaries.
# - It calls build-test.yml once, with the pinned toolchain, in every run.
# - One job keeps the binaries. It makes smock-linux-amd64 and
#   smock-linux-arm64 of release-linux-amd64 and release-linux-arm64, each
#   once and kept for 7 days, and does nothing else. It needs every other
#   job of the workflow, and runs only when the run was not cancelled and
#   each of them succeeded.
# - Every other job runs in every run, and each of its steps runs whenever
#   the job does, also after a failed step (!cancelled()). No job or step
#   continues on error or hides a failed command, and no other job uploads
#   smock-linux-<arch>.
# - Those jobs run, each once: this check and its test, yaml-test-suite
#   against smock's YAML parser (scripts/check-yaml-test-suite.sh), and the
#   test of its verdict (scripts/test-yaml-test-suite-verdict.sh).
#
# scripts/test-check-ci-artifacts.sh tests this check. It needs yq
# (mikefarah/yq v4, on GitHub's Ubuntu runners) and jq.
#
# usage: scripts/check-ci-artifacts.sh [workflow file [calling workflow file]]
set -eu
cd "$(dirname "$0")/.."

workflow=${1:-.github/workflows/build-test.yml}
caller=${2:-.github/workflows/ci.yml}

for file in "$workflow" "$caller"; do
  if [ ! -f "$file" ]; then
    echo "check-ci-artifacts: $file does not exist" >&2
    exit 1
  fi
done

# The conditions, as the workflows write them inside ${{ }} or bare.
pinned="inputs.toolchain == 'pinned'"
unless_plan_said_false="!cancelled() && needs.plan.outputs.full != 'false'"
push_to_main="inputs.toolchain == 'pinned' && github.event_name == 'push' && github.ref == 'refs/heads/main'"
# shellcheck disable=SC2016 # the workflow's own text, not this shell's variable
plan_command='scripts/ci-plan.sh >>"$GITHUB_OUTPUT"'
# The calling workflow's concurrency group: one for each branch or pull
# request, and one for each run on main.
# shellcheck disable=SC2016 # the workflow's own text
group='ci-${{ github.event_name }}-${{ github.ref == '"'refs/heads/main'"' && github.run_id || github.ref }}'

# What both jq programs below use.
# shellcheck disable=SC2016 # jq's variables and the workflows' ${{ }}, not this shell's
common='
  def command: (.run // "") | tostring;
  def builds: command | test("(^|[;&|[:space:]])scripts/build-release\\.sh");
  def uploads: (.uses // "") | startswith("actions/upload-artifact@");
  def merges: (.uses // "") | startswith("actions/upload-artifact/merge@");
  def downloads: (.uses // "") | startswith("actions/download-artifact@");
  def runs($pattern): command | test($pattern);
  def step_name: .name // .run // .uses | tostring;
  def needed: [.value.needs // empty] | flatten;
  # A condition on one line, without the ${{ }} around it; null for none.
  def expression:
    if . == null then null
    else tostring | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | sub("^\\$\\{\\{ ?"; "") | sub(" ?\\}\\}$"; "") end;
  def condition: .value.if | expression;
  def shown: if . == null then "none" else "if: \(.)" end;
  def days_problem($what):
    .with["retention-days"] as $days
    | if $days == 7 then empty
      else "\($what) should be kept for 7 days (retention-days), not \($days)" end;
  # What continues on error in a job: the job itself, or its steps.
  def continues:
    (select((.value["continue-on-error"] // false) != false) | "job \(.key)"),
    (.key as $job | .value.steps[]? | select((.["continue-on-error"] // false) != false)
     | "the step \"\(step_name)\" of job \($job)");
  # What would let a failed command pass, or run it somewhere else: for a
  # whole workflow, one line each.
  def hides_a_failure:
    (.jobs | to_entries[] | .key as $job | .value.steps[]? | select(has("run"))
     | select(command | test("\\|\\||set +[+][a-z]"))
     | "the step \"\(step_name)\" of job \($job) should fail when a command of it fails: no || and no set +e"),
    (.jobs | to_entries[] | .key as $job | .value.steps[]? | select(has("shell") or has("working-directory"))
     | "the step \"\(step_name)\" of job \($job) should not set its shell or working directory"),
    (if has("defaults") or any(.jobs[]; has("defaults")) then
       "it should set no defaults: a shell of another kind may not stop at a failed command"
     else empty end);
  def keeps_itself:
    .key as $job | .value.steps[]? | select(uploads)
    | select((.with.name // "") | startswith("smock-linux-"))
    | "job \($job) should not upload \(.with.name) itself: one job keeps the binaries, once every job passed";
'

# What is wrong with the workflow that builds and tests, one line each.
problems=$(yq --output-format=json "$workflow" | jq -r \
  --arg pinned "$pinned" --arg gated "$unless_plan_said_false" \
  --arg push_to_main "$push_to_main" --arg plan_command "$plan_command" \
  --arg amd64 "matrix.arch == 'amd64'" --arg cache_miss "steps.runner.outputs.cache-hit != 'true'" "$common"'
  # The steps that do not run whenever their job does, each with the one
  # condition it may have.
  def may_be_skipped($if):
    if $if == $pinned then
      command == "moon fmt --check" or (uploads and .with.name == "release-linux-${{ matrix.arch }}")
    elif $if == $amd64 then
      command as $command
      | ["scripts/install-h2spec.sh \"$RUNNER_TEMP/bin\"",
         "scripts/check-h2spec.sh dist/smock plain tls",
         "scripts/test-check-grpcurl.sh dist/smock"] | index($command) != null
    elif $if == $cache_miss then
      command == "scripts/build-conformance-runner.sh ~/.cache/smock/conformance-runner"
      or ((.uses // "") | startswith("actions/cache/save@"))
    elif $if == "failure()" then
      uploads and .with.name == "protobuf-conformance"
    else false end;

  [.jobs | to_entries[]] as $all
  | [$all[] | select(any(.value.steps[]?; builds))] as $build
  | [$all[] | select(any(.value.steps[]?; downloads and .with.name == "release-linux-amd64"))] as $sdk
  | ([$build[].value.strategy.matrix.include[]? | "\(.arch) on \(.machine)"] | sort | join(", ")) as $machines

  # The jobs that build the release binary.
  | (if $machines == "amd64 on x86_64, arm64 on aarch64" then empty
     else "the release binary should be built for amd64 on x86_64 and for arm64 on aarch64, not for: \(if $machines == "" then "nothing" else $machines end)" end),
    ($build[] | .key as $job | (.value.steps | to_entries) as $steps
     | (if condition != null then
          "job \($job) builds the release binary, so it should run in every run, not \(condition | shown)"
        else empty end),
       (if needed != [] then
          "job \($job) builds the release binary, so it should need no other job, not \(needed | join(", "))"
        else empty end),
       (([$steps[] | select(.value | builds) | .key] | first) as $built
        | [$steps[] | select(.value | uploads)
                    | select(.value.with.name == "release-linux-${{ matrix.arch }}")] as $handed
        | if ($handed | length) != 1 then
            "job \($job) should hand over dist/smock as release-linux-${{ matrix.arch }} once, not \($handed | length) times"
          else
            $handed[0] as $upload
            | (if $upload.key < $built then "job \($job) hands over release-linux-<arch> before it builds the release binary" else empty end),
              (if $upload.value.with.path != "dist/smock" then
                 "job \($job) should hand over dist/smock, which scripts/build-release.sh writes, not \($upload.value.with.path)"
               else empty end),
              ($upload.value | days_problem("release-linux-<arch> of job \($job)")),
              (($upload.value.if | expression) as $if
               | if $if != $pinned then
                   "job \($job) should hand over release-linux-<arch> with the pinned toolchain only, and only when every step before it passed (if: \($pinned)), not \($if | shown)"
                 else empty end)
          end)),

  # The SDK job.
    (if ($sdk | length) != 1 then
       "one job, the SDK job, should download release-linux-amd64, not \($sdk | length)"
     else
       $sdk[0] as $job
       | (if ($build | length) == 1 and ($job | needed) != [$build[0].key] then
            "job \($job.key) should need the job that builds the release binary and nothing else, not \(if ($job | needed) == [] then "nothing" else $job | needed | join(", ") end)"
          else empty end),
         (if ($job.value["runs-on"] | tostring | test("arm")) then
            "job \($job.key) should run on an amd64 runner, not \($job.value["runs-on"])"
          else empty end),
         (if any($job.value.steps[]?; runs("scripts/check-llm-sdks\\.sh")) | not then
            "job \($job.key) should run scripts/check-llm-sdks.sh"
          else empty end),
         (if any($job.value.steps[]?; runs("(^|[;&|[:space:]])(moon|scripts/build-release\\.sh)([[:space:]]|$)")) then
            "job \($job.key) should build nothing, but a step runs moon or scripts/build-release.sh"
          else empty end),
         (if ($job | condition) != $pinned then
            "job \($job.key) should run with the pinned toolchain only, and only when the build passed (if: \($pinned)), not \($job | condition | shown)"
          else empty end)
     end),

  # The job plan, and when each other job runs.
    ($all[] | select(.key == "plan")
     | (if condition != $push_to_main then
          "job plan should run only for a push to main with the pinned toolchain (if: \($push_to_main)), not \(condition | shown)"
        else empty end),
       ([.value.steps[] | select(has("run"))] as $commands
        | if ($commands | length) != 1 or ($commands[0] | command | gsub("\\s+"; " ") | sub(" $"; "")) != $plan_command then
            "job plan should run one command, \($plan_command), not: \([$commands[] | command] | join("; "))"
          elif .value.outputs != {"full": "${{ steps.\($commands[0].id).outputs.full }}"} then
            "job plan should have one output, full, which is what scripts/ci-plan.sh said, not \(.value.outputs | tojson)"
          elif $commands[0].env != {"GH_TOKEN": "${{ github.token }}"} then
            "job plan should give scripts/ci-plan.sh the token and nothing else (env: GH_TOKEN), not \($commands[0].env | tojson)"
          else empty end),
       (.value.steps[] | select(has("run") | not) | select(((.uses // "") | startswith("actions/checkout@")) | not)
        | "job plan should only check out the commit and run scripts/ci-plan.sh, not \(.uses // .name)")),
    ($all[] | select(.key != "plan") | . as $job
     | if (needed | index("plan")) != null then
         (if needed != ["plan"] then
            "job \(.key), which plan may skip, should need plan alone, not \(needed | join(", "))"
          else empty end),
         (if condition != $gated then
            "job \(.key) should run unless plan said false (if: ${{ \($gated) }}), not \(condition | shown)"
          else empty end)
       elif any($sdk[]; .key == $job.key) then empty
       elif condition != null then
         "job \(.key) does not wait for plan, so it should run in every run, not \(condition | shown)"
       else empty end),

  # What governs the mutation runner, in job checks.
    ($all[] | select(.key == "checks") | . as $job
     | (("python3 -m unittest discover -s scripts/mutation -v",
         "python3 scripts/mutation/run.py --root scripts/mutation/fixture --self-test-only calc log",
         "python3 scripts/mutation/ratchet.py check --base origin/main") as $command
        | ([$job.value.steps[]? | select(command == $command)] | length) as $times
        | if $times != 1 then "job checks should run \($command) once, not \($times) times" else empty end),
       (if any(.value.steps[]?; ((.uses // "") | startswith("actions/checkout@")) and .with["fetch-depth"] == 0) then empty
        else "job checks should check out the whole history (fetch-depth: 0), so that the site-count check finds the merge base with main" end)),

    (([$all[] | select((needed | index("plan")) != null) | .key] | sort) as $skipped
     | if $skipped != ["checks", "release-test", "test"] then
         "the jobs that plan may skip should be checks, release-test and test, not: \(if $skipped == [] then "none" else $skipped | join(", ") end)"
       else empty end),

  # Each job with a matrix runs on both machines, and each native setup
  # checks the machine and installs the toolchain of the call.
    ($all[] | select(.value.strategy != null) | .key as $job
     | ([.value.strategy.matrix.include[]? | "\(.arch) on \(.machine)"] | sort | join(", ")) as $legs
     | (if ((.value.strategy.matrix // {}) | keys) != ["include"] or $legs != "amd64 on x86_64, arm64 on aarch64" then
          (if any($build[]; .key == $job) and $legs != "amd64 on x86_64, arm64 on aarch64" then empty
           else "job \($job) should run once for amd64 on x86_64 and once for arm64 on aarch64 (strategy.matrix.include alone), not for: \(if $legs == "" then "nothing" else $legs end)" end)
        else empty end),
       (if .value["runs-on"] != "${{ matrix.runner }}" then
          "job \($job) should run on the runner its matrix names (runs-on: ${{ matrix.runner }}), not on \(.value["runs-on"])"
        else empty end),
       (if any(.value.steps[]?; (.uses // "") == "./.github/actions/native-setup") | not then
          "job \($job) should check its runner with the native setup (machine: ${{ matrix.machine }})"
        else empty end)),
    ($all[] | .key as $job | .value.steps[]?
     | select((.uses // "") == "./.github/actions/native-setup")
     | select(.with != {"machine": "${{ matrix.machine }}", "toolchain": "${{ inputs.toolchain }}"})
     | "job \($job) should set up the machine of its matrix and the toolchain of the call (machine: ${{ matrix.machine }}, toolchain: ${{ inputs.toolchain }}), not \(.with | tojson)"),
    ($all[] | .key as $job | .value.steps[]? | select(runs("scripts/install-moonbit\\.sh"))
     | select(command != "scripts/install-moonbit.sh \"$TOOLCHAIN\"" or .env != {"TOOLCHAIN": "${{ inputs.toolchain }}"})
     | "job \($job) should install the toolchain of the call (scripts/install-moonbit.sh \"$TOOLCHAIN\" with TOOLCHAIN: ${{ inputs.toolchain }})"),

  # Each step runs whenever its job does, but for the few named above.
    ($all[] | .key as $job | .value.steps[]? | (.if | expression) as $if
     | select($if != null) | select(may_be_skipped($if) | not)
     | "the step \"\(step_name)\" of job \($job) should run whenever its job does, not if: \($if)"),

  # Nothing hides a failure, and nothing is kept here.
    ($all[] | continues | select(. != "job plan")
     | "\(.) should not continue on error: a failed check would pass"),
    hides_a_failure,
    (if has("concurrency") or any(.jobs[]; has("concurrency")) then
       "it should set no concurrency group: it would be shared with the calling workflow, and cancel its runs"
     else empty end),
    ($all[] | keeps_itself),
    ($all[] | select(any(.value.steps[]?; merges))
     | "job \(.key) should not keep the binaries: the calling workflow does, once its every job passed"),
    ($all[] | .key as $job | .value.steps[]? | select((.uses // "") | test("upload-artifact"))
     | select(merges | not) | select(((.with.name // "") | startswith("smock-linux-")) | not)
     | .with.name as $name
     | select((["release-linux-${{ matrix.arch }}", "protobuf-conformance"] | index($name)) == null)
     | "job \($job) should upload release-linux-${{ matrix.arch }} or protobuf-conformance, not \($name)"),
    ($all[] | .key as $job | .value.steps[]? | select(downloads)
     | select(.with != {"name": "release-linux-amd64", "path": "dist"})
     | "job \($job) should download this run'"'"'s release-linux-amd64 into dist, not \(.with | tojson)")')

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed "s|^|check-ci-artifacts: $workflow: |" >&2
  exit 1
fi

# What is wrong with the calling workflow, one line each.
problems=$(yq --output-format=json "$caller" | jq -r --arg workflow "$(basename "$workflow")" \
  --arg group "$group" "$common"'
  [.jobs | to_entries[]] as $all
  | [$all[] | select((.value.uses // "") | endswith("/" + $workflow))] as $calls
  | [$all[] | select(any(.value.steps[]?; merges))] as $keep

  # When it runs, and which runs it cancels.
  | (if .on != {"push": {"branches-ignore": ["dependabot/**"]}, "pull_request": null} then
       "it should run on a push to any branch but dependabot/** and on a pull request, not on: \(.on | tojson)"
     else empty end),
    (if .concurrency != {"group": $group, "cancel-in-progress": true} then
       "it should cancel an older run of the same branch or pull request, and never a run on main (concurrency group \($group), cancel-in-progress: true), not \(.concurrency | tojson)"
     else empty end),
    ($all[] | select(.value | has("concurrency"))
     | "job \(.key) should set no concurrency group: it could cancel a run on main"),

  # The call.
    (if ($calls | length) != 1 then
       "it should call \($workflow) once, not \($calls | length) times"
     else
       $calls[0]
       | (if .value.with.toolchain != "pinned" then
            "it should call \($workflow) with toolchain: pinned, with which the release binaries are handed over"
          else empty end),
         (if condition != null or needed != [] or .value.strategy != null then
            "job \(.key) calls \($workflow), so it should run in every run, once: no condition, no needs and no matrix"
          else empty end)
     end),

  # The job that keeps the binaries.
    (if ($keep | length) != 1 then
       "one job should keep the binaries (actions/upload-artifact/merge), not \($keep | length)"
     else
       $keep[0] as $job
       | ([$all[].key | select(. != $job.key)] | sort) as $others
       | (("amd64", "arm64") as $arch
          | [$job.value.steps[] | select(merges) | select(.with.name == "smock-linux-\($arch)")] as $steps
          | if ($steps | length) != 1 then
              "job \($job.key) should make smock-linux-\($arch) once, not \($steps | length) times"
            else
              $steps[0] as $step
              | (if $step.with.pattern != "release-linux-\($arch)" then
                   "job \($job.key) should make smock-linux-\($arch) of release-linux-\($arch), not of \($step.with.pattern)"
                 else empty end),
                ($step | days_problem("smock-linux-\($arch)")),
                (if $step.if != null then
                   "job \($job.key) should make smock-linux-\($arch) whenever it runs, not if: \($step.if)"
                 else empty end)
            end),
         ($others[] | select(. as $other | ($job | needed | index($other)) == null)
          | "job \($job.key) should need job \(.), so that it keeps nothing when that job fails"),
         ((["!cancelled()"] + [$others[] | "needs.\(.).result == '"'"'success'"'"'"] | sort) as $terms
          | (($job | condition) // "" | split(" && ") | sort) as $written
          | if $written != $terms then
              "job \($job.key) should run only when the run was not cancelled and every other job succeeded (if: ${{ \($terms | join(" && ")) }}), not \($job | condition | shown)"
            else empty end)
     end),

    ($keep[] | .key as $job | .value.steps[]
     | select((merges | not) or ((.with | keys) != ["delete-merged", "name", "pattern", "retention-days"]) or .with["delete-merged"] != true)
     | "job \($job) should only make smock-linux-<arch> of release-linux-<arch> and remove the latter (name, pattern, retention-days, delete-merged: true), not: \(step_name) \(.with // {} | tojson)"),

  # Every other job runs in every run, and each of its steps whenever the
  # job does.
    ($all[] | select(.key as $key | any($keep[], $calls[]; .key == $key) | not)
     | select(condition != null or needed != [] or .value.strategy != null)
     | "job \(.key) should run in every run, once: no condition, no needs and no matrix"),
    ($all[] | .key as $job | .value.steps[]? | (.if | expression) as $if
     | select($if != null and $if != "!cancelled()")
     | "the step \"\(step_name)\" of job \($job) should run whenever its job does (no condition, or !cancelled() to run after a failed step), not if: \($if)"),
    (("scripts/check-ci-artifacts.sh", "scripts/test-check-ci-artifacts.sh",
      "scripts/check-yaml-test-suite.sh", "scripts/test-yaml-test-suite-verdict.sh") as $command
     | ([$all[] | select(.key as $key | any($keep[]; .key == $key) | not) | .value.steps[]? | select(command == $command)] | length) as $times
     | if $times != 1 then "a job that the binaries wait for should run \($command) once, not \($times) times" else empty end),

  # Nothing hides a failure, and nothing else keeps a binary.
    ($all[] | continues | "\(.) should not continue on error: a failed check would pass"),
    hides_a_failure,
    ($all[] | keeps_itself)')

if [ -n "$problems" ]; then
  printf '%s\n' "$problems" | sed "s|^|check-ci-artifacts: $caller: |" >&2
  exit 1
fi
echo "check-ci-artifacts: $workflow hands over the release binary of amd64 and arm64 in every run," \
  "and $caller keeps them as smock-linux-<arch> only when every job passed"
