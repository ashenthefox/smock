#!/bin/sh
# Calls a smock binary with grpcurl 1.9.4, a real gRPC client, and checks
# what grpcurl prints against committed transcripts, as CI does on every
# push; then checks that the gRPC guide, its entry docs/grpc.md and the
# documents in docs/grpc/, shows only those calls, with what grpcurl
# prints. smock serves scripts/grpcurl/definitions, the example of the
# guide's quick start, on free ports, once `smock check` finds no problem
# and no warning in it. Before the calls, the guide's Ephemeral gRPC Stub
# for the Session test-a is added through the Admin API.
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
# In each document of the guide, read on its own, every grpcurl command of
# an `sh` block, its lines joined, must be a transcript's, as written or in
# its form for the TLS port (-insecure, localhost:8443). When the block ends
# with that command and a `json` or `text` block follows it, that block
# must be what grpcurl prints, without the exit status. A difference names
# the document and the command's line. And one `yaml` block of the guide's
# documents must be the set's Definition file, greeter.yaml, without its
# first comment lines.
#
# CI runs it on linux/amd64 and linux/arm64
# (.github/workflows/build-test.yml). It needs grpcurl 1.9.4 on PATH
# (scripts/install-grpcurl.sh installs it), curl and jq.
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

# The set loads without a problem or a warning.
if ! "$smock" check "$work/defs" >"$tmp/check.out" 2>&1 || [ -s "$tmp/check.out" ]; then
  sed 's/^/    /' "$tmp/check.out" >&2
  echo "check-grpcurl: smock check found problems or warnings in scripts/grpcurl/definitions" >&2
  exit 1
fi

# smock, on free ports, with the Admin API token of the guide's examples.
# Without certificate files, the TLS port presents a self-signed
# certificate.
(cd "$work" && SMOCK_ADMIN_TOKEN=change-me exec "$smock" serve --dir defs \
  --port 0 --tls-port 0 --admin-port 0) 2>"$tmp/smock.log" &
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
admin=""
tries=0
while [ -z "$plain" ] || [ -z "$tls" ] || [ -z "$admin" ]; do
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
  admin=$(port admin)
done

# The Ephemeral gRPC Stub of the guide's example, which makes the calls of
# the Session test-a fail with UNAVAILABLE (docs/grpc.md, "Ephemeral gRPC
# Stubs").
if ! curl -sS --fail-with-body -o "$tmp/stub.json" -H "Authorization: Bearer change-me" \
  -H "baggage: smock-session=test-a" \
  -d '{"request": {"path": "/helloworld.Greeter/SayHello"}, "response": {"grpc": {"status": "UNAVAILABLE", "message": "try again"}}}' \
  "localhost:$admin/v1/mocks/greeter/stubs" 2>"$tmp/curl.err"; then
  cat "$tmp/curl.err" "$tmp/stub.json" 2>/dev/null | sed 's/^/    /' >&2
  echo "check-grpcurl: the Admin API did not add the guide's Ephemeral gRPC Stub" >&2
  exit 1
fi

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

