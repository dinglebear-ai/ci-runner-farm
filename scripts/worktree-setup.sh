#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/worktree-setup.sh
  scripts/worktree-setup.sh <branch> [base-ref]

With no arguments, installs and verifies the pinned toolchain in the current
checkout. With a branch, creates .worktrees/<branch> from base-ref (default:
origin/main), then installs and verifies the toolchain there.
EOF
}

main_worktree() {
  git -C "$1" worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" || $# -gt 2 ]]; then
  usage
  [[ $# -le 2 ]] || exit 2
  exit 0
fi

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$(cd "$(main_worktree "$script_root")" && pwd)"

if [[ $# -ge 1 ]]; then
  branch="$1"
  base_ref="${2:-origin/main}"
  slug="${branch//\//-}"
  destination="$source_root/.worktrees/$slug"

  if [[ -e "$destination" ]]; then
    echo "refusing to overwrite existing worktree path: $destination" >&2
    exit 1
  fi

  if git -C "$source_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$source_root" worktree add "$destination" "$branch"
  else
    git -C "$source_root" worktree add -b "$branch" "$destination" "$base_ref"
  fi
else
  destination="$script_root"
fi

mise_config="$destination/.mise.toml"
if [[ ! -f "$mise_config" ]]; then
  echo "missing repository toolchain config: $mise_config" >&2
  echo "create worktrees from a revision containing .mise.toml (normally origin/main)" >&2
  exit 1
fi

command -v mise >/dev/null 2>&1 || {
  echo "mise is required; install it before setting up this worktree" >&2
  exit 1
}

echo "setting up worktree: $destination"
mise trust --yes "$mise_config" >/dev/null
mise install --yes --cd "$destination"

# The nested shell expands the expressions in the single-quoted program.
# shellcheck disable=SC2016
mise exec --cd "$destination" -- bash -Eeuo pipefail -c '
  go_version="$(go version)"
  rustc_version="$(rustc --version)"
  cargo_version="$(cargo --version)"
  elixir_version="$(elixir --version)"
  mix_version="$(mix --version)"

  printf "%s\n" "$go_version"
  printf "%s\n" "$rustc_version"
  printf "%s\n" "$cargo_version"
  printf "%s\n" "$elixir_version"
  printf "%s\n" "$mix_version"

  [[ "$go_version" == *"go1.25.3"* ]]
  [[ "$rustc_version" == "rustc 1.97.1 "* ]]
  [[ "$cargo_version" == "cargo 1.97.1 "* ]]
  [[ "$elixir_version" == *"Erlang/OTP 29"* ]]
  [[ "$elixir_version" == *"Elixir 1.20.3"* ]]
'

echo "worktree toolchain ready: $destination"
