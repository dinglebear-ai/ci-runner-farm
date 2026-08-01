#!/usr/bin/env bash

crf_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

crf_assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  [ "$expected" = "$actual" ] || crf_fail "$message (expected '$expected', got '$actual')"
}

crf_assert_contains() {
  local haystack="$1" needle="$2" message="${3:-missing value}"
  case "$haystack" in
    *"$needle"*) ;;
    *) crf_fail "$message (missing '$needle')" ;;
  esac
}

crf_assert_file_mode() {
  local path="$1" expected="$2" actual
  actual="$(stat -c '%a' "$path")"
  crf_assert_eq "$expected" "$actual" "wrong mode for $path"
}

crf_go125() {
  local candidate="${CRF_GO:-}" version=""
  if [ -z "$candidate" ] && command -v go >/dev/null 2>&1; then
    candidate="$(command -v go)"
    version="$("$candidate" version 2>/dev/null | awk '{print $3}')"
    [ "$version" = go1.25.3 ] || candidate=""
  fi
  if [ -z "$candidate" ] && command -v mise >/dev/null 2>&1; then
    candidate="$(mise where go@1.25.3 2>/dev/null)/bin/go"
  fi
  [ -n "$candidate" ] && [ -x "$candidate" ] ||
    { crf_fail "Go 1.25.3 is required (set CRF_GO or install it on PATH)"; return 1; }
  version="$("$candidate" version 2>/dev/null | awk '{print $3}')"
  [ "$version" = go1.25.3 ] ||
    { crf_fail "Go 1.25.3 is required, found ${version:-unknown} at $candidate"; return 1; }
  printf '%s\n' "$candidate"
}