# tls_form <command>: the command for the TLS port, as the guide writes it.
tls_form() {
  printf '%s\n' "$1" | sed -e 's|^grpcurl -plaintext |grpcurl -insecure |' -e 's|localhost:8080|localhost:8443|g'
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
      on_port=$(tls_form "$command" | sed "s|localhost:8443|localhost:$tls|g")
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

# read_document <document>: reads one document of the guide into
# $tmp/guide, which it empties first. For the document's n-th grpcurl
# command, $tmp/guide/<n>.line holds its line, <n>.command the command with
# its lines joined and its blanks squeezed, and <n>.output the block that
# shows what it prints, if any. $tmp/guide/yaml-<m> holds the document's
# m-th yaml block. A fence may be indented, as in a list item; its lines
# lose that indent. The awk program keeps its state and its line numbers
# for one file, so each document is read on its own.
read_document() {
  rm -rf "$tmp/guide"
  mkdir "$tmp/guide"
  awk -v dir="$tmp/guide" '
  # file(i, kind): the file of kind <kind> of the i-th command, numbered
  # so that the files sort in the order of the document.
  function file(i, kind) {
    return dir "/" sprintf("%04d", i) "." kind
  }
  # unindented(s): s without the indent of its block'"'"'s fence.
  function unindented(s) {
    if (indent != "" && index(s, indent) == 1) s = substr(s, length(indent) + 1)
    return s
  }
  # squeeze(s): s with each run of blanks made one space, and none at
  # either end.
  function squeeze(s) {
    gsub(/[ \t]+/, " ", s)
    sub(/^ /, "", s)
    sub(/ $/, "", s)
    return s
  }
  # In an sh block: a command, which may go on over lines ending in "\".
  block == "sh" && $0 !~ /^[ \t]*```[ \t]*$/ {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (joined == "") start = NR
    joined = joined " " line
    if (joined ~ /\\$/) {
      sub(/\\$/, "", joined)
      next
    }
    command = squeeze(joined)
    joined = ""
    if (command ~ /^grpcurl /) {
      n++
      print start > file(n, "line")
      close(file(n, "line"))
      print command > file(n, "command")
      close(file(n, "command"))
      last = n
    } else if (command != "" && command !~ /^#/) {
      last = 0
    }
    next
  }
  block == "sh" {
    block = ""
    shown = last
    next
  }
  # In the block that shows what the last command printed.
  block == "output" && $0 !~ /^[ \t]*```[ \t]*$/ {
    line = unindented($0)
    print line > file(shown, "output")
    next
  }
  block == "output" {
    close(file(shown, "output"))
    block = ""
    shown = 0
    next
  }
  # In a yaml block, which may show the definition set.
  block == "yaml" && $0 !~ /^[ \t]*```[ \t]*$/ {
    line = unindented($0)
    print line > (dir "/yaml-" yamls)
    next
  }
  block == "yaml" {
    close(dir "/yaml-" yamls)
    block = ""
    next
  }
  block == "other" {
    if ($0 ~ /^[ \t]*```[ \t]*$/) block = ""
    next
  }
  /^[ \t]*```/ {
    indent = $0
    sub(/[^ \t].*/, "", indent)
    if ($0 ~ /^[ \t]*```sh[ \t]*$/) {
      block = "sh"
      last = 0
    } else if (shown > 0 && $0 ~ /^[ \t]*```(json|text)[ \t]*$/) {
      block = "output"
      printf "" > file(shown, "output")
    } else if ($0 ~ /^[ \t]*```yaml[ \t]*$/) {
      block = "yaml"
      yamls++
      printf "" > (dir "/yaml-" yamls)
    } else {
      block = "other"
    }
    shown = block == "output" ? shown : 0
    next
  }
  /[^ \t]/ { shown = 0 }
' "$1"
}

# The Definition file of the set, without its first comment lines, as the
# guide shows it.
definitions=scripts/grpcurl/definitions/greeter.yaml
awk 'body || !/^#/ { body = 1; print }' "$definitions" >"$tmp/definitions"

# Each document of the guide: the entry, then those in docs/grpc/. A glob
# that matches no file names no document, and fails the run.
shown=0
found=""
for document in docs/grpc.md docs/grpc/*.md; do
  if [ ! -f "$document" ]; then
    failed=1
    echo "check-grpcurl: $document: no such document of the gRPC guide" >&2
    continue
  fi
  read_document "$document"
  for record in "$tmp"/guide/*.command; do
    [ -f "$record" ] || continue
    shown=$((shown + 1))
    n=${record%.command}
    command=$(cat "$record")
    line=$(cat "$n.line")
    match=""
    for file in scripts/grpcurl/calls/*.txt; do
      written=$(head -n 1 "$file")
      written=${written#\$ }
      if [ "$command" = "$written" ] || [ "$command" = "$(tls_form "$written")" ]; then
        match=$file
        break
      fi
    done
    if [ -z "$match" ]; then
      failed=1
      echo "check-grpcurl: $document:$line: the guide shows a grpcurl command that no transcript in scripts/grpcurl/calls has:" >&2
      echo "    $command" >&2
      continue
    fi
    if [ -f "$n.output" ]; then
      sed -e '1d' -e '${/^exit status [0-9]*$/d;}' "$match" >"$tmp/printed"
      if ! cmp -s "$n.output" "$tmp/printed"; then
        failed=1
        echo "check-grpcurl: $document:$line: the guide shows another output than $match gives:" >&2
        diff -u --label "$document" --label "$match" "$n.output" "$tmp/printed" | sed 's/^/    /' >&2 || true
      fi
    fi
  done
  # The Definition file is one of the document's yaml blocks, or of
  # another's.
  if [ -z "$found" ]; then
    for yaml in "$tmp"/guide/yaml-*; do
      if [ -f "$yaml" ] && cmp -s "$yaml" "$tmp/definitions"; then
        found=$document
        break
      fi
    done
  fi
done
if [ -z "$found" ]; then
  failed=1
  echo "check-grpcurl: the gRPC guide, docs/grpc.md and docs/grpc/*.md, does not show $definitions, without its first comment lines, as a yaml block" >&2
fi

if [ "$failed" -ne 0 ]; then
  echo "check-grpcurl: grpcurl, or the guide, did not show what the transcripts give" >&2
  exit 1
fi
echo "check-grpcurl: grpcurl printed what each of the $calls transcripts gives, on the plain port and the TLS port;" \
  "the guide's $shown grpcurl commands are among them, and $found shows $definitions"
