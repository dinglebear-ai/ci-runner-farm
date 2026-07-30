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
