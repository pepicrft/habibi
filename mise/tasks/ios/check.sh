#!/usr/bin/env bash
#MISE description="Calculate the next independent iOS release without publishing"
set -euo pipefail

ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
git -C "$ROOT" rev-parse --verify HEAD >/dev/null
if [[ -n $(git -C "$ROOT" status --porcelain) ]]; then
  echo "Release inputs must be committed; the worktree is not clean." >&2
  exit 1
fi

# Share Habibi's conventional-commit policy, not its server release history.
export GITHUB_TOKEN="" GH_TOKEN=""
cliff=(git cliff --repository "$ROOT" --config "$ROOT/cliff.toml" --use-branch-tags)
for path in 'native/**/*' 'mise/tasks/ios/**/*' '.github/workflows/ios-release.yml' \
  'cliff.toml' 'package*.json' 'server/marketing/theme.mjs' \
  'server/priv/theme.json' 'server/priv/theme-variants.json'; do
  cliff+=(--include-path "$path")
done
latest=$(git -C "$ROOT" tag --merged HEAD --list 'ios@*' |
  jq -Rrs 'split("\n") | map(select(test("^ios@[0-9]+\\.[0-9]+\\.[0-9]+$")))
    | sort_by(split("@")[1] | split(".") | map(tonumber)) | last // ""')

run_cliff() {
  if [[ -n "$latest" ]]; then
    "${cliff[@]}" --tag-pattern "^${latest//./\.}$" "$@" -- "${latest}..HEAD"
  else
    "${cliff[@]}" --tag-pattern '^ios@[0-9]+\.[0-9]+\.[0-9]+$' "$@"
  fi
}

context=$(run_cliff --unreleased --context)
count=$(jq '[.[].commits[]] | length' <<< "$context")
should_release=true
if [[ "$count" == 0 ]]; then
  should_release=false
  version=${latest#*@}
else
  version=$(run_cliff --bumped-version)
  version=${version#*@}
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "git-cliff returned an invalid iOS version: $version" >&2
    exit 1
  fi
  if [[ -n "$latest" ]] && ! jq -en --arg next "$version" --arg last "${latest#*@}" \
    '($next | split(".") | map(tonumber)) > ($last | split(".") | map(tonumber))' >/dev/null; then
    echo "The next iOS version must exceed $latest." >&2
    exit 1
  fi
fi

case "${1:-check}" in
  check)
    outputs=$(printf 'should-release=%s\nnext-version=ios@%s\nnext-version-number=%s\n' \
      "$should_release" "$version" "$version")
    printf '%s\n' "$outputs"
    [[ -z "${GITHUB_OUTPUT:-}" ]] || printf '%s\n' "$outputs" >> "$GITHUB_OUTPUT"
    ;;
  notes)
    if [[ "$should_release" == true ]]; then
      run_cliff --tag "ios@$version" --strip all
    fi
    ;;
  *) echo "Usage: $0 [check|notes]" >&2; exit 1 ;;
esac
