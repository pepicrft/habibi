#!/usr/bin/env bash
#MISE description="Test release versioning against disposable Git histories"
set -euo pipefail

SOURCE=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/habibi-release.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
unset GITHUB_OUTPUT
# Equal timestamps expose tag ordering bugs hidden by slower local runs.
export GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
git init -q -b main "$FIXTURE"
git -C "$FIXTURE" config user.name "Habibi release tests"
git -C "$FIXTURE" config user.email "release-tests@example.invalid"
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" config core.hooksPath /dev/null
mkdir -p "$FIXTURE/mise/tasks/release" "$FIXTURE/mise/tasks/ios" "$FIXTURE/native" \
  "$FIXTURE/server/marketing" "$FIXTURE/client" "$FIXTURE/deploy"
cp "$SOURCE/cliff.toml" "$FIXTURE/cliff.toml"
cp "$SOURCE/mise/tasks/release/check.sh" "$FIXTURE/mise/tasks/release/check.sh"
cp "$SOURCE/mise/tasks/ios/check.sh" "$FIXTURE/mise/tasks/ios/check.sh"
CHECK="$FIXTURE/mise/tasks/release/check.sh"
IOS_CHECK="$FIXTURE/mise/tasks/ios/check.sh"

if bash "$CHECK" > /dev/null 2>&1; then echo "Unborn HEAD was accepted" >&2; exit 1; fi
if bash "$IOS_CHECK" > /dev/null 2>&1; then echo "iOS unborn HEAD was accepted" >&2; exit 1; fi
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm 'feat(server): introduce the server and marketing site'

expect() {
  local output
  output=$(bash "$CHECK")
  grep -qx "should-release=$1" <<< "$output"
  grep -qx "next-version=habibi@$2" <<< "$output"
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
git -C "$FIXTURE" tag habibi@0.1.1
expect false 0.1.1
change deploy/chart.txt 'fix(deploy): correct production readiness'
expect true 0.1.2
git -C "$FIXTURE" tag habibi@0.1.2
change server/marketing/copy.txt 'feat(site): add another marketing page'
expect true 0.2.0
git -C "$FIXTURE" tag habibi@0.2.0
change server/protocol.txt 'feat(server)!: change the sync protocol'
git -C "$FIXTURE" tag habibi@99.0.0-rc.1
expect true 1.0.0
git -C "$FIXTURE" checkout -qb unrelated
change server/config.txt 'fix(server): only on another branch'
git -C "$FIXTURE" tag habibi@99.0.0
git -C "$FIXTURE" checkout -q main
expect true 1.0.0
git -C "$FIXTURE" tag habibi@1.0.0
git -C "$FIXTURE" checkout -qb feature
change server/feature.txt 'feat(server): release a merged feature'
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" merge -q --no-ff feature -m 'Merge pull request #1 from feature'
expect true 1.1.0
git -C "$FIXTURE" tag habibi@1.1.0
git -C "$FIXTURE" checkout -qb maintenance
change server/config.txt 'chore(server): merged maintenance'
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" merge -q --no-ff maintenance -m 'Merge pull request #2 from maintenance'
expect false 1.1.0

expect_ios() {
  local output
  output=$(bash "$IOS_CHECK")
  grep -qx "should-release=$1" <<< "$output"
  grep -qx "next-version=ios@$2" <<< "$output"
  grep -qx "next-version-number=$2" <<< "$output"
  if grep -q '^build-number=' <<< "$output"; then
    echo "Version selection must not allocate an upload build number" >&2; exit 1
  fi
}

# Server tags, including unreachable high versions, must not bootstrap iOS.
expect_ios true 0.1.0
git -C "$FIXTURE" tag ios@0.1.0
expect_ios false 0.1.0
change server/config.txt 'feat(server): unrelated server feature'
expect_ios false 0.1.0
change native/app.txt 'chore(ios): native maintenance'
expect_ios false 0.1.0
change native/app.txt 'fix(ios): correct device startup'
expect_ios true 0.1.1
bash "$IOS_CHECK" notes | grep -q 'correct device startup'
git -C "$FIXTURE" tag ios@0.1.1
git -C "$FIXTURE" tag ios@0.0.9
expect_ios false 0.1.1
change native/app.txt 'feat(ios): add an iPhone feature'
expect_ios true 0.2.0
git -C "$FIXTURE" tag ios@0.2.0
change native/app.txt 'feat(ios)!: change the native vault format'
git -C "$FIXTURE" tag ios@99.0.0-rc.1
expect_ios true 1.0.0
git -C "$FIXTURE" checkout -qb unrelated-ios
change native/app.txt 'feat(ios): only on another branch'
git -C "$FIXTURE" tag ios@99.0.0
git -C "$FIXTURE" checkout -q main
expect_ios true 1.0.0
# Marketing version selection is independent of GitHub upload attempts/counters.
GITHUB_RUN_NUMBER=0 GITHUB_RUN_ATTEMPT=3 expect_ios true 1.0.0
git -C "$FIXTURE" tag ios@1.0.0
git -C "$FIXTURE" checkout -qb ios-feature
change native/app.txt 'feat(ios): release a merged feature'
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" merge -q --no-ff ios-feature -m 'Merge pull request #3 from ios-feature'
expect_ios true 1.1.0
# Native-only changes must not alter the server's next version.
expect true 1.2.0

touch "$FIXTURE/uncommitted"
if bash "$CHECK" > /dev/null 2>&1; then echo "Dirty worktree was accepted" >&2; exit 1; fi
if bash "$IOS_CHECK" > /dev/null 2>&1; then echo "iOS dirty worktree was accepted" >&2; exit 1; fi
rm "$FIXTURE/uncommitted"
printf '\ninvalid = [\n' >> "$FIXTURE/cliff.toml"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm 'ci: invalid configuration fixture'
if bash "$CHECK" > /dev/null 2>&1; then echo "Broken cliff configuration was accepted" >&2; exit 1; fi
if bash "$IOS_CHECK" > /dev/null 2>&1; then echo "iOS broken cliff configuration was accepted" >&2; exit 1; fi
echo "Server and iOS release fixtures passed: independent tags/paths, bootstrap, merges, no-op, bumps, retries and failures"
