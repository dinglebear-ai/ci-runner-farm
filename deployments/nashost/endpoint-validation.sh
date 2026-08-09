#!/bin/bash
# Canonical endpoint contract shared by the Nashost installer, scheduled audit,
# and runner image builds. Return codes are stable so callers can provide
# context-specific diagnostics: 1 scheme/required, 2 documentation address,
# 3 unsafe bytes, 4 malformed authority, 5 disallowed non-TLS Gotify target.

crf_require_http_endpoint() {
  local endpoint="${1:-}" purpose="${2:-kache}" scheme authority host port
  [ -n "$endpoint" ] || return 1
  [[ "$endpoint" =~ ^https?:// ]] || return 1
  scheme="${endpoint%%://*}"
  case "$endpoint" in
    *192.0.2.*|*198.51.100.*|*203.0.113.*) return 2 ;;
    *\"*|*\'*|*\\*|*[[:space:]]*) return 3 ;;
  esac
  [ -z "$(printf '%s' "$endpoint" | LC_ALL=C tr -d ' -~')" ] || return 3
  authority="${endpoint#*://}"
  authority="${authority%%/*}"
  case "$authority" in
    ''|*@*|*:*:*) return 4 ;;
    *:*)
      host="${authority%:*}"
      port="${authority##*:}"
      [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || return 4
      ;;
    *) host="$authority" ;;
  esac
  case "$host" in
    ''|.*|*..*|*.|-*|*-.*|*.-*|*[!A-Za-z0-9.-]*) return 4 ;;
  esac
  if [ "$purpose" = gotify ] && [ "$scheme" = http ] &&
     [ "$host" != localhost ] && [ "$host" != 127.0.0.1 ]; then
    return 5
  fi
  return 0
}

require_kache_endpoint() { crf_require_http_endpoint "${1:-}" kache; }
require_gotify_url() { crf_require_http_endpoint "${1:-}" gotify; }

crf_endpoint_error() {
  local purpose="$1" status="$2" name
  case "$purpose" in
    kache) name=KACHE_REMOTE_ENDPOINT ;;
    gotify) name=GOTIFY_URL ;;
    *) printf 'unknown endpoint purpose: %s\n' "$purpose" >&2; return 2 ;;
  esac
  case "$status" in
    1) printf '%s must be a non-empty HTTP or HTTPS URL\n' "$name" >&2 ;;
    2) printf '%s must not use an RFC 5737 documentation-only address\n' "$name" >&2 ;;
    3) printf '%s contains unsafe characters\n' "$name" >&2 ;;
    4) printf '%s must contain a valid authority and optional port from 1 through 65535\n' "$name" >&2 ;;
    5) printf '%s must use HTTPS; HTTP is allowed only for exact localhost or 127.0.0.1 loopback targets\n' "$name" >&2 ;;
    *) printf '%s is invalid\n' "$name" >&2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [ "$#" -eq 2 ] || { echo 'usage: endpoint-validation.sh <kache|gotify> <endpoint>' >&2; exit 2; }
  purpose="$1"
  case "$purpose" in kache|gotify) ;; *) echo 'endpoint purpose must be kache or gotify' >&2; exit 2 ;; esac
  if crf_require_http_endpoint "$2" "$purpose"; then
    exit 0
  else
    status=$?
  fi
  crf_endpoint_error "$purpose" "$status"
  exit "$status"
fi
