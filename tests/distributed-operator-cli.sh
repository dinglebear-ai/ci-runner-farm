#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake="$tmp/controller"
log="$tmp/args"
# Literal script body intentionally expands variables only when the fake runs.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s"\ncase "${CRF_FAKE_RESULT:-ok}" in ok) echo "CRF_OPERATOR_OK %%{}";; error) echo "CRF_OPERATOR_ERROR :rejected";; esac\n' "$log" >"$fake"
chmod 0755 "$fake"
cli="packaging/distributed/admin/crf-operator-status"

CRF_CONTROLLER_RELEASE="$fake" "$cli" status
grep -Fxq rpc "$log"
grep -Fq 'OperatorSnapshot.snapshot' "$log"

CRF_CONTROLLER_RELEASE="$fake" "$cli" drain unraid-1 7
grep -Fq 'set_draining("unraid-1", 7, true)' "$log"

CRF_CONTROLLER_RELEASE="$fake" "$cli" undrain unraid-1 7
grep -Fq 'set_draining("unraid-1", 7, false)' "$log"

CRF_CONTROLLER_RELEASE="$fake" "$cli" drain 'zone:unraid-1' 7
grep -Fq 'set_draining("zone:unraid-1", 7, true)' "$log"

if CRF_FAKE_RESULT=error CRF_CONTROLLER_RELEASE="$fake" "$cli" drain unraid-1 7 >/dev/null; then
  echo 'rejected drain returned success' >&2
  exit 1
fi

if CRF_CONTROLLER_RELEASE="$fake" "$cli" force-abandon placement-1 2>/dev/null; then
  echo 'force abandon accepted without --force' >&2
  exit 1
fi
CRF_CONTROLLER_RELEASE="$fake" "$cli" force-abandon placement-1 --force
grep -Fq 'force_abandon("placement-1", true)' "$log"

for invalid in '../escape' 'quoted"node' 'node;halt'; do
  if CRF_CONTROLLER_RELEASE="$fake" "$cli" drain "$invalid" 7 2>/dev/null; then
    echo "unsafe node identity accepted: $invalid" >&2
    exit 1
  fi
done

echo 'distributed-operator-cli: OK'
