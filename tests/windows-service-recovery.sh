#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

installer=packaging/distributed/windows/Install-CrfNodeService.ps1
grep -Fq "'failureflag' \$serviceName '1'" "$installer" || crf_fail 'normal-error recovery flag is not enabled'
grep -Fq "Name FailureActionsOnNonCrashFailures -Value \$serviceRegistrySnapshot.FailureActionsOnNonCrashFailures" "$installer" || crf_fail 'existing failure flag is not restored on rollback'
grep -Fq 'Remove-ItemProperty -LiteralPath $serviceKey -Name FailureActionsOnNonCrashFailures' "$installer" || crf_fail 'absent failure flag is not restored on rollback'
printf 'PASS: Windows service recovery contract\n'
