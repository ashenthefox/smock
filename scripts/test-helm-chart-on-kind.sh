#!/bin/sh
# Installs the Helm chart (charts/smock) on a kind cluster and checks it
# there. CI runs it with the image it has just built. It:
#
# 1. creates a kind cluster and loads the image into it;
# 2. makes a namespace that enforces the Restricted Pod Security Standard
#    and also warns about it, and checks, with a server-side dry run that
#    fails on any warning, that Kubernetes' own Pod Security admission
#    accepts the Pods of every delivery mode (ConfigMap, git-sync and OCI
#    image), with each Admin API authentication and TLS option;
# 3. installs the chart with a ConfigMap of Definition files and an Admin API
#    token Secret, and waits until the Pod is ready;
# 4. checks that a request to a Stub gets its response;
# 5. updates the Definition files with `helm upgrade`, which changes only
#    the ConfigMap, and checks that the Pod serves the new definition set
#    without a restart: the definition set digest in the Admin API status
#    becomes the digest of the new files, the Stub answers with the new
#    response, and the Pod is the same one, with a restart count of 0.
#
# It deletes the cluster when it ends, also when a HUP, INT or TERM signal
# ends it. It needs docker, kind, kubectl, helm, curl, jq and python3.
#
# Creating the cluster needs no image and takes about half a minute, most of
# it waiting for the control plane. So CI starts it in an earlier step, before
# it builds the release binary and the image, and runs the rest once the
# image is built:
#
# - --start creates the state directory if needed, starts creating the
#   cluster in the background and returns at once. The background process
#   leads a session of its own (setsid, from util-linux) and holds none of
#   the caller's file descriptors, so the step that runs --start ends at
#   once and the process outlives it. It writes into the state directory:
#   cluster (the cluster's name), kubeconfig (the cluster's credentials),
#   started (when creation started, in seconds since the epoch), pid (the
#   background process's pid and its start time, see start_time below; its
#   process group holds kind and its children), create.log (what kind
#   printed) and, once creation has ended, status (kind's exit status). It
#   refuses a state directory that already holds any of these files.
# - --cluster waits until that creation has ended, for at most 5 minutes
#   after --start, and prints create.log. It fails when creation failed or
#   did not end in time. Otherwise it goes on as the first form does, from
#   loading the image. It deletes the cluster when it ends, and leaves the
#   state directory to the caller.
#
# usage: scripts/test-helm-chart-on-kind.sh <image>
#        scripts/test-helm-chart-on-kind.sh --start <state directory>
#        scripts/test-helm-chart-on-kind.sh --cluster <state directory> <image>
# example: scripts/test-helm-chart-on-kind.sh smock:ci
set -eu

say() {
  echo "test-helm-chart-on-kind: $*"
}
# die <message>: fails before there is anything on the cluster to show.
die() {
  echo "test-helm-chart-on-kind: $*" >&2
  exit 1
}
usage() {
  echo "usage: $0 <image>" >&2
  echo "       $0 --start <state directory>" >&2
  echo "       $0 --cluster <state directory> <image>" >&2
  exit 2
}

# The state directory is resolved before the cd below, since the caller
# names it relative to its own working directory.
mode=all
case ${1-} in
--start)
  [ "$#" -eq 2 ] || usage
  mode=start
  mkdir -p "$2"
  state=$(cd "$2" && pwd)
  ;;
--create)
  # What --start runs in the background, with an absolute state directory.
  [ "$#" -eq 2 ] || usage
  mode=create
  state=$2
  ;;
--cluster)
  [ "$#" -eq 3 ] || usage
  mode=cluster
  [ -f "$2/cluster" ] || die "$2 holds no cluster that --start started"
  state=$(cd "$2" && pwd)
  image=$3
  ;;
-*) usage ;;
*)
  [ "$#" -eq 1 ] || usage
  image=$1
  ;;
esac
cd "$(dirname "$0")/.."

# The node image kind v0.33.0 was released with, by digest as kind asks.
node_image=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
# How long --cluster lets creation run, counted from --start: the node
# image's download, the node's start and kind's own wait of up to 120 s for
# the control plane fit in it.
create_timeout=300
namespace=mocks
release=smock

# create_cluster <name>: creates the cluster, with its credentials in
# $KUBECONFIG.
create_cluster() {
  kind create cluster --name "$1" --image "$node_image" --wait 120s
}

