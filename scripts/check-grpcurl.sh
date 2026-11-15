#!/bin/sh
# Calls a smock binary with grpcurl 1.9.4, a real gRPC client, and checks
# what grpcurl prints against committed transcripts, as CI does on every
# push. smock serves scripts/grpcurl/definitions, the example of the gRPC
# guide's quick start, on free ports.
#
# Each file scripts/grpcurl/calls/<name>.txt is one call's transcript: a
# first line `$ grpcurl ...`, the command as the guide writes it for the
# plain port (-plaintext, localhost:8080), then what grpcurl prints, its
# standard output and then its standard error, and last, when grpcurl
# exits with another status than 0, `exit status <n>`. Output that does not
# end with a newline gets one. Each command runs twice, from a directory
# where defs/ is the definition set and grpc/health/v1/health.proto is
# gRPC's health.proto (fixtures/protobuf/health):
#
# - plain: on the plain port, as written, over h2c;
# - tls: on the TLS port, with -insecure in place of -plaintext, over h2
#   with the self-signed certificate smock generates, which grpcurl does
#   not verify.
#
# Both must print what the transcript gives. A difference fails the run,
# which shows the difference and everything grpcurl printed.
#
# CI runs it on linux/amd64 and linux/arm64
# (.github/workflows/build-test.yml). It needs grpcurl 1.9.4 on PATH
# (scripts/install-grpcurl.sh installs it) and jq.
#
# usage: scripts/check-grpcurl.sh <smock>
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
repo=$PWD

grpcurl_version=$(sed -n 's/^version=//p' scripts/install-grpcurl.sh)
version=$(grpcurl -version 2>&1 || true)
if [ "$version" != "grpcurl v$grpcurl_version" ]; then
  echo "check-grpcurl: needs grpcurl $grpcurl_version on PATH, which scripts/install-grpcurl.sh installs; found: ${version:-none}" >&2
  exit 1
fi

tmp=$(mktemp -d)
pid=""
trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# smock_log: prints what smock logged.
smock_log() {
  echo "check-grpcurl: smock logged:" >&2
  sed 's/^/    /' "$tmp/smock.log" >&2
}

# The directory grpcurl runs in, where the guide's relative paths lead.
work=$tmp/work
mkdir -p "$work/grpc/health"
ln -s "$repo/scripts/grpcurl/definitions" "$work/defs"
ln -s "$repo/fixtures/protobuf/health/grpc/health/v1" "$work/grpc/health/v1"

# smock, on free ports. Without certificate files, the TLS port presents a
# self-signed certificate.
(cd "$work" && exec "$smock" serve --dir defs --port 0 --tls-port 0 --admin-port 0 \
  --admin-auth off) 2>"$tmp/smock.log" &
pid=$!

# port <listener>: the port number of the listener, from smock's listening
# entry, or nothing yet. A line still being written is not JSON yet, and is
# skipped.
port() {
  jq -rR --arg listener "$1" \
    'fromjson? | select(.msg == "listening" and .listener == $listener) | .address | sub(".*:"; "")' \
    "$tmp/smock.log"
}
plain=""
tls=""
tries=0
while [ -z "$plain" ] || [ -z "$tls" ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    smock_log
    echo "check-grpcurl: smock stopped before it listened" >&2
    exit 1
  fi
  tries=$((tries + 1))
  if [ "$tries" -gt 100 ]; then
    smock_log
    echo "check-grpcurl: smock did not listen within 10 seconds" >&2
    exit 1
  fi
  sleep 0.1
  plain=$(port plain)
  tls=$(port tls)
done

# run <command> <file>: runs the command in $work, and writes its
# transcript, which starts with <file>'s first line, into $tmp/actual.
run() {
  status=0
  (cd "$work" && eval "$1") >"$tmp/stdout" 2>"$tmp/stderr" || status=$?
  cat "$tmp/stdout" "$tmp/stderr" >"$tmp/output"
  {
    head -n 1 "$2"
    cat "$tmp/output"
    # -format-error prints no newline after the status.
    [ ! -s "$tmp/output" ] || [ -z "$(tail -c 1 "$tmp/output")" ] || echo
    [ "$status" -eq 0 ] || echo "exit status $status"
  } >"$tmp/actual"
}

failed=0
calls=0
for file in scripts/grpcurl/calls/*.txt; do
  calls=$((calls + 1))
  command=$(head -n 1 "$file")
  case $command in
  '$ grpcurl -plaintext '*localhost:8080*) command=${command#\$ } ;;
  *)
    echo "check-grpcurl: $file: its first line should be \`\$ grpcurl -plaintext ...\`, a command for localhost:8080" >&2
    failed=1
    continue
    ;;
  esac
  for listener in plain tls; do
    if [ "$listener" = plain ]; then
      on_port=$(printf '%s\n' "$command" | sed "s|localhost:8080|localhost:$plain|g")
    else
      on_port=$(printf '%s\n' "$command" | sed -e "s|localhost:8080|localhost:$tls|g" -e 's|^grpcurl -plaintext |grpcurl -insecure |')
    fi
    run "$on_port" "$file"
    if cmp -s "$file" "$tmp/actual"; then
      echo "check-grpcurl: $listener: $file: as committed"
    else
      failed=1
      echo "check-grpcurl: $listener: $file: grpcurl printed something else, for:" >&2
      echo "    $on_port" >&2
      diff -u --label "$file" --label "what grpcurl printed" "$file" "$tmp/actual" | sed 's/^/    /' >&2 || true
      echo "check-grpcurl: what grpcurl printed:" >&2
      sed 's/^/    /' "$tmp/actual" >&2
    fi
  done
done

if ! kill -0 "$pid" 2>/dev/null; then
  smock_log
  echo "check-grpcurl: smock stopped during the calls" >&2
  exit 1
fi
kill -TERM "$pid"
status=0
wait "$pid" || status=$?
pid=""
if [ "$status" -ne 0 ]; then
  smock_log
  echo "check-grpcurl: smock exited with $status after SIGTERM, not 0" >&2
  exit 1
fi

if [ "$failed" -ne 0 ]; then
  echo "check-grpcurl: grpcurl did not print what the transcripts give" >&2
  exit 1
fi
echo "check-grpcurl: grpcurl printed what each of the $calls transcripts gives, on the plain port and the TLS port"
