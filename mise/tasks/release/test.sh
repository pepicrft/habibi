#!/usr/bin/env bash
#MISE description="Test release versioning against disposable Git histories"
set -euo pipefail

SOURCE=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/habibi-release.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
unset GITHUB_OUTPUT
git init -q -b main "$FIXTURE"
git -C "$FIXTURE" config user.name "Habibi release tests"
git -C "$FIXTURE" config user.email "release-tests@example.invalid"
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" config core.hooksPath /dev/null
mkdir -p "$FIXTURE/mise/tasks/release" "$FIXTURE/server/marketing" "$FIXTURE/client" "$FIXTURE/deploy"
cp "$SOURCE/cliff.toml" "$FIXTURE/cliff.toml"
cp "$SOURCE/mise/tasks/release/check.sh" "$FIXTURE/mise/tasks/release/check.sh"
CHECK="$FIXTURE/mise/tasks/release/check.sh"

if bash "$CHECK" > /dev/null 2>&1; then echo "Unborn HEAD was accepted" >&2; exit 1; fi
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm 'feat(server): introduce the server and marketing site'

expect() {
  local output
  output=$(bash "$CHECK")
  grep -qx "should-release=$1" <<< "$output"
  grep -qx "next-version-number=$2" <<< "$output"
}

change() {
  printf '%s\n' "$2" >> "$FIXTURE/$1"
  git -C "$FIXTURE" add .
  git -C "$FIXTURE" commit -qm "$2"
}

expect true 0.1.0
bash "$CHECK" notes | grep -q 'introduce the server and marketing site'
git -C "$FIXTURE" tag server@0.1.0
expect false 0.1.0
change client/reference.txt 'feat(client): unrelated reference client change'
expect false 0.1.0
change server/config.txt 'chore(server): internal maintenance'
expect false 0.1.0
change server/marketing/copy.txt 'fix(site): correct a privacy explanation'
expect true 0.1.1
git -C "$FIXTURE" tag server@0.1.1
change deploy/chart.txt 'fix(deploy): correct production readiness'
expect true 0.1.2
git -C "$FIXTURE" tag server@0.1.2
change server/marketing/copy.txt 'feat(site): add another marketing page'
expect true 0.2.0
git -C "$FIXTURE" tag server@0.2.0
change server/protocol.txt 'feat(server)!: change the sync protocol'
git -C "$FIXTURE" tag server@99.0.0-rc.1
expect true 1.0.0
git -C "$FIXTURE" checkout -qb unrelated
change server/config.txt 'fix(server): only on another branch'
git -C "$FIXTURE" tag server@99.0.0
git -C "$FIXTURE" checkout -q main
expect true 1.0.0

touch "$FIXTURE/uncommitted"
if bash "$CHECK" > /dev/null 2>&1; then echo "Dirty worktree was accepted" >&2; exit 1; fi
rm "$FIXTURE/uncommitted"
printf '\ninvalid = [\n' >> "$FIXTURE/cliff.toml"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm 'ci: invalid configuration fixture'
if bash "$CHECK" > /dev/null 2>&1; then echo "Broken cliff configuration was accepted" >&2; exit 1; fi
echo "Release fixtures passed: bootstrap, no-op, filtering, bumps, tag reachability, prereleases and failures"