# start_time <pid>: when the process <pid> started, in clock ticks since
# boot (field 22 of /proc/<pid>/stat), or nothing when no process has that
# pid or there is no /proc. A pid and its start time name one process: a
# process that gets the pid after it is freed has a later start time.
start_time() {
  sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d ' ' -f 20
}

if [ "$mode" = start ]; then
  command -v setsid >/dev/null || die "--start needs setsid (util-linux)"
  # A file of an earlier start would pass for one of this start's.
  for file in cluster started pid pid.new create.log kubeconfig status status.new; do
    [ ! -e "$state/$file" ] ||
      die "$state already holds the state of a cluster ($file); give --start a new directory"
  done
  echo "smock-chart-$$" >"$state/cluster"
  date +%s >"$state/started"
  setsid sh "$PWD/scripts/${0##*/}" --create "$state" \
    </dev/null >"$state/create.log" 2>&1 &
  # The background process writes its pid first; waiting for it shows here
  # that it started.
  for _ in $(seq 50); do
    if [ -s "$state/pid" ]; then
      say "creating cluster $(cat "$state/cluster") in the background, logging to $state/create.log"
      exit 0
    fi
    sleep 0.1
  done
  cat "$state/create.log" >&2
  die "the background creation of the cluster did not start"
fi

if [ "$mode" = create ]; then
  # A new file is renamed into place, so a reader never sees it half written.
  echo "$$ $(start_time "$$")" >"$state/pid.new"
  mv "$state/pid.new" "$state/pid"
  export KUBECONFIG="$state/kubeconfig"
  status=0
  create_cluster "$(cat "$state/cluster")" || status=$?
  say "kind create cluster ended with exit status $status after $(($(date +%s) - $(cat "$state/started"))) s"
  echo "$status" >"$state/status.new"
  mv "$state/status.new" "$state/status"
  exit "$status"
fi

