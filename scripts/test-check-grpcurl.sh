#!/bin/sh
# Tests of scripts/check-grpcurl.sh, which CI runs on every push: that it
# passes as committed, and fails, naming what differs, when the definition
# set has a problem, or a transcript, the guide's commands, the guide's
# output or the guide's Definition file differ from what grpcurl and the
# set give. Each test runs the check, as
# CI does, against the given smock binary, in a fresh copy of the files the
# check reads, after changing the copy, and checks its exit status and what
# it prints.
#
# It needs what the check needs: grpcurl 1.9.4 on PATH
# (scripts/install-grpcurl.sh installs it), curl and jq.
#
# usage: scripts/test-check-grpcurl.sh <smock>
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <smock>" >&2
  exit 2
fi
case $1 in
/*) smock=$1 ;;
*) smock=$PWD/$1 ;;
esac
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
copy=$tmp/repo

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

# fresh: makes $copy, a copy of the files the check reads.
fresh() {
  rm -rf "$copy"
  for path in scripts/check-grpcurl.sh scripts/install-grpcurl.sh scripts/grpcurl docs/grpc.md \
    docs/grpc fixtures/protobuf/health/grpc; do
    mkdir -p "$copy/$(dirname "$path")"
    cp -R "$path" "$copy/$path"
  done
}

# check <name>: runs the check in the copy, its output into
# $tmp/<name>.out and its exit status into $tmp/<name>.status.
check() {
  status=0
  "$copy/scripts/check-grpcurl.sh" "$smock" >"$tmp/$1.out" 2>&1 || status=$?
  echo "$status" >"$tmp/$1.status"
}

# expect <name> <status> <text>...: passes the test <name> when the check
# exited with <status> and printed each <text>, a fixed string, in a line.
expect() {
  name=$1
  want=$2
  shift 2
  got=$(cat "$tmp/$name.status")
  if [ "$got" != "$want" ]; then
    fail "$name: exit status $got, not $want"
    sed 's/^/    /' "$tmp/$name.out"
    return
  fi
  for text; do
    if ! grep -qF -- "$text" "$tmp/$name.out"; then
      fail "$name: it did not print: $text"
      sed 's/^/    /' "$tmp/$name.out"
      return
    fi
  done
  pass "$name"
}

example=scripts/grpcurl/calls/example.txt

# As committed, every call prints its transcript, on both ports.
fresh
check committed
expect committed 0 \
  "check-grpcurl: plain: $example: as committed" \
  "check-grpcurl: tls: $example: as committed" \
  "the guide's"

# A transcript that grpcurl does not print fails on both ports, with the
# difference and all that grpcurl printed.
fresh
sed -i 's/"Hello Tom"/"Hello Ann"/' "$copy/$example"
check transcript
expect transcript 1 \
  "check-grpcurl: plain: $example: grpcurl printed something else, for:" \
  "check-grpcurl: tls: $example: grpcurl printed something else, for:" \
  '-  "message": "Hello Ann"' \
  '+  "message": "Hello Tom"' \
  "check-grpcurl: what grpcurl printed:" \
  '      "message": "Hello Tom"'

# The exit status is part of the transcript.
fresh
sed -i 's/^exit status 69$/exit status 5/' "$copy/scripts/grpcurl/calls/example-ann.txt"
check exit-status
expect exit-status 1 \
  "check-grpcurl: plain: scripts/grpcurl/calls/example-ann.txt: grpcurl printed something else, for:" \
  "-exit status 5" \
  "+exit status 69"

# A transcript that is not written for the plain port is refused.
fresh
sed -i '1s/^\$ grpcurl -plaintext /$ grpcurl -insecure /' "$copy/$example"
check plain-port
expect plain-port 1 \
  "check-grpcurl: $example: its first line should be"

# A definition set with a problem is not served.
fresh
printf 'mocks:\n  - name: other-greeter\n    hosts: [greeter.svc]\n' >"$copy/scripts/grpcurl/definitions/twice.yaml"
check definitions
expect definitions 1 \
  'the Host "greeter.svc" is already claimed by the Mock "greeter"' \
  "check-grpcurl: smock check found problems or warnings in scripts/grpcurl/definitions"

# A grpcurl command in the guide that no transcript has, in one of the
# documents in docs/grpc/, which names the document and the command's line.
fresh
health=docs/grpc/services-and-connections.md
sed -i 's|^  localhost:8080 grpc.health.v1.Health/Check$|  localhost:8080 grpc.health.v1.Health/Watch|' "$copy/$health"
check guide-command
line=$(grep -n 'grpc.health.v1.Health/Watch$' "$copy/$health" | head -n 1 | cut -d: -f1)
expect guide-command 1 \
  "check-grpcurl: $health:$((line - 1)): the guide shows a grpcurl command that no transcript in scripts/grpcurl/calls has:" \
  "grpcurl -plaintext -authority greeter.svc -d '{\"service\": \"nope.Svc\"}' localhost:8080 grpc.health.v1.Health/Watch"

# Output in the guide that grpcurl does not print, after a command that
# goes over two lines.
fresh
sed -i '0,/^  "message": "Hello Tom"$/s//  "message": "Hello, Tom"/' "$copy/docs/grpc.md"
check guide-output
expect guide-output 1 \
  "the guide shows another output than $example gives:" \
  '-  "message": "Hello, Tom"' \
  '+  "message": "Hello Tom"'

# The guide's TLS form of a command is that of a transcript; another port
# is not.
fresh
sed -i 's|localhost:8443 helloworld.Greeter/SayHello$|localhost:8444 helloworld.Greeter/SayHello|' "$copy/docs/grpc.md"
check guide-tls
expect guide-tls 1 \
  "localhost:8444 helloworld.Greeter/SayHello"

# The guide's quick start shows the set's Definition file.
fresh
sed -i '0,/^      headers: { x-tenant: acme }  /s//      headers: { x-tenant: other }  /' "$copy/docs/grpc.md"
check guide-definitions
expect guide-definitions 1 \
  "check-grpcurl: the gRPC guide, docs/grpc.md and docs/grpc/*.md, does not show scripts/grpcurl/definitions/greeter.yaml, without its first comment lines, as a yaml block"

echo "test-check-grpcurl: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
