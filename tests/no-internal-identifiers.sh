#!/usr/bin/env bash
# Guard against committing real internal network identifiers to this PUBLIC repo.
#
# Why this exists: commit bfe4dcd ("chore: scrub internal network identifiers")
# scrubbed real hosts and addresses out of the tree, but the scrub did not stick --
# a real tailnet FQDN and a real tailnet host address were committed again
# afterwards in docs/distributed-runner-farm/progress.md. Manual discipline had
# already failed once, so this makes it mechanical.
#
# Scope is deliberately narrow: NETWORK identifiers only (tailnet FQDNs, tailnet
# host addresses). It does NOT ban internal-sounding hostnames, because names like
# "dookie" and "squirts" are legitimate test fixture node_ids throughout
# controller/test/*.exs and crates/crf-node/src/*.rs. Banning those would produce
# constant false positives, and a noisy check is a disabled check.
#
# Placeholder conventions (established by bfe4dcd, follow them):
#   real host addresses  -> RFC 5737 (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24)
#   real tailnet FQDNs   -> <role>.tailnet-name.ts.net  (see crates/crf-node/src/config.rs)
#   real host aliases    -> generic role-based names (e.g. nashost, ctrlhost)

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
self="tests/no-internal-identifiers.sh"

# Tracked files only (git grep searches the index natively, and is portable to
# the bash 3.2 that ships on macOS -- mapfile is bash 4+).
exclude=":(exclude)${self}"

report() {
  printf '\n[no-internal-identifiers] %s\n' "$1"
  printf '%s\n' "$2" | sed 's/^/  /'
  fail=1
}

# --- 1. Tailnet FQDNs -------------------------------------------------------
# Allow only documented placeholders.
hits=$(git grep -nE '[a-z0-9-]+\.[a-z0-9-]+\.ts\.net' -- . "$exclude" 2>/dev/null \
  | grep -vE '\.(tailnet-name|example)\.ts\.net' || true)
if [ -n "$hits" ]; then
  report "Real tailnet FQDN committed. Use <role>.tailnet-name.ts.net instead:" "$hits"
fi

# --- 2. Tailnet host addresses (CGNAT 100.64.0.0/10) ------------------------
# A bare host address leaks a real node. A CIDR range (e.g. 100.64.0.0/10 in the
# egress firewall rules in runner-farm.sh) is functional code, not a leak, so
# anything immediately followed by "/" is allowed.
hits=$(git grep -nE '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}' -- . "$exclude" 2>/dev/null \
  | grep -vE '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]+' || true)
if [ -n "$hits" ]; then
  report "Real tailnet host address committed. Use RFC 5737 (198.51.100.x) instead:" "$hits"
fi

# --- 3. Regression guard for the identifiers that already leaked ------------
hits=$(git grep -niE 'manatee-triceratops' -- . "$exclude" 2>/dev/null || true)
if [ -n "$hits" ]; then
  report "Previously-leaked tailnet name reintroduced:" "$hits"
fi

if [ "$fail" -ne 0 ]; then
  printf '\n[no-internal-identifiers] FAIL - this repository is public.\n'
  printf '[no-internal-identifiers] Scrub per the conventions in the header of %s\n\n' "$self"
  exit 1
fi

echo "[no-internal-identifiers] ok"