repository=${image%:*}
tag=${image##*:}

tmp=$(mktemp -d)
if [ "$mode" = cluster ]; then
  cluster=$(cat "$state/cluster")
  export KUBECONFIG="$state/kubeconfig"
else
  cluster=smock-chart-$$
  # The cluster's credentials stay here, out of the user's kubeconfig.
  export KUBECONFIG="$tmp/kubeconfig"
fi

# creating: whether the creation that --start started still runs; it sets
# leader to the pid of the creation's process. That process leads a process
# group, which kind and its children share, so the group outlives a
# background shell that was killed while kind runs on. A process that has
# the leader's pid but another start time is not the leader: the creation
# ended without a status and its pid went to an unrelated process, whose
# group is neither waited for nor signalled. A live group whose leader has
# gone is still the creation's, since no new process gets the id of a
# process group that still has members (POSIX).
creating() {
  [ ! -e "$state/status" ] && [ -s "$state/pid" ] || return 1
  read -r leader leader_started <"$state/pid"
  kill -0 "-$leader" 2>/dev/null || return 1
  leader_now=$(start_time "$leader")
  [ -z "$leader_now" ] || [ "$leader_now" = "$leader_started" ]
}
# stop_creation: stops a creation that still runs, so that it does not go on
# making the cluster while cleanup deletes it. It signals the group only
# while creating says that it is the creation's.
stop_creation() {
  creating || return 0
  kill -TERM "-$leader" 2>/dev/null || true
  for _ in $(seq 50); do
    creating || return 0
    sleep 0.2
  done
  kill -KILL "-$leader" 2>/dev/null || true
}

pids=
cleanup() {
  # A second signal, such as the TERM that follows the INT when a CI step is
  # cancelled, would cut the cleanup short and leave the cluster: the
  # cleanup ignores HUP, INT and TERM, and so do the commands it runs.
  trap '' HUP INT TERM
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  if [ "$mode" = cluster ]; then
    stop_creation
  fi
  kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
# dash runs the EXIT trap when the script exits but not when a signal kills
# it, so these signals end the script through exit, with the status a shell
# reports for each (128 + the signal's number).
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "test-helm-chart-on-kind: $*" >&2
  echo "test-helm-chart-on-kind: the Pods and their logs:" >&2
  kubectl --namespace "$namespace" get pods -o wide >&2 || true
  kubectl --namespace "$namespace" describe pods >&2 || true
  kubectl --namespace "$namespace" logs --all-containers --prefix \
    --selector app.kubernetes.io/name=smock >&2 || true
  exit 1
}

if [ "$mode" = cluster ]; then
  [ -s "$state/pid" ] || die "the creation of cluster $cluster did not start: see what --start printed"
  started=$(cat "$state/started")
  waiting=$(date +%s)
  say "waiting for the creation of cluster $cluster, at most $create_timeout s after it started"
  while creating && [ "$(($(date +%s) - started))" -lt "$create_timeout" ]; do
    sleep 0.5
  done
  waited=$(($(date +%s) - waiting))
  echo "test-helm-chart-on-kind: what kind printed while it created cluster $cluster:" >&2
  cat "$state/create.log" >&2
  if [ ! -e "$state/status" ]; then
    if creating; then
      die "the creation of cluster $cluster did not end within $create_timeout s"
    fi
    die "the creation of cluster $cluster stopped without an exit status"
  fi
  status=$(cat "$state/status")
  [ "$status" = 0 ] || die "the creation of cluster $cluster failed with exit status $status"
  say "created cluster $cluster; waited $waited s for it here"
else
  create_cluster "$cluster"
fi
kind load docker-image "$image" --name "$cluster"

kubectl create namespace "$namespace"
kubectl label namespace "$namespace" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest
kubectl --namespace "$namespace" create secret generic smock-admin-token \
  --from-literal=token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
kubectl --namespace "$namespace" get secret smock-admin-token -o jsonpath='{.data.token}' |
  base64 -d >"$tmp/token"
printf 'Authorization: Bearer %s\n' "$(cat "$tmp/token")" >"$tmp/admin-header"

# Kubernetes' own Pod Security admission, on every delivery mode. On a
# Deployment it only warns, which --warnings-as-errors makes fatal. First,
# the check itself: it refuses a Pod without a security context.
cat >"$tmp/broken.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken
spec:
  selector:
    matchLabels: { app: broken }
  template:
    metadata:
      labels: { app: broken }
    spec:
      containers:
        - name: broken
          image: $image
YAML
if kubectl --namespace "$namespace" apply --dry-run=server --warnings-as-errors \
  -f "$tmp/broken.yaml" >"$tmp/broken.log" 2>&1; then
  fail "the dry run accepts a Pod that breaks the Restricted standard, so it checks nothing"
fi
grep -q 'violate PodSecurity "restricted' "$tmp/broken.log" ||
  fail "the dry run refused a Pod for another reason than the Restricted standard: $(cat "$tmp/broken.log")"
token="--set adminAuth.tokenSecret.name=smock-admin-token"
for variant in \
  "configmap|$token" \
  "configmap-env-tls|$token --set adminAuth.tokenAs=env --set tls.secretName=smock-tls --set tls.mockSecrets.users=users-tls" \
  "configmap-auth-off|--set adminAuth.enabled=false" \
  "git-sync|$token --set definitions.source=gitSync --set definitions.gitSync.repo=https://example.com/mocks.git --set tls.secretName=smock-tls" \
  "image|$token --set definitions.source=image --set definitions.image.reference=ghcr.io/hirunefu/mocks:v1 --set tls.secretName=smock-tls"; do
  name=${variant%%|*}
  flags=${variant#*|}
  # shellcheck disable=SC2086 # $flags is a list of flags
  helm template "$release" charts/smock --namespace "$namespace" $flags >"$tmp/$name.yaml"
  if ! kubectl --namespace "$namespace" apply --dry-run=server --warnings-as-errors \
    -f "$tmp/$name.yaml" >"$tmp/$name.log" 2>&1; then
    cat "$tmp/$name.log" >&2
    fail "Pod Security admission does not accept the $name Pods under the Restricted standard"
  fi
  say "Pod Security admission accepts the $name Pods under the Restricted standard"
done

# definitions <response body>: a Definition file with one Stub, GET /hello.
definitions() {
  printf '{"mocks":[{"name":"hello"}],"stubs":[{"id":"hello","mock":"hello","request":{"method":"GET","path":"/hello"},"response":{"status":200,"body":"%s"}}]}' "$1"
}
definitions "hello v1" >"$tmp/v1.json"
definitions "hello v2" >"$tmp/v2.json"

helm install "$release" charts/smock --namespace "$namespace" \
  --set image.repository="$repository" --set image.tag="$tag" --set image.pullPolicy=Never \
  --set adminAuth.tokenSecret.name=smock-admin-token \
  --set-file 'definitions.configMap.files.hello\.json='"$tmp/v1.json" \
  --wait --timeout 5m || fail "the chart did not install"
kubectl --namespace "$namespace" rollout status deployment/"$release" --timeout 2m ||
  fail "the Pod did not become ready"
say "installed into a namespace that enforces the Restricted standard, and the Pod is ready"

# forward <service> <port>: forwards a free local port to the Service's
# port, and sets local_port to it. It runs in this shell rather than in a
# command substitution, which would lose what it adds to pids, so that
# cleanup stops the port-forward.
forward() {
  kubectl --namespace "$namespace" port-forward "service/$1" ":$2" >"$tmp/forward-$1" 2>&1 &
  pids="$pids $!"
  for _ in $(seq 50); do
    local_port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) .*/\1/p' "$tmp/forward-$1")
    if [ -n "$local_port" ]; then
      return
    fi
    sleep 0.2
  done
  cat "$tmp/forward-$1" >&2
  fail "could not forward a port to service/$1"
}
forward "$release" 80
plain_port=$local_port
forward "$release-admin" 9090
admin_port=$local_port

hello() {
  curl --silent --show-error --fail --max-time 5 "http://127.0.0.1:$plain_port/hello"
}
status() {
  curl --silent --show-error --fail --max-time 5 --header "@$tmp/admin-header" \
    "http://127.0.0.1:$admin_port/v1/status"
}

body=$(hello) || fail "no answer from the Stub"
[ "$body" = "hello v1" ] || fail "the Stub answered \"$body\", not \"hello v1\""
say "a request to a Stub gets its response"

pod=$(kubectl --namespace "$namespace" get pods --selector app.kubernetes.io/name=smock \
  -o jsonpath='{.items[0].metadata.name}')
uid=$(kubectl --namespace "$namespace" get pod "$pod" -o jsonpath='{.metadata.uid}')
generation=$(kubectl --namespace "$namespace" get deployment "$release" -o jsonpath='{.metadata.generation}')
before=$(status | jq -r .digest) || fail "no answer from the Admin API status operation"

# The digest smock reports for a definition set of one Definition file, as
# docs/definition-files.md defines it.
expected=$(python3 -c '
import hashlib, sys
name = sys.argv[1].encode()
content = open(sys.argv[2], "rb").read()
frame = b"D" + len(name).to_bytes(8, "big") + name + len(content).to_bytes(8, "big") + content
print(hashlib.sha256(frame).hexdigest()[:12])' hello.json "$tmp/v2.json")
[ "$before" != "$expected" ] || fail "the digests of the old and the new files are the same"

helm upgrade "$release" charts/smock --namespace "$namespace" --reuse-values \
  --set-file 'definitions.configMap.files.hello\.json='"$tmp/v2.json" ||
  fail "helm upgrade with new Definition files failed"
[ "$(kubectl --namespace "$namespace" get deployment "$release" -o jsonpath='{.metadata.generation}')" = "$generation" ] ||
  fail "new Definition files changed the Deployment, which rolls out new Pods"

# The kubelet refreshes ConfigMap volumes periodically: allow it 3 minutes.
digest=$before
for _ in $(seq 90); do
  digest=$(status | jq -r .digest) || fail "no answer from the Admin API status operation"
  [ "$digest" = "$before" ] || break
  sleep 2
done
[ "$digest" = "$expected" ] ||
  fail "after the ConfigMap update the replica serves the digest $digest, not $expected of the new files"
[ "$(status | jq -r .lastReload.result)" = swapped ] || fail "the last reload did not swap the new files in"
body=$(hello) || fail "no answer from the Stub after the update"
[ "$body" = "hello v2" ] || fail "after the update the Stub answered \"$body\", not \"hello v2\""

[ "$(kubectl --namespace "$namespace" get pods --selector app.kubernetes.io/name=smock \
  -o jsonpath='{.items[*].metadata.uid}')" = "$uid" ] || fail "the Pod was replaced"
restarts=$(kubectl --namespace "$namespace" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
[ "$restarts" = 0 ] || fail "smock restarted $restarts times"
say "after a ConfigMap update the same Pod serves the new definition set ($before -> $digest) with 0 restarts"

say "passed"
