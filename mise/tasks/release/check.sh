#!/usr/bin/env bash
#MISE description="Check the next combined server and marketing release without publishing"
set -euo pipefail

ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1 || {
  echo "Create the initial commit before calculating a release." >&2
  exit 1
}
if [[ -n $(git -C "$ROOT" status --porcelain) ]]; then
  echo "Release inputs must be committed; the worktree is not clean." >&2
  exit 1
fi

# No GitHub enrichment/API calls are needed for local conventional commits.
export GITHUB_TOKEN="" GH_TOKEN=""
cliff=(git cliff --repository "$ROOT" --config "$ROOT/cliff.toml" --use-branch-tags)
for path in 'server/**/*' 'deploy/**/*' 'package*.json' 'mise.toml' 'mise.lock' 'cliff.toml' \
  '.dockerignore' 'mise/tasks/release/**/*' '.github/workflows/*' 'README.md' 'LICENSE'; do
  cliff+=(--include-path "$path")
done

latest=$(git -C "$ROOT" tag --merged HEAD --sort=version:refname --list 'server@*' |
  awk '/^server@[0-9]+\.[0-9]+\.[0-9]+$/ { latest=$0 } END { print latest }')

run_cliff() {
  if [[ -n "$latest" ]]; then
    "${cliff[@]}" "$@" -- "${latest}..HEAD"
  else
    "${cliff[@]}" "$@"
  fi
}

context=$(run_cliff --unreleased --context)
count=$(jq '[.[].commits[]] | length' <<< "$context")
should_release=true
if [[ -n "$latest" && "$count" == 0 ]]; then
  should_release=false
  version=${latest#server@}
else
  version=$(run_cliff --bumped-version)
  version=${version#server@}
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "git-cliff returned an invalid stable version: $version" >&2
    exit 1
  fi
  if [[ -n "$latest" ]] && ! jq -en --arg next "$version" --arg last "${latest#server@}" \
    '($next | split(".") | map(tonumber)) > ($last | split(".") | map(tonumber))' >/dev/null; then
    echo "The next version must exceed $latest." >&2
    exit 1
  fi
fi

case "${1:-check}" in
  check)
    outputs=$(printf 'should-release=%s\nnext-version=server@%s\nnext-version-number=%s\n' \
      "$should_release" "$version" "$version")
    printf '%s\n' "$outputs"
    [[ -z "${GITHUB_OUTPUT:-}" ]] || printf '%s\n' "$outputs" >> "$GITHUB_OUTPUT"
    ;;
  notes)
    if [[ "$should_release" == true ]]; then
      run_cliff --tag "server@$version" --strip all
    fi
    ;;
  *) echo "Usage: $0 [check|notes]" >&2; exit 1 ;;
esac
