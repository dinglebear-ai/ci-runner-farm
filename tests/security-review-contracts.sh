#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/assert.sh

engine=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-farm.sh
snippet="$(mktemp)"
trap 'rm -f "$snippet"' EXIT
for fn in gh_fetch_all public_repo_problem org_runner_group_problem privileged_trust_problem; do
  sed -n "/^${fn}()/,/^}/p" "$engine" >>"$snippet"
done
. "$snippet"

DIND=true SHARE_DOCKER_SOCK=false GH_SCOPE=repo GH_REPOS=owner/public ACCESS_TOKEN=token
SECURITY_CACHE="$(dirname "$snippet")/crf-security-cache.$$" SECURITY_TTL=0
gh_fetch_all(){ mkdir -p "$2"; printf '{"visibility":"public"}' >"$2/1"; }
[ -n "$(privileged_trust_problem)" ] || crf_fail 'public privileged target was accepted'

gh_fetch_all(){ mkdir -p "$2"; printf '{"visibility":"private"}' >"$2/1"; }
[ -z "$(privileged_trust_problem)" ] || crf_fail 'private repository target was rejected'

mktemp(){ return 1; }
[ -n "$(privileged_trust_problem)" ] || crf_fail 'temporary workspace failure allowed privileged runners'
unset -f mktemp

GH_SCOPE=org RUNNER_GROUP=restricted
[ -n "$(privileged_trust_problem)" ] || crf_fail 'unproven organization restriction was accepted'
CRF_I_ACCEPT_UNRESTRICTED_PRIVILEGED_RUNNER_HOST_ROOT_RISK=YES_I_ACCEPT_UNRAID_HOST_ROOT_COMPROMISE
[ -z "$(privileged_trust_problem)" ] || crf_fail 'explicit high-friction compatibility override was rejected'

grep -Fqx 'DIND="false"' src/usr/local/emhttp/plugins/ci-runner-farm/default.cfg || crf_fail 'reference DIND default is privileged'
grep -Fq 'DIND="false"' "$engine" || crf_fail 'runtime DIND default is privileged'
grep -Fq "'DIND'=>'false'" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page || crf_fail 'Settings DIND default is privileged'
grep -Fq "crf_sel(\$cfg,'DIND','false','false')" src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmSettings.page || crf_fail 'Settings DIND fallback is privileged'

base='myoung34/github-runner@sha256:bc766ffbf9c8e6fd301d486a0aecbfbaa7920ab33cef05958a9eab62dd119537'
grep -Fxq "FROM $base" src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile || crf_fail 'runner base is not digest pinned'
grep -Fq "RUNNER_BASE=\"$base\"" build-plg.sh || crf_fail 'release digest gate is missing'
grep -Fq 'https://github.com/dinglebear-ai/ci-runner-farm/releases/' ci-runner-farm.plg || crf_fail 'generated plugin release URLs do not use the authoritative repository'
grep -Fq 'https://github.com/dinglebear-ai/ci-runner-farm' ci-runner-farm.plg || crf_fail 'generated plugin support URL does not use the authoritative repository'
if rg -n 'github\.com/unraid/ci-runner-farm|raw\.githubusercontent\.com/unraid/ci-runner-farm|REPO=.*unraid/ci-runner-farm' \
  build-plg.sh README.md community-applications; then
  crf_fail 'active publication metadata still references the non-authoritative upstream'
fi

migration="$(mktemp)"
sed -n '/# BEGIN_RUNNER_BASE_MIGRATION/,/# END_RUNNER_BASE_MIGRATION/p' ci-runner-farm.plg >"$migration"
fixture="$(mktemp -d)"
CFGDIR="$fixture"; DF="$CFGDIR/Dockerfile"
printf '%s\n' 'FROM myoung34/github-runner:latest' 'RUN echo customized' >"$DF"
. "$migration" >/dev/null
grep -Fxq "FROM $base" "$DF" || crf_fail 'saved stock mutable base was not migrated'
grep -Fxq 'RUN echo customized' "$DF" || crf_fail 'base migration discarded Dockerfile customization'
printf '%s\n' 'FROM ubuntu:24.04' >"$DF"
. "$migration" >/dev/null
grep -Fxq 'FROM ubuntu:24.04' "$DF" || crf_fail 'custom base was rewritten'
rm -rf "$fixture" "$migration"

printf 'PASS: security review contracts\n'
