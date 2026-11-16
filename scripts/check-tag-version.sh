#!/bin/sh
# Checks that a version tag names the version in moon.mod, as
# docs/releasing.md asks: "The tag names the version. Keep the version in
# moon.mod the same." The release workflow (.github/workflows/release.yml)
# checks each pushed tag with it.
#
# <version> is the tag without its v: <major>.<minor>.<patch>, or
# <major>.<minor>.<patch>-<pre-release> for a pre-release, as SemVer 2.0
# (https://semver.org/spec/v2.0.0.html) defines them. Each of the three
# numbers is 0 or has no leading zero. The pre-release is one or more
# identifiers separated by dots, none of them empty: an identifier of
# digits only is a number, which is 0 or has no leading zero, and any other
# holds letters, digits and hyphens. helm refuses a chart version whose
# pre-release breaks these rules (0.4.0-rc..1, 0.4.0-01), and the release
# workflow packages the chart only after it has pushed the images, so this
# check refuses such a version before anything is built. It also refuses
# build metadata (+<build>), which an image tag cannot hold.
#
# A pre-release leads up to its version, so moon.mod already names that:
# v0.4.0-rc.1 was tagged with version = "0.4.0" in moon.mod. The check
# therefore compares the version without its pre-release with the
# top-level version = "..." line of moon.mod.
#
# It exits 0 when they are the same, and 1, naming both, when they are not,
# when <version> is not such a version, or when moon.mod gives no version;
# 2 for wrong arguments.
#
# usage: scripts/check-tag-version.sh <version> [<moon.mod file>]
# example: scripts/check-tag-version.sh 0.4.0-rc.1
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <version> [<moon.mod file>]" >&2
  exit 2
fi
version=$1
if [ "$#" -eq 2 ]; then
  mod=$2
else
  cd "$(dirname "$0")/.."
  mod=moon.mod
fi

# SemVer's grammar: a number, and a pre-release identifier, which is a
# number or holds at least one letter or hyphen. grep matches each line on
# its own, so the case first refuses a newline, with every other character
# that no version holds.
number='(0|[1-9][0-9]*)'
identifier="($number|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
case $version in
*[!0-9A-Za-z.-]*) valid=false ;;
*) valid=true ;;
esac
if [ "$valid" = false ] ||
  ! printf '%s\n' "$version" | grep -Eqx "$number\\.$number\\.$number(-$identifier(\\.$identifier)*)?"; then
  echo "check-tag-version: '$version' is not a SemVer 2.0 version <major>.<minor>.<patch>[-<pre-release>]" >&2
  exit 1
fi
release=${version%%-*}

if [ ! -f "$mod" ]; then
  echo "check-tag-version: $mod does not exist" >&2
  exit 1
fi
# The module's own version is a top-level line, which is not indented.
found=$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$mod")
case $found in
'')
  echo "check-tag-version: $mod has no line version = \"...\"" >&2
  exit 1
  ;;
*'
'*)
  echo "check-tag-version: $mod has more than one line version = \"...\"" >&2
  exit 1
  ;;
esac

tagged=$version
[ "$release" = "$version" ] || tagged="$version, a pre-release of $release,"
if [ "$release" != "$found" ]; then
  echo "check-tag-version: the tag names $tagged but $mod names $found" >&2
  exit 1
fi
echo "check-tag-version: the tag names $tagged and $mod names $found"
