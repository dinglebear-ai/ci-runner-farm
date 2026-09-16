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
grep -Fq 'apt-get install -y --no-install-recommends ruby' src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile || crf_fail 'stock runner image is missing Ruby parity'
grep -Fq 'usermod -aG docker runner' src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile || crf_fail 'stock runner cannot access its DinD socket'
grep -Fq "'{\"storage-driver\":\"vfs\"}'" src/usr/local/emhttp/plugins/ci-runner-farm/default.Dockerfile || crf_fail 'stock nested Docker storage driver is unsupported'
grep -Fq "RUNNER_BASE=\"$base\"" build-plg.sh || crf_fail 'release digest gate is missing'
image_page=src/usr/local/emhttp/plugins/ci-runner-farm/RunnerFarmImage.page
if grep -Eq 'curl[^|]*\|[[:space:]]*(sh|bash)' "$image_page"; then
  crf_fail 'runner image presets execute a remote installer through a curl pipeline'
fi
grep -Fq 'ARG RUSTUP_INIT_VERSION=1.28.2' "$image_page" || crf_fail 'Rust preset does not pin rustup-init'
grep -Fq '20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c' "$image_page" || crf_fail 'Rust preset lacks x86_64 rustup-init checksum'
grep -Fq 'e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c' "$image_page" || crf_fail 'Rust preset lacks arm64 rustup-init checksum'
grep -Fq 'ARG NODESOURCE_NODE_MAJOR=24' "$image_page" || crf_fail 'Node preset does not pin the NodeSource major release'
grep -Fq 'ARG NODESOURCE_KEY_SHA256=b42e0321dabdc24e892115da705cf061167eac12a317f23d329862d0aa0a271d' "$image_page" || crf_fail 'Node preset does not pin the NodeSource repository key'
grep -Fq 'echo "$NODESOURCE_KEY_SHA256  /tmp/nodesource-repo.gpg.key" | sha256sum -c -' "$image_page" || crf_fail 'Node preset does not verify the NodeSource repository key bytes'
grep -Fq 'URIs: https://deb.nodesource.com/node_%s.x' "$image_page" || crf_fail 'Node preset does not configure the pinned NodeSource repository directly'
grep -Fq 'ARG ANDROID_CMDLINE_TOOLS_VERSION=11076708' "$image_page" || crf_fail 'Android preset does not pin command-line tools version'
grep -Fq 'ARG ANDROID_CMDLINE_TOOLS_SHA256=2d2d50857e4eb553af5a6dc3ad507a17adf43d115264b1afc116f95c92e5e258' "$image_page" || crf_fail 'Android preset lacks command-line tools checksum'
grep -Fq 'echo "$ANDROID_CMDLINE_TOOLS_SHA256  /tmp/actools.zip" | sha256sum -c -' "$image_page" || crf_fail 'Android preset does not verify command-line tools bytes'

grep -Fq 'https://github.com/dinglebear-ai/ci-runner-farm/releases/' ci-runner-farm.plg || crf_fail 'generated plugin release URLs do not use the authoritative repository'
grep -Fq 'https://github.com/dinglebear-ai/ci-runner-farm' ci-runner-farm.plg || crf_fail 'generated plugin support URL does not use the authoritative repository'
if grep -R -n -E 'github\.com/unraid/ci-runner-farm|raw\.githubusercontent\.com/unraid/ci-runner-farm|REPO=.*unraid/ci-runner-farm' \
  build-plg.sh README.md community-applications; then
  crf_fail 'active publication metadata still references the non-authoritative upstream'
fi

migration="$(mktemp)"
sed -n '/# BEGIN_RUNNER_BASE_MIGRATION/,/# END_RUNNER_BASE_MIGRATION/p' build-plg.sh \
  | sed 's/\\\$/\$/g' >"$migration"
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
