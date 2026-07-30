#!/bin/bash
###############################################################################
# CI Runner Farm - manage GitHub Actions self-hosted BUILD runners as Docker
# containers on Unraid. Multiple concurrent runners, container-only (no VM),
# warm shared caches on a fast pool, resource-capped so builds coexist with
# the host and the other workloads.
#
# Subcommands:
#   start            provision RUNNER_COUNT runner containers
#   stop             stop+remove all managed runner containers
#   restart          stop then start
#   scale <N>        grow/shrink the fleet to N runners
#   status           human-readable fleet table
#   status-json      machine-readable status for the web UI
#   logs <i>         tail logs for runner i
#   validate         dry-provision one container (no GitHub token needed) to
#                    prove mounts/limits/image on this box, then remove it
#   prune-cache      clear the shared cache root
###############################################################################
set -uo pipefail

PLUGIN="ci-runner-farm"
CFGDIR="/boot/config/plugins/${PLUGIN}"
# Ephemeral runtime caches/locks live on tmpfs, not the USB flash (they are
# rewritten every 60-300s while a settings tab is open — a flash-wear antipattern).
RUNDIR="/var/local/emhttp/${PLUGIN}"
mkdir -p "$RUNDIR" 2>/dev/null || RUNDIR="$CFGDIR"
CFG="${CFGDIR}/${PLUGIN}.cfg"
TOKEN_FILE="${CFGDIR}/token"
REGISTRY_TOKEN_FILE="${CFGDIR}/registry-token"
MANAGED_LABEL="net.unraid.ci-runner-farm.managed=true"
NAME_PREFIX="ci-runner"
LABEL_NS="net.unraid.ci-runner-farm"

# ---- defaults (overridden by ci-runner-farm.cfg) ---------------------------
GH_SCOPE="repo"                       # repo | org
GH_OWNER="unraid"
GH_REPOS="unraid/repo-a unraid/repo-b"
RUNNER_GROUP=""
RUNNER_COUNT=4
RUNNER_LABELS="self-hosted,unraid,build"
RUNNER_MODE="single"                  # single | pools
RUNNER_POOLS="rust|3|2|5|1;python|1|1|2|1;typescript|1|1|2|1"
POOL_BACKEND="classic"                # requested only; effective backend is durable runtime state
RUNNER_CPUS=""                        # per-runner CPU cap; empty = uncapped (CFS time-shares fairly)
RUNNER_MEMORY="16g"                   # per-runner memory cap (kept: memory isn't time-shared like CPU)
CACHE_ROOT="/mnt/cache/github-runner" # must be a dedicated SUBDIR under a pool/disk, never a bare mount root (see crf_safe_cache_root)
WORK_TMPFS_SIZE="8g"                  # empty => bind workdir to pool instead of RAM
IMAGE_SOURCE="builtin"                # builtin = run the locally-built image; remote = pull IMAGE from a registry
BUILTIN_IMAGE="ci-runner-farm-runner:latest"  # tag produced by the in-plugin image builder (build-image)
IMAGE=""                              # remote image ref, used when IMAGE_SOURCE=remote (e.g. ghcr.io/org/img:tag)
EPHEMERAL="false"                     # true => runner deregisters after each job
RUN_AS_ROOT="false"                   # false => jobs run as non-root 'runner' (sudo+docker groups), like
                                      # GitHub-hosted runners. true => jobs run as root (legacy).
ACCESS_TOKEN=""                       # GitHub PAT (repo scope; +admin:org for org). Stays host-side:
                                      # runners get a short-lived registration token, never the PAT itself.
SHARE_DOCKER_SOCK="false"             # mount host docker.sock for service containers (ignored when DIND=true).
                                      # Off by default: it gives jobs root-equivalent host access — opt in only
                                      # for trusted/private repos. DIND=true (the default) supersedes it anyway.
DIND="true"                           # docker-in-docker: each runner gets its own daemon (--privileged).
                                      # Fixes GitHub Actions services: networking + 'port already allocated' collisions.
SHARED_IMAGE_CACHE="true"             # run a shared pull-through registry mirror so every DinD runner
                                      # reuses pulled images (postgres, etc.) instead of each pulling cold.
MIRROR_NAME="ci-runner-mirror"        # cache persists on the pool across restarts.
MIRROR_PORT="5000"
# ---- network isolation -----------------------------------------------------
NETWORK_ISOLATION="off"               # off     = runners on the default docker bridge (legacy).
                                      # isolate = dedicated bridge; runners can't reach your OTHER
                                      #           Unraid containers (docker inter-network isolation).
                                      # strict  = isolate + DOCKER-USER egress rules that block the
                                      #           runners from the Unraid host + your LAN (RFC1918),
                                      #           while still allowing the internet + the shared mirror.
RUNNER_NETWORK="ci-runner-net"        # name of the dedicated bridge (created when isolation != off).
                                      # Docker auto-allocates its subnet; we read it back for the rules.
FW_TAG="ci-runner-farm"               # iptables comment tag used to find/remove our DOCKER-USER rules
# ---- private registry auth: docker login so the host can pull a private IMAGE
REGISTRY_SERVER=""                     # e.g. ghcr.io — registry to docker login (empty = skip)
REGISTRY_USERNAME=""                   # registry username (password/token stored in registry-token file)
REGISTRY_TOKEN=""                      # registry password/token (loaded from registry-token file)
# ---- warm caches mounted into every runner (host-subdir:container-path) -----
# Cache mounts target the runner's home (/home/runner) so the non-root 'runner'
# user can read/write them (it cannot even traverse /root). RUNNER_UID:RUNNER_GID
# own the host cache dirs so the non-root runner can write (see ensure_dirs).
RUNNER_UID="1001"                     # uid of the image's 'runner' user (myoung34/github-runner)
RUNNER_GID="121"                      # gid of the 'runner' group
CACHE_MOUNTS="cargo-registry:/home/runner/.cargo/registry cargo-git:/home/runner/.cargo/git pnpm-store:/home/runner/.local/share/pnpm/store npm:/home/runner/.npm yarn:/home/runner/.cache/yarn ms-playwright:/home/runner/.cache/ms-playwright"
# ---- autoscaling (live utilization): fleet floats between MIN and MAX -------
AUTOSCALE="false"                     # true => a daemon grows/shrinks the fleet by demand
AUTOSCALE_MIN="2"                     # never go below this many runners
AUTOSCALE_MAX="16"                    # never go above this many
AUTOSCALE_MIN_IDLE="2"                # keep at least this many idle (warm) runners as headroom
AUTOSCALE_STEP="2"                    # add/remove this many per adjustment
AUTOSCALE_INTERVAL="30"              # seconds between checks
AUTOSCALE_IDLE_GRACE="5"             # consecutive over-idle checks before scaling down (anti-flap)
# ---- image auto-update: keep the runner image current, roll the fleet --------
IMAGE_AUTOUPDATE="false"             # true => a daemon periodically pulls the runner image and,
                                     # when the digest moves, recreates runners on the new image.
IMAGE_AUTOUPDATE_INTERVAL="1800"     # seconds between update checks (default 30 min)
IMAGE_DRAIN_TIMEOUT="3600"           # max seconds to wait for a busy runner to finish its job
                                     # before leaving it on the old image this cycle (0 = wait forever)
# shellcheck disable=SC2034  # consumed only by RunnerFarmDashboard.page's Cond, never inside this script
DASHBOARD_WIDGET_ENABLE="true"       # show the Main->Dashboard status tile (read only by RunnerFarmDashboard.page's Cond)
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/usr/local/emhttp/plugins/ci-runner-farm/include/runner-pools.sh
. "$SCRIPT_DIR/runner-pools.sh"

# Allowlist of keys the settings page may set. load_cfg only ever assigns these.
CFG_KEYS="GH_SCOPE GH_OWNER GH_REPOS RUNNER_GROUP RUNNER_COUNT RUNNER_LABELS RUNNER_MODE RUNNER_POOLS POOL_BACKEND \
RUNNER_CPUS RUNNER_MEMORY CACHE_ROOT WORK_TMPFS_SIZE IMAGE_SOURCE IMAGE EPHEMERAL \
RUN_AS_ROOT REGISTRY_SERVER REGISTRY_USERNAME CACHE_MOUNTS SHARE_DOCKER_SOCK DIND \
SHARED_IMAGE_CACHE NETWORK_ISOLATION RUNNER_NETWORK MIRROR_PORT AUTOSCALE AUTOSCALE_MIN \
AUTOSCALE_MAX AUTOSCALE_MIN_IDLE AUTOSCALE_STEP AUTOSCALE_INTERVAL \
AUTOSCALE_IDLE_GRACE IMAGE_AUTOUPDATE IMAGE_AUTOUPDATE_INTERVAL IMAGE_DRAIN_TIMEOUT \
DASHBOARD_WIDGET_ENABLE"

# Long-running daemons reload this file in place. Snapshot every configurable
# default once so a key omitted by an older config resets instead of retaining
# the value from the previous reload (notably RUNNER_MODE/RUNNER_POOLS).
declare -A CFG_DEFAULTS=()
for cfg_key in $CFG_KEYS; do
  CFG_DEFAULTS["$cfg_key"]="${!cfg_key-}"
done

# Read ci-runner-farm.cfg WITHOUT sourcing it (the file is written by the web form, so
# sourcing would execute anything a crafted value smuggled in). Parse KEY="value"
# lines ourselves and assign via printf -v — a literal string set, never eval'd —
# and only for keys on the allowlist above.
load_cfg() {
  local key
  for key in $CFG_KEYS; do
    printf -v "$key" '%s' "${CFG_DEFAULTS[$key]}"
  done
  [ -f "$CFG" ] || return 0
  local line val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    [ "${line#*=}" = "$line" ] && continue           # no '=' on the line
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    case "$key" in *[!A-Za-z0-9_]*|'') continue;; esac
    case " $CFG_KEYS " in *" $key "*) ;; *) continue;; esac
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    printf -v "$key" '%s' "$val"
  done < "$CFG"
}

load_cfg
[ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
[ -z "$REGISTRY_TOKEN" ] && [ -f "$REGISTRY_TOKEN_FILE" ] && REGISTRY_TOKEN="$(cat "$REGISTRY_TOKEN_FILE" 2>/dev/null)"
# PID files live on tmpfs (RUNDIR), not flash: they're pure per-boot runtime state,
# so this both spares the USB stick and means a stale PID can't survive a reboot to
# later match an unrelated reused PID that autoscale_stop would then kill.
AUTOSCALE_PID="${RUNDIR}/autoscale.pid"
IMAGEUPDATE_PID="${RUNDIR}/imageupdate.pid"
RECONCILE_PID="${RUNDIR}/reconcile.pid"
SECURITY_CACHE="${RUNDIR}/security-warn.cache"   # cached public-repo warning (TTL below), so the
SECURITY_TTL="300"                               # UI's 5s status poll never hammers the GitHub API

log()  { echo "[ci-runner-farm] $*"; }
err()  { echo "[ci-runner-farm] ERROR: $*" >&2; }
host() { hostname -s; }

validate_runtime_config() {
  pool_config_validate "$RUNNER_MODE" "$RUNNER_POOLS" "$GH_SCOPE" "$GH_OWNER"
}

cleanup_pool_runtime_state() {
  local keep=" " rec pool gen f
  if pool_mode_enabled; then
    while IFS= read -r rec; do
      pool="${rec%%|*}"; gen="$(pool_state_generation "$pool")"
      keep="${keep}${RUNDIR}/autoscale.${pool}.${gen}.state ${RUNDIR}/scale-override.${pool}.${gen} "
    done < <(pool_records)
  fi
  for f in "$RUNDIR"/autoscale.*.*.state "$RUNDIR"/scale-override.*.*; do
    [ -e "$f" ] || continue
    case "$keep" in *" $f "*) ;; *) rm -f "$f" ;; esac
  done
}

# One authoritative Docker snapshot for pool-aware hot paths. The file is
# process-local in intent but tmpfs-backed so subshells created by command
# substitution can consume the same parsed records. Fields:
# name|state|health|cpus|memory|confgen|pool|scope|index|routing-label|identity
INVENTORY_FILE="$RUNDIR/fleet-inventory.tsv"
INVENTORY_ACTIVE=0

fleet_inventory_invalidate() {
  INVENTORY_ACTIVE=0
  rm -f "$INVENTORY_FILE" 2>/dev/null || true
}

fleet_inventory_refresh() {
  local names raw tmp row name state health cpus mem gen pool scope pidx legacy_idx managed version routing identity expected
  names="$(docker ps -a --filter "label=${MANAGED_LABEL}" --format '{{.Names}}' | sort -V)"
  tmp="${INVENTORY_FILE}.tmp.$$"
  : > "$tmp" || return 1
  if [ -n "$names" ]; then
    # shellcheck disable=SC2086 # one Docker argument per newline-delimited managed name
    if ! raw="$(docker inspect -f '{{.Name}}|{{.State.Status}}|{{with index .State "Health"}}{{.Status}}{{end}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.Memory}}|{{index .Config.Labels "net.unraid.ci-runner-farm.confgen"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.pool"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.scope-target"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.pool-index"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.index"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.managed"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.identity-version"}}|{{index .Config.Labels "net.unraid.ci-runner-farm.routing-label"}}' $names 2>/dev/null)"; then
      rm -f "$tmp"; return 1
    fi
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS='|' read -r name state health cpus mem gen pool scope pidx legacy_idx managed version routing _extra <<< "$row"
      name="${name#/}"; identity=invalid-managed
      [ "$gen" = "<no value>" ] && gen=""
      [ "$pool" = "<no value>" ] && pool=""
      [ "$scope" = "<no value>" ] && scope=""
      [ "$pidx" = "<no value>" ] && pidx=""
      [ "$legacy_idx" = "<no value>" ] && legacy_idx=""
      [ "$managed" = "<no value>" ] && managed=""
      [ "$version" = "<no value>" ] && version=""
      [ "$routing" = "<no value>" ] && routing=""
      # Reject delimiter/control injection in metadata before it reaches the
      # inventory format or later JSON/selector consumers.
      case "$name$scope$pool$pidx$legacy_idx$routing" in
        *$'\n'*|*$'\r'*|*$'\t'*) name="" ;;
      esac
      [ -n "$name" ] || continue
      if [ -z "$pool" ] && [[ "$name" =~ ^${NAME_PREFIX}-([0-9]+)$ ]]; then
        pool=default
        [ -n "$pidx" ] || pidx="${BASH_REMATCH[1]}"
      fi
      [ -n "$pidx" ] || pidx="$legacy_idx"
      if [ "$managed" = true ]; then
        case "$pidx" in ''|*[!0-9]*) ;;
          *)
            if [ "$pool" = default ]; then
              expected="${NAME_PREFIX}-${pidx}"
              if [ "$name" = "$expected" ] && { [ -z "$scope" ] || github_scope_validate "$scope"; }; then identity=valid; fi
            elif pool_id_valid "$pool" && [ "$version" = 1 ]; then
              expected="${NAME_PREFIX}-${pool}-${pidx}"
              if [ "$name" = "$expected" ] && github_scope_validate "$scope" && [[ "$scope" == org:* ]]; then identity=valid; fi
            fi
            ;;
        esac
      fi
      # Fields sourced from Docker labels must not be able to add columns.
      case "$gen$pool$scope$routing" in *'|'*) identity=invalid-managed; pool=invalid; scope=""; routing="" ;; esac
      printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$name" "$state" "$health" "$cpus" "$mem" "$gen" "${pool:-invalid}" "$scope" "${pidx:-0}" "$routing" "$identity" >> "$tmp"
    done <<< "$raw"
  fi
  mv "$tmp" "$INVENTORY_FILE" || { rm -f "$tmp"; return 1; }
  INVENTORY_ACTIVE=1
}

inventory_names() {
  local pool="${1:-}"
  [ -f "$INVENTORY_FILE" ] || return 0
  if [ -n "$pool" ]; then awk -F'|' -v p="$pool" '$7 == p && $11 == "valid" { print $1 }' "$INVENTORY_FILE"
  else cut -d'|' -f1 "$INVENTORY_FILE"; fi
}

inventory_field() {
  local name="$1" field="$2" col
  case "$field" in
    state) col=2 ;; health) col=3 ;; cpus) col=4 ;; memory) col=5 ;;
    confgen) col=6 ;; pool) col=7 ;; scope) col=8 ;; index) col=9 ;;
    routing_label) col=10 ;; identity) col=11 ;; *) return 1 ;;
  esac
  awk -F'|' -v n="$name" -v c="$col" '$1 == n { print $c; exit }' "$INVENTORY_FILE"
}

inventory_count() { inventory_names "${1:-}" | grep -c .; }

inventory_state_counts() {
  local pool="$1" c phase
  POOL_BUSY=0; POOL_IDLE=0; POOL_STARTING=0; POOL_ERROR=0
  for c in $(inventory_names "$pool"); do
    phase="$(runner_state "$c")"
    case "$phase" in
      busy) POOL_BUSY=$((POOL_BUSY+1)) ;;
      idle) POOL_IDLE=$((POOL_IDLE+1)) ;;
      starting) POOL_STARTING=$((POOL_STARTING+1)) ;;
      *) POOL_ERROR=$((POOL_ERROR+1)) ;;
    esac
  done
}

managed_names() {
  local pool="${1:-}"
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    inventory_names "$pool"
  elif [ -n "$pool" ]; then
    fleet_inventory_refresh && inventory_names "$pool"
  else
    docker ps -a --filter "label=${MANAGED_LABEL}" --format '{{.Names}}' | sort -V
  fi
}

current_count() {
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then inventory_count "${1:-}"
  else managed_names "${1:-}" | grep -c .; fi
}

runner_pool() {
  local p
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    p="$(inventory_field "$1" pool)"; [ -n "$p" ] && { printf '%s\n' "$p"; return; }
  fi
  p="$(docker inspect -f "{{ index .Config.Labels \"${LABEL_NS}.pool\" }}" "$1" 2>/dev/null)"
  [ "$p" = "<no value>" ] && p=""
  printf '%s\n' "${p:-default}"
}

runner_index() {
  local i
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    i="$(inventory_field "$1" index)"; [ -n "$i" ] && { printf '%s\n' "$i"; return; }
  fi
  i="$(docker inspect -f "{{ index .Config.Labels \"${LABEL_NS}.pool-index\" }}" "$1" 2>/dev/null)"
  [ "$i" = "<no value>" ] && i=""
  [ -n "$i" ] || i="$(docker inspect -f "{{ index .Config.Labels \"${LABEL_NS}.index\" }}" "$1" 2>/dev/null)"
  [ "$i" = "<no value>" ] && i=""
  [ -n "$i" ] || i="${1##*-}"
  printf '%s\n' "$i"
}

runner_scope_target() {
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    inventory_field "$1" scope
    return
  fi
  local target
  target="$(docker inspect -f "{{ index .Config.Labels \"${LABEL_NS}.scope-target\" }}" "$1" 2>/dev/null)"
  [ "$target" = "<no value>" ] && target=""
  printf '%s\n' "$target"
}

runner_name_for() {
  local idx="$1" pool="${2:-default}"
  if pool_mode_enabled; then printf '%s-%s-%s\n' "$NAME_PREFIX" "$pool" "$idx"
  else printf '%s-%s\n' "$NAME_PREFIX" "$idx"; fi
}

runner_identity_validate() {
  local name="$1" managed pool idx scope version expected
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    [ "$(inventory_field "$name" identity)" = valid ]
    return
  fi
  managed="$(docker inspect -f "{{ index .Config.Labels \"${MANAGED_LABEL%=*}\" }}" "$name" 2>/dev/null)" || return 1
  [ "$managed" = true ] || return 1
  pool="$(runner_pool "$name")"; idx="$(runner_index "$name")"; scope="$(runner_scope_target "$name")"
  version="$(docker inspect -f "{{ index .Config.Labels \"${LABEL_NS}.identity-version\" }}" "$name" 2>/dev/null)"
  case "$idx" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$scope" ] || github_scope_validate "$scope" || return 1
  if [ "$pool" = default ]; then
    expected="${NAME_PREFIX}-${idx}"
  else
    pool_id_valid "$pool" || return 1
    [ "$version" = 1 ] || return 1
    case "$scope" in org:*) ;; *) return 1 ;; esac
    expected="${NAME_PREFIX}-${pool}-${idx}"
  fi
  [ "$name" = "$expected" ]
}

# is a runner actively running a job? (last meaningful log line)
# Single busy/idle/starting/error predicate shared by the autoscaler (scale-down
# safety) and the UI status, so the two can never disagree. Deterministic: ask the
# runner which agent process is live (Runner.Worker = running a job, Runner.Listener
# = idle-waiting) in one docker exec, matching the image's own healthcheck, with a
# log-tail fallback for non-standard images or the brief gap between agent processes.
runner_state() {
  local c="$1" p
  p="$(docker exec "$c" sh -c 'pgrep -x Runner.Worker >/dev/null 2>&1 && echo busy || { pgrep -x Runner.Listener >/dev/null 2>&1 && echo idle; }' 2>/dev/null)"
  case "$p" in busy) echo busy; return;; idle) echo idle; return;; esac
  case "$(docker logs --tail 15 "$c" 2>&1 | grep -iE 'Running job|Listening for Jobs|Job .* completed|error' | tail -1)" in
    *"Running job"*)                      echo busy ;;
    *"Listening for Jobs"*|*"completed"*) echo idle ;;
    *[Ee]rror*)                           echo error ;;
    *)                                    echo starting ;;
  esac
}
runner_busy() { [ "$(runner_state "$1")" = busy ]; }
runner_authoritatively_failed() {
  local c="$1" st health
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    st="$(inventory_field "$c" state)"; health="$(inventory_field "$c" health)"
  else
    st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    health="$(docker inspect -f '{{with index .State "Health"}}{{.Status}}{{end}}' "$c" 2>/dev/null)"
  fi
  case "$st" in
    exited|dead) return 0 ;;
    running) [ "$health" = unhealthy ] ;;
    *) return 1 ;;
  esac
}
busy_count() {
  local pool="${1:-}" b=0 c
  for c in $(managed_names "$pool"); do [ -n "$c" ] && runner_busy "$c" && b=$((b+1)); done
  echo "$b"
}

# ── Config generation ────────────────────────────────────────────────────────
# A short fingerprint of every config value that build_args BAKES INTO a runner
# container at creation (image, resources, mounts, DinD/mirror, network, registration
# identity) — i.e. the settings that only take effect on recreate, NOT the live keys the
# daemons re-read each tick (autoscale thresholds, image-autoupdate cadence). Stamped as
# a label on every runner so the reconciler can tell which runners predate a config
# change and migrate them onto the new config as they go idle. IMPORTANT: whenever you
# add a setting that build_args bakes into the container, add it here too.
crf_confgen() {
  local pool="${1:-default}" scope_target="${2:-}"
  if pool_mode_enabled; then
    [ -n "$scope_target" ] || scope_target="org:$GH_OWNER"
    printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$RUNNER_GROUP" "$(pool_label "$pool")" "$pool" \
      "$scope_target" "identity-v1" "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" \
      "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" \
      "$IMAGE_SOURCE" "$IMAGE" "$REGISTRY_SERVER" "$REGISTRY_USERNAME" \
      "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" \
      | sha256sum | cut -c1-12
    return
  fi
  printf '%s\0' "$GH_SCOPE" "$GH_OWNER" "$GH_REPOS" "$RUNNER_GROUP" "$RUNNER_LABELS" \
    "$EPHEMERAL" "$RUNNER_CPUS" "$RUNNER_MEMORY" "$WORK_TMPFS_SIZE" "$CACHE_MOUNTS" \
    "$DIND" "$SHARE_DOCKER_SOCK" "$RUN_AS_ROOT" "$IMAGE_SOURCE" "$IMAGE" \
    "$REGISTRY_SERVER" "$REGISTRY_USERNAME" "$SHARED_IMAGE_CACHE" "$MIRROR_PORT" \
    "$NETWORK_ISOLATION" "$RUNNER_NETWORK" "$CACHE_ROOT" \
    | sha256sum | cut -c1-12
}
# The config fingerprint a running runner was created with ('' for runners created before
# this feature existed — they read as stale and migrate on the next reconcile).
runner_confgen() {
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then inventory_field "$1" confgen
  else docker inspect -f '{{ index .Config.Labels "net.unraid.ci-runner-farm.confgen" }}' "$1" 2>/dev/null; fi
}
# How many RUNNING runners predate the current baked config (drives the drain loop and the
# UI "migrating" indicator).
count_stale_runners() {
  local cur c n=0 pool target
  [ "$INVENTORY_ACTIVE" = 1 ] || fleet_inventory_refresh || return 1
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    runner_identity_validate "$c" || continue
    pool="$(runner_pool "$c")"
    if pool_mode_enabled; then
      pool_record "$pool" >/dev/null 2>&1 || { n=$((n+1)); continue; }
      target="org:$GH_OWNER"
      cur="$(crf_confgen "$pool" "$target")"
    else
      [ "$pool" = default ] || { n=$((n+1)); continue; }
      cur="$(crf_confgen)"
    fi
    [ "$(runner_confgen "$c")" = "$cur" ] || n=$((n+1))
  done
  echo "$n"
}

count_pool_desired_drift() {
  pool_mode_enabled || { echo 0; return; }
  [ "$INVENTORY_ACTIVE" = 1 ] || fleet_inventory_refresh || { echo 0; return 1; }
  local rec pool current target drift=0 delta
  while IFS= read -r rec; do
    pool="${rec%%|*}"; current="$(current_count "$pool")"; target="$(pool_effective_target "$pool")"
    delta=$((current-target)); [ "$delta" -lt 0 ] && delta=$((-delta))
    drift=$((drift+delta))
  done < <(pool_records)
  echo "$drift"
}

count_reconcile_work() {
  local stale drift
  stale="$(count_stale_runners)" || stale=0
  drift="$(count_pool_desired_drift)" || drift=0
  echo $((stale+drift))
}

# Effective autoscale floor: AUTOSCALE_MIN, clamped to AUTOSCALE_MAX so a floor
# misconfigured above the ceiling can never bypass the resource cap.
autoscale_floor() {
  local pool="${1:-default}" f max
  if pool_mode_enabled; then f="$(pool_min "$pool")"; max="$(pool_max "$pool")"
  else f="$AUTOSCALE_MIN"; max="$AUTOSCALE_MAX"; fi
  [ "$f" -gt "$max" ] && f="$max"
  echo "$f"
}

# remove up to $1 IDLE runners (highest index first), never below the effective
# floor (MIN clamped to MAX), never busy ones
scale_down_idle() {
  local want="$1" pool="${2:-default}" removed=0 c floor
  SCALE_REMOVED=0
  floor="$(autoscale_floor "$pool")"
  for c in $(managed_names "$pool" | sort -rV); do
    [ "$removed" -ge "$want" ] && break
    [ "$(current_count "$pool")" -le "$floor" ] && break
    if [ "$(runner_state "$c")" = idle ]; then
      log "autoscale[$pool]: removing idle $c"
      remove_runner "$c" || continue
      removed=$((removed+1))
    fi
  done
  SCALE_REMOVED="$removed"
}

pool_phase_counts() {
  local pool="$1" c phase
  if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
    inventory_state_counts "$pool"
    return
  fi
  POOL_BUSY=0; POOL_IDLE=0; POOL_STARTING=0; POOL_ERROR=0
  for c in $(managed_names "$pool"); do
    phase="$(runner_state "$c")"
    case "$phase" in
      busy) POOL_BUSY=$((POOL_BUSY+1)) ;;
      idle) POOL_IDLE=$((POOL_IDLE+1)) ;;
      starting) POOL_STARTING=$((POOL_STARTING+1)) ;;
      *) POOL_ERROR=$((POOL_ERROR+1)) ;;
    esac
  done
}

# Remove managed runners that can no longer service jobs, so the grow step below
# refills the floor with a freshly registered one. Two failure modes qualify:
#
#   1. exited/dead — crash, OOM, inner-dockerd failure, or a host/Docker restart
#      not yet reconciled. With --restart=no the plugin owns recovery.
#   2. running + Docker health=unhealthy — the runner's GitHub registration was
#      removed out from under it, so its listener loops forever on "Registration
#      was not found / Retrying until reconnected". It never exits, so mode (1)
#      misses it. The runner image's HEALTHCHECK flags exactly this state.
#
# Either way the zombie lingers and — because its last log line isn't "Running
# job" — counts as phantom *idle* capacity in busy_count/idle, suppressing growth
# so the live fleet silently shrinks to zero usable runners while current_count
# still looks full (jobs then queue forever behind zombies). Never reaped: a
# container still starting (state != running, or health=starting within the
# HEALTHCHECK start-period) or one on an image without a healthcheck (health
# empty => treated as fine, so this is a safe no-op until the new image ships).
# Caches/DinD roots persist as bind mounts across the recycle.
reap_dead_runners() {
  local c st health
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    if [ "$INVENTORY_ACTIVE" = 1 ] && [ -f "$INVENTORY_FILE" ]; then
      st="$(inventory_field "$c" state)"; health="$(inventory_field "$c" health)"
    else
      st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
      health="$(docker inspect -f '{{with index .State "Health"}}{{.Status}}{{end}}' "$c" 2>/dev/null)"
    fi
    case "$st" in
      exited|dead)
        log "autoscale: reaping dead runner $c (state=$st)" ;;
      running)
        [ "$health" = "unhealthy" ] || continue
        log "autoscale: reaping unhealthy runner $c (disconnected; health=$health)" ;;
      *) continue ;;
    esac
    remove_runner_force "$c"
  done
}

# one autoscaling evaluation: keep AUTOSCALE_MIN_IDLE warm runners, within [MIN,MAX]
autoscale_tick() {
  [ "$AUTOSCALE" = "true" ] || return 0
  validate_runtime_config || { err "autoscale: $POOL_CONFIG_ERROR"; return 1; }
  cleanup_pool_runtime_state
  fleet_inventory_refresh || { err "autoscale: could not inventory managed runners"; return 1; }
  reap_dead_runners        # drop dead containers first so idle accounting is real
  [ "$INVENTORY_ACTIVE" = 1 ] || fleet_inventory_refresh || return 1
  if pool_mode_enabled; then
    local rec pool cursor=0 offset idx count
    local -a records=()
    mapfile -t records < <(pool_records)
    count="${#records[@]}"
    [ -f "$RUNDIR/autoscale.cursor" ] && cursor="$(cat "$RUNDIR/autoscale.cursor" 2>/dev/null || echo 0)"
    case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
    [ "$count" -gt 0 ] && cursor=$((cursor%count))
    AUTOSCALE_ADD_BUDGET=8
    AUTOSCALE_REMOVE_BUDGET=2
    for ((offset=0; offset<count; offset++)); do
      idx=$(((cursor+offset)%count)); rec="${records[$idx]}"
      pool="${rec%%|*}"
      pool_autoscale_tick "$pool" || log "autoscale[$pool]: tick failed; continuing with other pools"
    done
    [ "$count" -gt 0 ] && printf '%s\n' "$(((cursor+1)%count))" > "$RUNDIR/autoscale.cursor"
    reconcile_stale_runners
    return 0
  fi
  local cur busy idle statef over target
  cur=$(current_count); busy=$(busy_count); idle=$((cur - busy))
  statef="${RUNDIR}/autoscale.state"; over=0
  [ -f "$statef" ] && over=$(cat "$statef" 2>/dev/null || echo 0)

  # runner churn (crash, reap, or ephemeral exit) can drop the fleet below the
  # floor between ticks; the grow branch below only ever adds STEP to the
  # current count, so enforce AUTOSCALE_MIN unconditionally first. Clamp the
  # floor to AUTOSCALE_MAX so a floor misconfigured above the ceiling can
  # never bypass the resource cap.
  local floor
  floor="$(autoscale_floor)"
  if [ "$cur" -lt "$floor" ]; then
    log "autoscale: count $cur < floor $floor -> grow to $floor"
    cmd_scale_internal "$floor" >/dev/null || return 1
    echo 0 > "$statef"
    return 0
  fi

  if [ "$idle" -lt "$AUTOSCALE_MIN_IDLE" ] && [ "$cur" -lt "$AUTOSCALE_MAX" ]; then
    target=$(( cur + AUTOSCALE_STEP )); [ "$target" -gt "$AUTOSCALE_MAX" ] && target=$AUTOSCALE_MAX
    log "autoscale: idle=$idle/$cur < buffer $AUTOSCALE_MIN_IDLE -> grow to $target"
    cmd_scale_internal "$target" >/dev/null || return 1
    echo 0 > "$statef"
  elif [ "$idle" -gt $(( AUTOSCALE_MIN_IDLE + AUTOSCALE_STEP )) ] && [ "$cur" -gt "$floor" ]; then
    over=$(( over + 1 )); echo "$over" > "$statef"
    if [ "$over" -ge "$AUTOSCALE_IDLE_GRACE" ]; then
      log "autoscale: idle=$idle/$cur high for $over checks -> shrink by $AUTOSCALE_STEP"
      scale_down_idle "$AUTOSCALE_STEP"; echo 0 > "$statef"
    fi
  else
    echo 0 > "$statef"
  fi
  # Continuous safety net behind the Apply-triggered drain: migrate one runner still on a
  # previous baked config onto the current one once idle. The narrow exception is a
  # Docker-proven exited/dead/unhealthy runner, which is already failed and may be
  # replaced immediately; log-derived errors never authorize force. This also picks up a
  # direct cfg edit or a runner whose job outlasted the Apply drain timeout.
  # Runs LAST so it never perturbs the scale math above; already under the fleet lock.
  reconcile_stale_runners
}

pool_autoscale_tick() {
  local pool="$1" cur warm statef over=0 target floor max buffer before after delta remove_n removable_idle removable_floor
  cur="$(current_count "$pool")"
  pool_phase_counts "$pool"
  warm=$((POOL_IDLE + POOL_STARTING))
  floor="$(pool_min "$pool")"; max="$(pool_max "$pool")"; buffer="$(pool_idle "$pool")"
  statef="${RUNDIR}/autoscale.${pool}.$(pool_state_generation "$pool").state"
  [ -f "$statef" ] && over="$(cat "$statef" 2>/dev/null || echo 0)"
  case "$over" in ''|*[!0-9]*) over=0 ;; esac

  if [ "$cur" -lt "$floor" ]; then
    [ "${AUTOSCALE_ADD_BUDGET:-8}" -gt 0 ] || return 0
    target="$floor"
    [ "$target" -gt $((cur + AUTOSCALE_ADD_BUDGET)) ] && target=$((cur + AUTOSCALE_ADD_BUDGET))
    log "autoscale[$pool]: count $cur < floor $floor -> grow to $target this tick"
    before="$cur"
    cmd_scale_internal "$pool" "$target" >/dev/null || return 1
    after="$(current_count "$pool")"; delta=$((after-before)); [ "$delta" -lt 0 ] && delta=0
    AUTOSCALE_ADD_BUDGET=$((AUTOSCALE_ADD_BUDGET-delta))
    printf '0\n' > "$statef"
    return 0
  fi
  if [ "$warm" -lt "$buffer" ] && [ "$cur" -lt "$max" ]; then
    [ "${AUTOSCALE_ADD_BUDGET:-8}" -gt 0 ] || return 0
    target=$((cur + AUTOSCALE_STEP)); [ "$target" -gt "$max" ] && target="$max"
    [ "$target" -gt $((cur + AUTOSCALE_ADD_BUDGET)) ] && target=$((cur + AUTOSCALE_ADD_BUDGET))
    log "autoscale[$pool]: warm=$warm/$cur < buffer $buffer -> grow to $target"
    before="$cur"
    cmd_scale_internal "$pool" "$target" >/dev/null || return 1
    after="$(current_count "$pool")"; delta=$((after-before)); [ "$delta" -lt 0 ] && delta=0
    AUTOSCALE_ADD_BUDGET=$((AUTOSCALE_ADD_BUDGET-delta))
    printf '0\n' > "$statef"
  elif [ "$POOL_IDLE" -gt "$buffer" ] && [ "$cur" -gt "$floor" ]; then
    over=$((over+1)); printf '%s\n' "$over" > "$statef"
    if [ "$over" -ge "$AUTOSCALE_IDLE_GRACE" ]; then
      [ "${AUTOSCALE_REMOVE_BUDGET:-2}" -gt 0 ] || return 0
      remove_n="$AUTOSCALE_STEP"
      [ "$remove_n" -gt "$AUTOSCALE_REMOVE_BUDGET" ] && remove_n="$AUTOSCALE_REMOVE_BUDGET"
      removable_idle=$((POOL_IDLE-buffer))
      removable_floor=$((cur-floor))
      [ "$remove_n" -gt "$removable_idle" ] && remove_n="$removable_idle"
      [ "$remove_n" -gt "$removable_floor" ] && remove_n="$removable_floor"
      log "autoscale[$pool]: idle=$POOL_IDLE/$cur high for $over checks -> shrink by $remove_n this tick"
      scale_down_idle "$remove_n" "$pool"
      AUTOSCALE_REMOVE_BUDGET=$((AUTOSCALE_REMOVE_BUDGET-${SCALE_REMOVED:-0}))
      printf '0\n' > "$statef"
    fi
  else
    printf '0\n' > "$statef"
  fi
}

# long-running loop; re-reads config each tick so UI changes apply live
autoscale_daemon() {
  # Disown any inherited fleet-lock fd. This daemon is nohup'd from cmd_start, which
  # runs under `with_fleet_lock wait` (fd 8 flock HELD) — without this the child would
  # inherit that locked fd and hold the fleet lock for its entire life, so (a) its own
  # `with_fleet_lock try` ticks could never re-acquire it (autoscale silently never
  # runs) and (b) every UI start/stop/scale/recycle would block 20s then fail "fleet
  # busy". Closing fd 8 here releases the inherited lock; with_fleet_lock reopens it
  # fresh per tick. (7/9 closed too, defensively, for any future locked spawn path.)
  exec 8>&- 7>&- 9>&- 2>/dev/null || true
  log "autoscale daemon up (min=$AUTOSCALE_MIN max=$AUTOSCALE_MAX buffer=$AUTOSCALE_MIN_IDLE step=$AUTOSCALE_STEP every ${AUTOSCALE_INTERVAL}s)"
  while true; do
    load_cfg
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ "$AUTOSCALE" = "true" ] || { log "autoscale disabled -> daemon exit"; rm -f "$AUTOSCALE_PID"; break; }
    with_fleet_lock try autoscale_tick
    sleep "${AUTOSCALE_INTERVAL:-30}"
  done
}

autoscale_start() {
  [ "$AUTOSCALE" = "true" ] || return 0
  autoscale_stop
  nohup "$0" autoscale-daemon >>"${RUNDIR}/autoscale.log" 2>&1 &
  echo $! > "$AUTOSCALE_PID"
  log "autoscale daemon started (pid $(cat "$AUTOSCALE_PID"))"
}
autoscale_stop() {
  [ -f "$AUTOSCALE_PID" ] && kill "$(cat "$AUTOSCALE_PID")" 2>/dev/null
  rm -f "$AUTOSCALE_PID"
  pkill -f "runner-farm.sh autoscale-daemon" 2>/dev/null || true
}
autoscale_status() {
  if [ -f "$AUTOSCALE_PID" ] && kill -0 "$(cat "$AUTOSCALE_PID" 2>/dev/null)" 2>/dev/null; then
    echo "running (pid $(cat "$AUTOSCALE_PID"))"
  else echo "stopped"; fi
}

# ---- image auto-update -----------------------------------------------------
# Keep the runner image current without operator intervention: a daemon pulls
# the configured image on a schedule and, when its digest moves, recreates each
# runner on the new image — draining (waiting for the current job to finish)
# first so no build is interrupted. Also refreshes the shared pull-through
# mirror image in place. Lifecycle mirrors the autoscale daemon: started by
# cmd_start when IMAGE_AUTOUPDATE=true, self-exits when the flag is turned off.

image_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }

# Pull the runner image (when it's a pullable remote ref) and the mirror image.
# Returns 0 iff the RUNNER image digest moved (that's what triggers a roll; the
# mirror is refreshed in place and never rolls the fleet), 1 otherwise. Uses a
# return code, not stdout, so the log() lines below don't pollute the signal. A
# builtin image is locally built and has no upstream to pull — rebuild it via
# build-image instead.
imageupdate_pull() {
  local changed=1 before after img
  img="$(effective_image)"
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$IMAGE" ]; then
    registry_login
    before="$(image_id "$img")"
    docker pull "$img" >/dev/null 2>&1
    after="$(image_id "$img")"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      changed=0; log "image-update: $img ${before:-none} -> $after"
    fi
  else
    log "image-update: image source is builtin ($img) — nothing to pull; rebuild via build-image to update"
  fi
  # keep the shared pull-through mirror image current too (recreate in place if it moved)
  if [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ]; then
    before="$(image_id registry:2)"
    docker pull registry:2 >/dev/null 2>&1
    after="$(image_id registry:2)"
    if [ -n "$after" ] && [ "$before" != "$after" ]; then
      log "image-update: mirror image registry:2 changed -> recreating $MIRROR_NAME"
      docker rm -f "$MIRROR_NAME" >/dev/null 2>&1; ensure_mirror
    fi
  fi
  return $changed
}

# Drain one runner (wait for its current job to finish), then recreate it on the
# freshly-pulled image. Never interrupts a running job. If it stays busy past
# IMAGE_DRAIN_TIMEOUT, leave it on the old image — the next cycle retries.
drain_and_recreate() {
  local c="$1" waited=0 limit
  limit="${IMAGE_DRAIN_TIMEOUT:-3600}"
  # Wait for the runner to finish its job WITHOUT holding the fleet lock across the
  # (up to IMAGE_DRAIN_TIMEOUT — hours) idle-wait. fd 8 is the fleet mutex, held by our
  # with_fleet_lock caller; we hand it back during each sleep and re-take it only to
  # mutate, so the operator's Stop/Scale/Recycle (and daemon ticks) aren't starved for
  # the whole drain — and Stop can actually abort a runaway rollover.
  while runner_busy "$c"; do
    if [ "$limit" -gt 0 ] && [ "$waited" -ge "$limit" ]; then
      log "image-update: $c still busy after ${limit}s — leaving on old image this cycle"
      return 1
    fi
    flock -u 8 2>/dev/null                 # release the fleet lock while idle-waiting
    sleep 15; waited=$((waited+15))
    flock -w 20 8 2>/dev/null || { log "image-update: fleet busy elsewhere — deferring $c to next cycle"; return 1; }
  done
  # Re-holding the lock here. If the runner vanished while we were unlocked (the
  # operator hit Stop/Recycle mid-drain), do NOT recreate it — never resurrect a
  # runner the operator just removed.
  docker ps -a --format '{{.Names}}' | grep -qx "$c" || { log "image-update: $c no longer present — skipping recreate"; return 0; }
  log "image-update: $c idle -> recreating on new image"
  recreate_runner "$c" graceful >/dev/null
}

# Roll the whole fleet onto the new image, one runner at a time so capacity stays
# up while each drains. Re-reads managed_names each loop (recreated names persist).
imageupdate_rollover() {
  local c
  for c in $(managed_names); do
    [ -n "$c" ] && drain_and_recreate "$c"
  done
  log "image-update: rollover complete ($(managed_names | wc -l) runner(s) on $(effective_image))"
}

# one update evaluation: pull, and roll only if the runner image actually changed
imageupdate_tick() {
  [ "$IMAGE_AUTOUPDATE" = "true" ] || return 0
  validate_runtime_config || { err "image-update: $POOL_CONFIG_ERROR"; return 1; }
  imageupdate_pull || return 0   # nonzero = image unchanged this cycle
  log "image-update: new runner image detected -> draining + recreating fleet"
  imageupdate_rollover
}

# long-running loop; re-reads config each tick so UI changes apply live
imageupdate_daemon() {
  exec 8>&- 7>&- 9>&- 2>/dev/null || true   # disown inherited lock fds (see autoscale_daemon)
  log "image-update daemon up (every ${IMAGE_AUTOUPDATE_INTERVAL}s, drain-timeout ${IMAGE_DRAIN_TIMEOUT}s)"
  while true; do
    load_cfg
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ -z "$REGISTRY_TOKEN" ] && [ -f "$REGISTRY_TOKEN_FILE" ] && REGISTRY_TOKEN="$(cat "$REGISTRY_TOKEN_FILE" 2>/dev/null)"
    [ "$IMAGE_AUTOUPDATE" = "true" ] || { log "image auto-update disabled -> daemon exit"; rm -f "$IMAGEUPDATE_PID"; break; }
    with_fleet_lock try imageupdate_tick
    sleep "${IMAGE_AUTOUPDATE_INTERVAL:-1800}"
  done
}

imageupdate_start() {
  [ "$IMAGE_AUTOUPDATE" = "true" ] || return 0
  imageupdate_stop
  nohup "$0" imageupdate-daemon >>"${RUNDIR}/imageupdate.log" 2>&1 &
  echo $! > "$IMAGEUPDATE_PID"
  log "image-update daemon started (pid $(cat "$IMAGEUPDATE_PID"))"
}
imageupdate_stop() {
  [ -f "$IMAGEUPDATE_PID" ] && kill "$(cat "$IMAGEUPDATE_PID")" 2>/dev/null
  rm -f "$IMAGEUPDATE_PID"
  pkill -f "runner-farm.sh imageupdate-daemon" 2>/dev/null || true
}
imageupdate_status() {
  if [ -f "$IMAGEUPDATE_PID" ] && kill -0 "$(cat "$IMAGEUPDATE_PID" 2>/dev/null)" 2>/dev/null; then
    echo "running (pid $(cat "$IMAGEUPDATE_PID"))"
  else echo "stopped"; fi
}

repo_for_index() {
  # round-robin assign a target repo to runner index (repo scope, multi-repo)
  local idx="$1"
  # shellcheck disable=SC2206  # GH_REPOS is a deliberately space-separated list
  local arr=($GH_REPOS); local n=${#arr[@]}
  [ "$n" -eq 0 ] && { echo ""; return; }
  echo "${arr[$(( (idx-1) % n ))]}"
}

# Inspect CACHE_ROOT and describe any problem that would break the fleet (empty
# output = OK). Split out from check_cache_root so the settings page can surface
# the SAME problems live, before the user clicks Start. Two classes:
#   - root filesystem (rootfs/tmpfs/overlay): RAM-backed, lost on reboot.
#   - FUSE user share (/mnt/user, fuse.shfs) while DinD is on: each runner's
#     Docker data root lands here, and overlay2 cannot run on FUSE, so buildx
#     and 'services:' jobs die with "mount overlay ... invalid argument".
cache_root_problem() {
  local line fstype target
  line=$(df -PT "$CACHE_ROOT" 2>/dev/null | awk 'NR==2')
  fstype=$(echo "$line" | awk '{print $2}')
  target=$(echo "$line" | awk '{print $NF}')
  case "$fstype" in
    rootfs|tmpfs|overlay|"")
      echo "CACHE_ROOT ($CACHE_ROOT) is on '${fstype:-unknown}' — the root filesystem, not a pool. Caches would fill RAM and vanish on reboot. Point it at a pool dataset, e.g. /mnt/<pool>/github-runner."
      return ;;
  esac
  [ "$target" = "/" ] && { echo "CACHE_ROOT ($CACHE_ROOT) resolves to '/'. Point it at a pool dataset, e.g. /mnt/<pool>/github-runner."; return; }
  if [ "$DIND" = "true" ]; then
    case "$fstype" in
      fuse.shfs|fuse*)
        echo "CACHE_ROOT ($CACHE_ROOT) is a /mnt/user share (FUSE/$fstype). With Docker-in-Docker on, each runner's Docker data root lives here and overlay2 cannot run on FUSE — buildx and 'services:' jobs fail with \"mount overlay ... invalid argument\". Point CACHE_ROOT at a pool dataset (e.g. /mnt/<pool>/github-runner), not /mnt/user/..."
        return ;;
    esac
  fi
}

# Hard guard before provisioning (start/scale/validate/boot): print the problem
# and fail. cache_root_problem() carries the detail and remediation.
check_cache_root() {
  # Location guard FIRST: CACHE_ROOT must resolve under /mnt/<pool> and not a system
  # dir or share root. This gates the mkdir/chown -R (ensure_dirs) and the bind mount
  # into every runner (build_args), so a value like /boot or /mnt/user/... — which
  # passes the fs-type check below — is rejected here before it can chown the flash
  # or expose a host path (and the PAT) to untrusted workflow code.
  crf_safe_cache_root >/dev/null 2>&1 || { err "CACHE_ROOT ($CACHE_ROOT) is unsafe — point it at a pool dataset under /mnt/<pool>, not a share root or system dir"; return 1; }
  local p; p="$(cache_root_problem)"
  [ -z "$p" ] && return 0
  err "$p"
  return 1
}

# ---- host-side GitHub runner tokens ----------------------------------------
# The long-lived PAT must NEVER enter a runner container: a job step could read
# it straight out of its own environment (`printenv ACCESS_TOKEN`), and a repo/org
# PAT is far more powerful than the per-job GITHUB_TOKEN. So we keep the PAT here
# on the host (where it already lives) and hand each container only a short-lived
# (~1h), single-purpose runner REGISTRATION token. The base image (myoung34) uses
# RUNNER_TOKEN directly when set and only falls back to minting from ACCESS_TOKEN
# when RUNNER_TOKEN is absent — so passing the token and omitting the PAT works.

# Thin GitHub REST helper: gh_api METHOD PATH -> response body on stdout (empty on
# failure). Requires ACCESS_TOKEN. Used for the token + deregistration calls below.
gh_api() {
  [ -n "$ACCESS_TOKEN" ] || return 1
  # Pass the bearer token via --config on stdin so the PAT never appears in argv
  # (/proc/<pid>/cmdline is world-readable), unlike a -H flag on the command line.
  printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
    | curl -fsSL -m 10 -X "$1" --config - \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2026-03-10" \
      "https://api.github.com$2" 2>/dev/null
}

GH_RESPONSE=""
GH_STATUS=""
gh_api_request() {
  local method="$1" path="$2" body
  [ -n "$ACCESS_TOKEN" ] || { GH_RESPONSE=""; GH_STATUS="000"; return 1; }
  body="$(mktemp 2>/dev/null)" || { GH_RESPONSE=""; GH_STATUS="000"; return 1; }
  GH_STATUS="$(
    printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
      | curl -sS -m 10 -X "$method" --config - -o "$body" -w '%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2026-03-10" \
        "https://api.github.com$path" 2>/dev/null
  )"
  GH_RESPONSE="$(cat "$body" 2>/dev/null)"
  rm -f "$body"
  case "$GH_STATUS" in 2??|404) return 0 ;; *) return 1 ;; esac
}

github_scope_validate() {
  printf '%s' "$1" | grep -qE '^(org:[A-Za-z0-9_.-]+|repo:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$'
}

github_scope_base() {
  github_scope_validate "$1" || return 1
  case "$1" in
    org:*) printf '/orgs/%s\n' "${1#org:}" ;;
    repo:*) printf '/repos/%s\n' "${1#repo:}" ;;
  esac
}

legacy_runner_scope_target() {
  local c="$1" env scope owner repo target
  env="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null)" || return 1
  scope="$(printf '%s\n' "$env" | sed -n 's/^RUNNER_SCOPE=//p' | tail -1)"
  case "$scope" in
    org)
      owner="$(printf '%s\n' "$env" | sed -n 's/^ORG_NAME=//p' | tail -1)"
      target="org:$owner"
      ;;
    repo)
      repo="$(printf '%s\n' "$env" | sed -n 's#^REPO_URL=https://github.com/##p' | tail -1)"
      target="repo:$repo"
      ;;
    *) return 1 ;;
  esac
  github_scope_validate "$target" || return 1
  printf '%s\n' "$target"
}

# Mint and cache one short-lived registration token per exact scope. GitHub
# registration tokens are valid for one hour and may register multiple runners;
# a 45-minute tmpfs cache turns a multi-runner Start into one token request per
# scope instead of one request per container. The cache contains a short-lived,
# registration-only credential (never the PAT) and is mode 0600.
github_registration_token() {
  local target="$1" base key cache age=999999 body token
  github_scope_validate "$target" || return 1
  key="$(printf '%s' "$target" | sha256sum | cut -c1-16)"
  cache="$RUNDIR/registration-token.$key"
  if [ -f "$cache" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 2700 ]; then
      token="$(cat "$cache" 2>/dev/null)"
      case "$token" in ''|*[!A-Za-z0-9_-]*) ;; *) printf '%s\n' "$token"; return 0 ;; esac
    fi
  fi
  base="$(github_scope_base "$target")" || return 1
  body="$(gh_api POST "${base}/actions/runners/registration-token")" || return 1
  token="$(printf '%s' "$body" | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  case "$token" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  ( umask 077; printf '%s\n' "$token" > "$cache.tmp" && mv "$cache.tmp" "$cache" ) || return 1
  printf '%s\n' "$token"
}

# Compatibility name retained for the existing construction path.
registration_token() { github_registration_token "$1"; }

# Fetch and parse the GitHub runner list once per exact scope/mutation batch.
# The result is a strict `id|name` inventory in tmpfs. Parsing through PHP's JSON
# decoder avoids the line-format assumptions of grep/awk and rejects malformed
# or truncated responses. Pagination continues until GitHub returns <100 rows.
github_runner_inventory() {
  local target="$1" base key cache age=999999 page=1 count tmp parsed
  github_scope_validate "$target" || return 1
  key="$(printf '%s' "$target" | sha256sum | cut -c1-16)"
  cache="$RUNDIR/github-runners.$key"
  if [ -f "$cache" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -lt 5 ] && { cat "$cache"; return 0; }
  fi
  base="$(github_scope_base "$target")" || return 1
  tmp="$(mktemp "$RUNDIR/github-runners.XXXXXX")" || return 1
  : > "$tmp"
  while [ "$page" -le 100 ]; do
    gh_api_request GET "${base}/actions/runners?per_page=100&page=${page}" || { rm -f "$tmp"; return 1; }
    parsed="${tmp}.page"
    # shellcheck disable=SC2016 # the single-quoted program is PHP, not shell
    if ! printf '%s' "$GH_RESPONSE" | php -r '
      $j=json_decode(stream_get_contents(STDIN), true);
      if (!is_array($j) || !isset($j["runners"]) || !is_array($j["runners"])) exit(2);
      foreach ($j["runners"] as $r) {
        $id=$r["id"]??null; $name=$r["name"]??null;
        if (is_int($id) && is_string($name) && !str_contains($name, "|") && !preg_match("/[\\x00-\\x1f]/", $name))
          echo $id,"|",$name,"\n";
      }' > "$parsed"; then
      rm -f "$tmp" "$parsed"; return 1
    fi
    count="$(wc -l < "$parsed" | tr -d ' ')"
    cat "$parsed" >> "$tmp"; rm -f "$parsed"
    [ "${count:-0}" -lt 100 ] && break
    page=$((page+1))
  done
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$cache" || { rm -f "$tmp"; return 1; }
  cat "$cache"
}

github_runner_inventory_invalidate() {
  local target="$1" key
  github_scope_validate "$target" || return 1
  key="$(printf '%s' "$target" | sha256sum | cut -c1-16)"
  rm -f "$RUNDIR/github-runners.$key"
}

github_runner_inventory_forget() {
  local target="$1" id="$2" key cache tmp
  github_scope_validate "$target" || return 1
  key="$(printf '%s' "$target" | sha256sum | cut -c1-16)"
  cache="$RUNDIR/github-runners.$key"
  [ -f "$cache" ] || return 0
  tmp="${cache}.tmp.$$"
  if awk -F'|' -v drop="$id" '$1 != drop' "$cache" > "$tmp" &&
     chmod 600 "$tmp" 2>/dev/null && mv "$tmp" "$cache"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

github_runner_id() {
  local target="$1" name="$2"
  github_runner_inventory "$target" | awk -F'|' -v want="$name" '$2 == want { print $1; exit }'
}

# Deregister a runner from GitHub host-side, by name, using the PAT. This replaces
# the base image's in-container SIGTERM deregister (we disable it via
# DISABLE_AUTOMATIC_DEREGISTRATION) — that path re-mints from ACCESS_TOKEN and so
# required the PAT inside the container. Doing it here is both safer (PAT stays on
# the host) and more robust (runs even when the container is hard-killed).
# Best-effort: a busy runner can't be deleted (GitHub 422) and a leftover offline
# entry is harmless — the next Start re-registers the same name with --replace.
deregister_runner_api() {
  local c="$1" rname base id target
  [ -n "$ACCESS_TOKEN" ] && [ -n "$c" ] || return 1
  rname="$(host)-${c}"                          # matches RUNNER_NAME set in build_args
  target="$(runner_scope_target "$c")"
  if [ -z "$target" ]; then
    # Compatibility fallback for old single-mode containers only: recover the
    # ORIGINAL registration target from its baked environment. Never recompute
    # it from today's owner/repository settings after those settings may change.
    [ "$(runner_pool "$c")" = default ] || { err "runner $c lacks a valid stamped scope target"; return 1; }
    target="$(legacy_runner_scope_target "$c")" || {
      err "runner $c has no stamped scope and its original target is ambiguous; leaving it intact"
      return 1
    }
  fi
  base="$(github_scope_base "$target")" || { err "runner $c carries an invalid scope target"; return 1; }
  id="$(github_runner_id "$target" "$rname")" || {
    log "warning: could not list GitHub runners for $target while retiring $c (HTTP ${GH_STATUS:-000})"
    return 1
  }
  [ -n "$id" ] || { log "GitHub runner $rname is already absent from $target"; return 0; }
  if gh_api_request DELETE "${base}/actions/runners/${id}" && {
       [ "$GH_STATUS" = 204 ] || [ "$GH_STATUS" = 404 ];
     }; then
    github_runner_inventory_forget "$target" "$id" || github_runner_inventory_invalidate "$target"
    log "deregistered $rname from GitHub (id $id)"
    return 0
  else
    log "warning: GitHub did not accept retirement of $rname (HTTP ${GH_STATUS:-000}); leaving its container intact"
    return 1
  fi
}

# Fetch one GitHub REST endpoint for EVERY repo in GH_REPOS concurrently, writing each
# repo's raw response body to "$outdir/<n>" (n = 1-based position of the non-empty repo
# in GH_REPOS). The three background refreshers (queued, stats, public-repo) each sweep
# every target repo; doing it serially made refresh latency scale with repo count
# (N x per-call round-trip). Fan-out is chunked — drain every $maxpar — so a large repo
# list can't spawn hundreds of simultaneous curls or trip GitHub's concurrent-request
# secondary limit. Callers re-walk GH_REPOS with the SAME skip-empty rule so file <n>
# lines up with the right repo. Requires $ACCESS_TOKEN in scope.
gh_fetch_all() {
  local suffix="$1" outdir="$2" maxpar="${3:-8}" timeout="${4:-10}"
  local n=0 r
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    n=$((n+1))
    # PAT via --config on stdin so it never lands in argv (/proc/<pid>/cmdline is
    # world-readable and reachable from a broken-out privileged runner) — same
    # hardening as gh_api. printf is a shell builtin (no argv exposure) and the whole
    # printf|curl pipeline is backgrounded as a unit, so each curl gets its own stdin.
    printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
      | curl -s --max-time "$timeout" --config - \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${r}${suffix}" > "$outdir/$n" 2>/dev/null &
    [ $((n % maxpar)) -eq 0 ] && wait
  done
  wait
}

# The single biggest footgun: pointing privileged runners at a PUBLIC repo. A
# fork PR on a public repo runs attacker-controlled code, and here that code runs
# in a --privileged DinD container (or with the host docker.sock mounted) — i.e.
# root on the Unraid box. This asks GitHub, using the PAT, whether any repo-scope
# target is public while privileged, and returns a warning describing it (empty
# = nothing to warn about). It WARNS, never blocks — an operator who knows what
# they're doing (e.g. an internal-only public repo) isn't trapped. Only relevant
# for repo scope; org scope should use a runner group restricted to private repos.
# Result is cached with a TTL (SECURITY_TTL) so the UI's 5s status poll doesn't
# hit the GitHub API on every refresh.
public_repo_problem() {
  [ "$GH_SCOPE" = "repo" ] || { echo ""; return; }
  { [ "$DIND" = "true" ] || [ "$SHARE_DOCKER_SOCK" = "true" ]; } || { echo ""; return; }
  [ -n "$ACCESS_TOKEN" ] || { echo ""; return; }   # can't query without a token
  if [ -f "$SECURITY_CACHE" ]; then
    local age; age=$(( $(date +%s) - $(stat -c %Y "$SECURITY_CACHE" 2>/dev/null || echo 0) ))
    [ "$age" -ge 0 ] && [ "$age" -lt "$SECURITY_TTL" ] && { cat "$SECURITY_CACHE"; return; }
  fi
  local pub="" repo vis tmpd n=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo ""; return; }   # transient temp failure: don't cache, retry next call
  # One concurrent visibility probe per repo (see gh_fetch_all). GitHub's repo API
  # returns "visibility":"public|private|internal"; a 404 (a repo the PAT can't see)
  # returns a JSON error body with no "visibility" field, so it reads as unknown and is
  # not flagged — the same outcome the old per-repo `curl -f` gave.
  gh_fetch_all "" "$tmpd" 8 5
  for repo in $GH_REPOS; do
    [ -n "$repo" ] || continue
    n=$((n+1))
    vis="$(grep -o '"visibility"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmpd/$n" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ "$vis" = "public" ] && pub="$pub ${repo}"
  done
  rm -rf "$tmpd"
  local msg=""
  [ -n "$pub" ] && msg="PUBLIC repo(s) targeted while runners are privileged (DinD / host docker.sock):${pub}. Fork-PR code on a public repo would run as root on this server. Use trusted/private repos only, or an org runner-group restricted to private repos. See the Security section of the plugin README."
  printf '%s' "$msg" > "$SECURITY_CACHE" 2>/dev/null || true
  printf '%s' "$msg"
}

org_runner_group_problem() {
  pool_mode_enabled || return 0
  [ "$GH_SCOPE" = org ] || return 0
  { [ "$DIND" = true ] || [ "$SHARE_DOCKER_SOCK" = true ]; } || return 0
  [ -n "$RUNNER_GROUP" ] && return 0
  echo "Runner pools are privileged and use the organization default runner group. Configure a repository-restricted runner group before allowing untrusted repositories to target these labels."
}

# docker login on the HOST so it can pull a private runner IMAGE (e.g. a private
# GHCR image). No-op unless server+username+token are all configured.
registry_login() {
  [ "$IMAGE_SOURCE" = "remote" ] || return 0
  [ -n "$REGISTRY_SERVER" ] || return 0
  local user="$REGISTRY_USERNAME" pass="$REGISTRY_TOKEN"
  # GHCR fallback: reuse the GitHub PAT (ACCESS_TOKEN) when no dedicated registry
  # token is set, so a private GHCR image pulls without configuring a second
  # token. Requires the PAT to carry the read:packages scope. Username can be
  # anything for GHCR PAT auth; default to the org/owner.
  if [ -z "$pass" ]; then
    case "$REGISTRY_SERVER" in
      ghcr.io|*.ghcr.io) pass="$ACCESS_TOKEN"; [ -z "$user" ] && user="$GH_OWNER" ;;
    esac
  fi
  [ -n "$user" ] && [ -n "$pass" ] || return 0
  if printf '%s' "$pass" | docker login -u "$user" --password-stdin -- "$REGISTRY_SERVER" >/dev/null 2>&1; then
    log "registry: logged in to $REGISTRY_SERVER as $user"
  else
    err "registry: docker login to $REGISTRY_SERVER failed (check server/username/token; GHCR needs read:packages on the PAT)"
    return 1
  fi
}

ensure_dirs() {
  mkdir -p "$CACHE_ROOT/work"
  local m dir
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    dir="$(crf_safe_mount_subdir "${m%%:*}")" || { err "skipping unsafe cache mount '${m%%:*}' — it escapes CACHE_ROOT"; continue; }
    # Only ever chown -R a cache dir WE create here. A pre-existing dir is left
    # untouched: we never recurse ownership into a tree we didn't make — on a shared
    # cache root that could be the operator's own data whose name happens to collide
    # with a cache mount (e.g. a 'docker'/'npm' dir already on the pool). When runners
    # are non-root, a freshly created (empty) dir is handed to RUNNER_UID:RUNNER_GID so
    # the 'runner' user can populate it. (Re-owning an existing cache after a
    # RUN_AS_ROOT flip is a one-time 'prune-cache', not a silent chown -R of live data.)
    [ -d "$dir" ] && continue
    mkdir -p "$dir" || { err "could not create cache dir '$dir'"; continue; }
    [ "$RUN_AS_ROOT" != "true" ] && chown -R "$RUNNER_UID:$RUNNER_GID" "$dir" 2>/dev/null || true
  done
  write_dind_config
}

# Dedicated user-defined bridge for the fleet (created when NETWORK_ISOLATION is
# on). Docker isolates user-defined bridges from each other, so runners here can't
# reach your OTHER Unraid containers. Docker auto-allocates the subnet; strict mode
# reads it back for the egress rules. No-op (and never created) when isolation=off.
ensure_network() {
  [ "$NETWORK_ISOLATION" = "off" ] && return 0
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 && return 0
  log "creating isolated runner network $RUNNER_NETWORK"
  # Label our networks so they're identifiable as plugin-created. (RUNNER_NETWORK
  # defaults to the plugin-specific 'ci-runner-net'; a foreign network deliberately
  # pointed at by a hand-edited RUNNER_NETWORK is not verified here to preserve
  # upgrade compatibility with pre-label networks — see docs on isolation caveats.)
  if ! docker network create --driver bridge --label net.unraid.ci-runner-farm=1 "$RUNNER_NETWORK" >/dev/null; then
    err "could not create network $RUNNER_NETWORK"
    return 1
  fi
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 || {
    err "network $RUNNER_NETWORK is unavailable after creation"
    return 1
  }
}

# Does container $1 sit on the network the CURRENT isolation mode expects? Used to
# detect a mid-flight NETWORK_ISOLATION change (off <-> isolate/strict) so the mirror
# and runners left on the old network get recreated on Start. off => default 'bridge';
# isolate/strict => the dedicated $RUNNER_NETWORK.
on_expected_network() {
  local nets; nets=" $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null) "
  if [ "$NETWORK_ISOLATION" = "off" ]; then
    echo "$nets" | grep -q " bridge "
  else
    echo "$nets" | grep -q " $RUNNER_NETWORK "
  fi
}

# Shared pull-through registry mirror so all DinD runners reuse pulled images
# (docker.io) from one cache on the pool instead of each pulling cold. When network
# isolation is on the mirror joins the dedicated bridge and runners reach it by name
# ($MIRROR_NAME:5000) over that bridge — so it keeps working even in strict mode,
# where host access is blocked. Otherwise it's published on the host ($MIRROR_PORT)
# and reached via host.docker.internal (the legacy path).
ensure_mirror() {
  [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ] || return 0
  mkdir -p "$CACHE_ROOT/registry-mirror"
  # If the mirror is up but on the wrong network for the current mode (operator
  # switched NETWORK_ISOLATION without a full Stop/Start), drop it so it's recreated
  # below on the right network — otherwise runners can't reach it by name and strict's
  # firewall keys off its stale IP. Its cache is on the pool volume, so this is cheap.
  if docker ps -a --format '{{.Names}}' | grep -qx "$MIRROR_NAME" && ! on_expected_network "$MIRROR_NAME"; then
    log "network mode changed -> recreating shared image cache ($MIRROR_NAME)"
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1
    local netargs=()
    if [ "$NETWORK_ISOLATION" != "off" ]; then
      ensure_network
      netargs=( --network "$RUNNER_NETWORK" )
      log "starting shared image cache ($MIRROR_NAME) on $RUNNER_NETWORK"
    else
      # Bind the published mirror to the docker0 bridge gateway (where runners reach
      # it via host.docker.internal:host-gateway) instead of 0.0.0.0 — so it is NOT an
      # open, unauthenticated Docker Hub proxy exposed to the LAN/WAN. Fall back to
      # localhost if the gateway can't be resolved (safe: the mirror is only a cache,
      # so an unreachable one just means direct pulls — never a wildcard bind).
      local gwip; gwip="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
      netargs=( -p "${gwip:-127.0.0.1}:${MIRROR_PORT}:5000" )
      # Pre-flight: a wildcard 0.0.0.0:PORT held by ANY other container/process blocks
      # the publish on every interface (Docker's allocator treats the port as globally
      # taken), so give an actionable error up front instead of a doomed docker run.
      if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${MIRROR_PORT}$"; then
        err "shared image cache: host port ${MIRROR_PORT} is already in use by another service — set MIRROR_PORT to a free port in /boot/config/plugins/ci-runner-farm/ci-runner-farm.cfg, then Restart the fleet"
        return 1
      fi
      log "starting shared image cache ($MIRROR_NAME) on ${gwip:-127.0.0.1}:$MIRROR_PORT"
    fi
    # Capture the real docker error (don't swallow it): "port is already allocated",
    # an image-pull failure, etc. were otherwise lost, leaving only a generic message.
    local mout
    if ! mout="$(docker run -d --restart=unless-stopped --name "$MIRROR_NAME" \
        "${netargs[@]}" \
        -v "$CACHE_ROOT/registry-mirror:/var/lib/registry" \
        -e REGISTRY_PROXY_REMOTEURL="https://registry-1.docker.io" \
        registry:2 2>&1)"; then
      err "could not start $MIRROR_NAME: ${mout##*: }"
      docker rm -f "$MIRROR_NAME" >/dev/null 2>&1   # clear the Created residue so the next cycle retries clean
    fi
  fi
}

# daemon.json the inner dockerd of each DinD runner uses. Pins
# storage-driver=overlay2 — on a pool-backed data root the auto-detector may
# pick the zfs/btrfs driver and fail to start a fresh daemon, whereas overlay2
# runs on any of them (this matches how the Unraid host's own docker is set up).
# Adds the shared pull-through mirror when that's enabled.
write_dind_config() {
  [ "$DIND" = "true" ] || return 0
  local mirror="" ep
  if [ "$SHARED_IMAGE_CACHE" = "true" ]; then
    # Isolated: reach the mirror by container name over the dedicated bridge (works
    # in strict mode, where host access is blocked). Legacy: via the published host
    # port. The inner dockerd shares the runner's netns, so Docker DNS resolves the
    # name for it.
    if [ "$NETWORK_ISOLATION" != "off" ]; then ep="${MIRROR_NAME}:5000"; else ep="host.docker.internal:${MIRROR_PORT}"; fi
    mirror=$(printf ',"registry-mirrors":["http://%s"],"insecure-registries":["%s"]' "$ep" "$ep")
  fi
  printf '{"storage-driver":"overlay2"%s}\n' "$mirror" > "$CACHE_ROOT/dind-daemon.json"
}

# --- strict-mode egress firewall (DOCKER-USER) ------------------------------
# strict isolation blocks runners from reaching the Unraid host and your LAN while
# still allowing the internet (GitHub, package registries) and the shared mirror.
# We drive Docker's DOCKER-USER chain (the supported hook for user rules on
# forwarded container traffic). Rules are scoped to the runner network's subnet, so
# nothing else on the box is affected. firewall_apply attempts the complete rule
# set; strict_firewall_ensure is the enforcement gate that refuses runner creation
# unless every exact subnet-keyed DOCKER-USER and INPUT rule can be verified.

# Remove every rule we previously added (matched by our comment tag), highest line
# number first so deletes don't renumber out from under us. Covers BOTH chains we
# touch: DOCKER-USER (forwarded traffic) and INPUT (traffic to the host's own IPs).
# Idempotent.
firewall_clear() {
  command -v iptables >/dev/null 2>&1 || return 0
  local chain n
  for chain in DOCKER-USER INPUT; do
    for n in $(iptables -w -L "$chain" --line-numbers -n 2>/dev/null \
               | awk -v t="$FW_TAG" 'index($0,t){print $1}' | sort -rn); do
      iptables -w -D "$chain" "$n" 2>/dev/null || true
    done
  done
}

# Install the egress rules for strict mode. Reads the runner network's subnet and
# the mirror's IP back from docker (no pinned subnet -> no collisions). RETURN =
# "leave DOCKER-USER, let Docker's normal ACCEPT handle it"; public destinations
# match none of the DROPs and fall through, so internet egress still works.
firewall_apply() {
  [ "$NETWORK_ISOLATION" = "strict" ] || return 0
  command -v iptables >/dev/null 2>&1 || { err "strict isolation needs iptables — egress NOT restricted"; return 0; }
  docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1 || { err "strict isolation: $RUNNER_NETWORK missing — egress NOT restricted"; return 0; }
  local s gw mip i=1
  s="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  gw="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  [ -n "$s" ] || { err "strict isolation: could not resolve $RUNNER_NETWORK subnet — egress NOT restricted"; return 0; }
  mip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MIRROR_NAME" 2>/dev/null)"
  firewall_clear
  # Order matters (top-down): allow mirror + established replies, THEN drop host +
  # every private range. Inserting at increasing indices keeps them in this order
  # ahead of Docker's trailing RETURN.
  [ -n "$mip" ] && { iptables -w -I DOCKER-USER "$i" -s "$s" -d "$mip" -p tcp --dport 5000 -j RETURN -m comment --comment "$FW_TAG:mirror"; i=$((i+1)); }
  iptables -w -I DOCKER-USER "$i" -d "$s" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:estab"; i=$((i+1))
  [ -n "$gw" ] && { iptables -w -I DOCKER-USER "$i" -s "$s" -d "$gw" -j DROP -m comment --comment "$FW_TAG:host"; i=$((i+1)); }
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 10.0.0.0/8     -j DROP -m comment --comment "$FW_TAG:lan10";  i=$((i+1))
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 172.16.0.0/12  -j DROP -m comment --comment "$FW_TAG:lan172"; i=$((i+1))
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 192.168.0.0/16 -j DROP -m comment --comment "$FW_TAG:lan192"; i=$((i+1))
  iptables -w -I DOCKER-USER "$i" -s "$s" -d 100.64.0.0/10  -j DROP -m comment --comment "$FW_TAG:cgnat"; i=$((i+1))
  # DOCKER-USER is in the FORWARD path only. A runner reaching the Unraid host's OWN
  # ip (e.g. the webGUI on the LAN address, or the host's tailscale ip) is delivered
  # locally via INPUT and never forwarded, so the rules above miss it — that leaves
  # the management UI reachable. Drop new traffic from the runner subnet to the host
  # here too; the runner needs nothing that originates host-side (the mirror is a
  # container = forwarded, DNS is Docker's embedded resolver inside the netns).
  iptables -w -I INPUT 1 -s "$s" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:in-estab"
  iptables -w -I INPUT 2 -s "$s" -j DROP -m comment --comment "$FW_TAG:in-drop"
  log "strict isolation: egress locked to internet+mirror for $s (Unraid host + LAN blocked)"
}

strict_firewall_ensure() {
  [ "$NETWORK_ISOLATION" = strict ] || return 0
  command -v iptables >/dev/null 2>&1 || { err "strict isolation needs iptables"; return 1; }
  local subnet gateway mip
  subnet="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  [ -n "$subnet" ] || { err "strict isolation cannot resolve runner subnet"; return 1; }
  gateway="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' "$RUNNER_NETWORK" 2>/dev/null)"
  mip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$MIRROR_NAME" 2>/dev/null)"
  if ! strict_firewall_rules_valid "$subnet" "$gateway" "$mip"; then
    log "strict isolation: (re)applying stale or missing firewall rules"
    firewall_apply
  fi
  if ! strict_firewall_rules_valid "$subnet" "$gateway" "$mip"; then
    err "strict isolation firewall rules could not be verified"
    return 1
  fi
}

strict_firewall_rules_valid() {
  local subnet="$1" gateway="$2" mirror_ip="$3"
  [ -n "$subnet" ] || return 1
  if [ -n "$mirror_ip" ]; then
    iptables -w -C DOCKER-USER -s "$subnet" -d "$mirror_ip" -p tcp --dport 5000 -j RETURN -m comment --comment "$FW_TAG:mirror" >/dev/null 2>&1 || return 1
  fi
  iptables -w -C DOCKER-USER -d "$subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:estab" >/dev/null 2>&1 || return 1
  if [ -n "$gateway" ]; then
    iptables -w -C DOCKER-USER -s "$subnet" -d "$gateway" -j DROP -m comment --comment "$FW_TAG:host" >/dev/null 2>&1 || return 1
  fi
  iptables -w -C DOCKER-USER -s "$subnet" -d 10.0.0.0/8 -j DROP -m comment --comment "$FW_TAG:lan10" >/dev/null 2>&1 || return 1
  iptables -w -C DOCKER-USER -s "$subnet" -d 172.16.0.0/12 -j DROP -m comment --comment "$FW_TAG:lan172" >/dev/null 2>&1 || return 1
  iptables -w -C DOCKER-USER -s "$subnet" -d 192.168.0.0/16 -j DROP -m comment --comment "$FW_TAG:lan192" >/dev/null 2>&1 || return 1
  iptables -w -C DOCKER-USER -s "$subnet" -d 100.64.0.0/10 -j DROP -m comment --comment "$FW_TAG:cgnat" >/dev/null 2>&1 || return 1
  iptables -w -C INPUT -s "$subnet" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN -m comment --comment "$FW_TAG:in-estab" >/dev/null 2>&1 || return 1
  iptables -w -C INPUT -s "$subnet" -j DROP -m comment --comment "$FW_TAG:in-drop" >/dev/null 2>&1 || return 1
}

# resolve the image to run: the locally-built image (builtin) or a remote ref.
# Falls back to the built-in image if remote is selected but no IMAGE is set.
effective_image() {
  if [ "$IMAGE_SOURCE" = "remote" ] && [ -n "$IMAGE" ]; then echo "$IMAGE"; else echo "$BUILTIN_IMAGE"; fi
}

# build the docker run argv for one runner.
# $1=index, $2=name-override(optional), $3=pool(optional), $4=scope-target(optional)
build_args() {
  local idx="$1" name_override="${2:-}" pool="${3:-default}" scope_target="${4:-}"
  local name labels
  [ -n "$name_override" ] && name="$name_override" || name="$(runner_name_for "$idx" "$pool")"
  if pool_mode_enabled; then
    labels="$(pool_label "$pool")"
    [ -n "$scope_target" ] || scope_target="org:$GH_OWNER"
  else
    labels="$RUNNER_LABELS"
    if [ -z "$scope_target" ]; then
      if [ "$GH_SCOPE" = "org" ]; then scope_target="org:$GH_OWNER"
      else scope_target="repo:$(repo_for_index "$idx")"; fi
    fi
  fi
  ARGS=(
    # --restart=no (NOT unless-stopped): the registration token baked in below is
    # short-lived (~1h) and the runner re-runs config on start, so letting Docker
    # auto-restart a crashed/exited runner makes it re-register with an expired
    # token — GitHub returns 404 ("Not configured") and the container crash-loops.
    # The plugin is the sole supervisor: start_stopped_managed (boot) and
    # reap_dead_runners (autoscale) recreate a dead runner with a freshly minted
    # token instead of resurrecting it with the stale one.
    -d --restart=no
    --name "$name" --hostname "$name"
    --pids-limit=4096
    --label "${MANAGED_LABEL%=*}=true"
    --label "net.unraid.ci-runner-farm.index=${idx}"
    --label "${LABEL_NS}.pool=${pool}"
    --label "${LABEL_NS}.pool-index=${idx}"
    --label "${LABEL_NS}.routing-label=$(pool_mode_enabled && pool_label "$pool" || printf '%s' "$RUNNER_LABELS")"
    --label "${LABEL_NS}.scope-target=${scope_target}"
    --label "${LABEL_NS}.identity-version=1"
    --label "net.unraid.ci-runner-farm.confgen=$(crf_confgen "$pool" "$scope_target")"
    -e RUNNER_NAME="$(host)-${name}"
    -e LABELS="$labels"
    -e DISABLE_AUTO_UPDATE="true"
    -e DISABLE_AUTOMATIC_DEREGISTRATION="true"   # we deregister host-side (deregister_runner_api)
    -e RUN_AS_ROOT="$RUN_AS_ROOT"
    -e RUNNER_ALLOW_RUNASROOT="1"
    -e RUNNER_WORKDIR="/_work"
    -e npm_config_cache="/home/runner/.npm"
  )
  # myoung34 entrypoints enable ephemeral mode when the EPHEMERAL env var is
  # PRESENT (any value, including "false") — so only pass it when it is true,
  # otherwise EPHEMERAL="false" silently produces one-job-then-exit runners.
  [ "$EPHEMERAL" = "true" ] && ARGS+=( -e EPHEMERAL="true" )
  # warm caches mounted into the runner, configurable via CACHE_MOUNTS
  local m
  for m in $CACHE_MOUNTS; do
    [ -n "$m" ] || continue
    local hostdir; hostdir="$(crf_safe_mount_subdir "${m%%:*}")" || { err "skipping unsafe cache mount '${m%%:*}'"; continue; }
    ARGS+=( -v "$hostdir:${m#*:}" )
  done
  [ -n "$RUNNER_CPUS" ]   && ARGS+=( --cpus="$RUNNER_CPUS" )
  [ -n "$RUNNER_MEMORY" ] && ARGS+=( --memory="$RUNNER_MEMORY" )
  # network isolation: put the runner on the dedicated bridge (off = default bridge)
  [ "$NETWORK_ISOLATION" != "off" ] && ARGS+=( --network "$RUNNER_NETWORK" )
  if [ "$DIND" = "true" ]; then
    # each runner runs its own dockerd: isolates service-container ports and
    # makes localhost:<port> reachable from job steps (the runner IS the host).
    ARGS+=( --privileged -e START_DOCKER_SERVICE=true )
    # Give the inner dockerd a real-filesystem data root. Without this it writes
    # /var/lib/docker onto the runner's overlay rootfs, so overlay2 (and buildx's
    # BuildKit) stack overlay-on-overlay and fail with "mount overlay ...
    # invalid argument". CACHE_ROOT must be a pool, not FUSE (check_cache_root).
    mkdir -p "$CACHE_ROOT/docker/$name"
    ARGS+=( -v "$CACHE_ROOT/docker/$name:/var/lib/docker" )
    # inner daemon.json: storage-driver + optional pull-through mirror
    ARGS+=( -v "$CACHE_ROOT/dind-daemon.json:/etc/docker/daemon.json:ro" )
    # Persisted DinD diagnostics dir (kept by remove_runner, unlike the data root):
    # the runner image's wait-docker.sh snapshots inner-daemon state (storage driver,
    # Native Overlay Diff, backing fs, userxattr, uid_map) here and mirrors the inner
    # dockerd log, so a layer-extraction failure (e.g. the whiteout "operation not
    # permitted" mknod seen on ZFS-backed overlay2 under the services: workload) leaves
    # a post-mortem trail off the ephemeral container. Inspect $CACHE_ROOT/dind-logs/<runner>.
    mkdir -p "$CACHE_ROOT/dind-logs/$name"
    ARGS+=( -v "$CACHE_ROOT/dind-logs/$name:/var/log/dind" )
    # Legacy mirror path: reach the host-published mirror via host.docker.internal.
    # Under isolation the mirror is on the dedicated bridge and reached by name, so
    # host-gateway isn't needed (and is blocked in strict) — skip it.
    [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$NETWORK_ISOLATION" = "off" ] && ARGS+=( --add-host "host.docker.internal:host-gateway" )
  elif [ "$SHARE_DOCKER_SOCK" = "true" ]; then
    ARGS+=( -v /var/run/docker.sock:/var/run/docker.sock )
  fi
  if [ -n "$WORK_TMPFS_SIZE" ]; then
    ARGS+=( --tmpfs "/_work:rw,exec,size=${WORK_TMPFS_SIZE}" )
  else
    mkdir -p "$CACHE_ROOT/work/$name"
    ARGS+=( -v "$CACHE_ROOT/work/$name:/_work" )
  fi
  if [ "${scope_target%%:*}" = "org" ]; then
    ARGS+=( -e RUNNER_SCOPE="org" -e ORG_NAME="$GH_OWNER" )
    [ -n "$RUNNER_GROUP" ] && ARGS+=( -e RUNNER_GROUP="$RUNNER_GROUP" )
  else
    local repo="${scope_target#repo:}"
    ARGS+=( -e RUNNER_SCOPE="repo" -e REPO_URL="https://github.com/${repo}" )
  fi
  # Hand the container a short-lived registration token, never the PAT (see the
  # host-side token helpers above). Skipped when no PAT is configured — e.g. the
  # 'validate' path, which swaps the entrypoint for a sleep and never registers.
  if [ -n "$ACCESS_TOKEN" ] && [ "${NO_REGISTER:-0}" != "1" ]; then
    local reg; reg="$(registration_token "$scope_target")"
    [ -z "$reg" ] && { err "could not mint a runner registration token for ${scope_target#*:} (check the PAT's scope/permissions)"; return 1; }
    ARGS+=( -e RUNNER_TOKEN="$reg" )
  fi
  ARGS+=( "$(effective_image)" )
}

start_one() {
  local idx="$1" pool="${2:-default}" scope_target="${3:-}" name
  name="$(runner_name_for "$idx" "$pool")"
  if [ -z "$scope_target" ]; then
    if pool_mode_enabled || [ "$GH_SCOPE" = org ]; then scope_target="org:$GH_OWNER"
    else scope_target="repo:$(repo_for_index "$idx")"; fi
  fi
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    if runner_identity_validate "$name"; then
      log "runner $name already exists; skipping"; return 0
    fi
    err "runner name collision: $name exists but is not a valid managed runner; refusing to touch it"
    return 1
  fi
  build_args "$idx" "$name" "$pool" "$scope_target" || { err "runner $name not started (registration-token error)"; return 1; }
  log "starting $name (pool=$pool cpus=$RUNNER_CPUS mem=$RUNNER_MEMORY scope=${scope_target:-$GH_SCOPE})"
  docker run "${ARGS[@]}" >/dev/null
  local rc=$?
  [ "$rc" -eq 0 ] && github_runner_inventory_invalidate "$scope_target" 2>/dev/null || true
  fleet_inventory_invalidate
  return "$rc"
}

# Recreate a stopped managed runner with a FRESH registration token. We cannot
# `docker start` it in place: the baked-in RUNNER_TOKEN is short-lived (~1h) and
# the runner re-runs config on start, so a stale token yields a GitHub 404
# ("Not configured") and a crash loop. Only the container is removed — the warm
# caches and the DinD data root are bind mounts on the pool (see build_args), so
# they survive under the same name and the replacement starts warm. The stale
# GitHub registration is dropped host-side first (the PAT never touches the
# container) so the fresh runner re-registers cleanly.
recreate_stopped_runner() {
  local c="$1" idx pool scope
  runner_identity_validate "$c" || { err "refusing to recreate invalid managed identity $c"; return 1; }
  idx="$(runner_index "$c")"; pool="$(runner_pool "$c")"
  if pool_mode_enabled; then
    pool_record "$pool" >/dev/null 2>&1 || { log "stopped runner $c belongs to removed pool $pool — retiring instead of recreating"; remove_runner_force "$c"; return; }
  elif [ "$pool" != default ]; then
    log "stopped pool runner $c is obsolete in single mode — retiring instead of recreating"; remove_runner_force "$c"; return
  fi
  deregister_runner_api "$c" || {
    err "runner $c was not recreated because GitHub deregistration was not confirmed"
    return 1
  }
  docker rm -f "$c" >/dev/null 2>&1
  fleet_inventory_invalidate
  if pool_mode_enabled; then scope="org:$GH_OWNER"
  elif [ "$GH_SCOPE" = org ]; then scope="org:$GH_OWNER"
  else scope="repo:$(repo_for_index "$idx")"; fi
  start_one "$idx" "$pool" "$scope"
}

# Bring back managed runner containers that exist but are stopped — e.g. after
# Unraid stopped Docker for an array stop, which leaves them "exited", reconciled
# by the docker_started event hook. Each is recreated with a fresh registration
# token (see recreate_stopped_runner) rather than started in place, because the
# original token has almost certainly expired by the time Docker comes back.
start_stopped_managed() {
  local c st rc=0
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    st="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)"
    [ "$st" = "true" ] && continue
    log "recreating stopped runner $c with a fresh registration token"
    recreate_stopped_runner "$c" || rc=1
  done
  return "$rc"
}

# Cache/network provisioning shared by cmd_start and the Fleet recycle path before
# they run start_one: validate the cache root (hard guard — aborts on FUSE for
# DIND, etc.), create the cache dirs / isolated network / image-cache mirror, and
# log in to a remote registry. Returns non-zero (problem already logged) when the
# cache-root guard OR a real registry login fails, so callers can bail before
# provisioning (registry_login is a no-op returning 0 for the built-in image or
# when no remote registry/creds are set, so it only bites an actually-failed remote
# auth). In strict mode this also verifies that the existing subnet-keyed firewall
# rules still match the live network and mirror, reapplying them only when stale.
# Replacements therefore never start unprotected, while steady-state recycle avoids
# a clear/reapply blackout for the rest of the fleet. cmd_start deliberately performs
# a full clear/reapply through provision_preflight. Manual scale-up and
# reconciliation use this same non-destructive gate before creating capacity.
provision_base() {
  check_cache_root || return 1
  ensure_dirs
  ensure_network || return 1
  ensure_mirror
  registry_login || return 1
  strict_firewall_ensure || return 1
}

# Full Start preflight: the shared base provisioning, then (re)program the strict
# egress firewall (firewall_apply is a no-op unless NETWORK_ISOLATION=strict).
provision_preflight() {
  provision_base || return 1
  firewall_clear                                # drop stale rules (e.g. strict -> off/isolate)
  firewall_apply                                # re-add egress rules (no-op unless strict)
  strict_firewall_ensure || return 1
}

# Serialize all fleet mutation (UI start/stop/restart/scale/recycle AND the autoscale
# / image-update daemon ticks) behind one lock (fd 8), so a manual action and a daemon
# tick can't race into a duplicate docker-run or a false "removed but not recreated"
# (e.g. a "Scale to N" silently reverted by the next autoscale tick). Mode "wait": UI
# commands block briefly. Mode "try": daemon ticks take it non-blocking and simply
# skip a contended tick (retried next interval), so a stuck UI action can never
# deadlock the daemons. Runs the command in a subshell that holds fd 8 for its duration.
with_fleet_lock() {
  local mode="$1"; shift
  if [ "$mode" = try ]; then
    ( flock -n 8 || exit 0; "$@" ) 8>"$RUNDIR/fleet.lock"
  else
    ( flock -w 20 8 || { err "fleet busy (another start/stop/scale/recycle or a daemon tick is running) — try again"; exit 1; }; "$@" ) 8>"$RUNDIR/fleet.lock"
  fi
}
cmd_restart() {
  validate_runtime_config || { err "$POOL_CONFIG_ERROR"; return 1; }
  cmd_stop
  cmd_start
}

# Operator convenience: (re)start the shared image cache + regenerate the runner DinD
# config to match — WITHOUT a full fleet Start/Restart (useful after changing
# SHARED_IMAGE_CACHE / MIRROR_PORT, or to clear a failed mirror). The mirror is a
# separate container so this doesn't disrupt runners; already-running runners pick up
# the new mirror endpoint only when they are next recreated.
cmd_mirror_up() {
  ensure_mirror
  write_dind_config
  if docker ps --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    log "shared image cache ($MIRROR_NAME) is up"
  elif [ "$SHARED_IMAGE_CACHE" = "true" ] && [ "$DIND" = "true" ]; then
    err "shared image cache is not running — see the error above"
  fi
}

# ── Drain-aware config reconciliation ────────────────────────────────────────
# Recycle AT MOST ONE running runner that predates the current baked config onto the new
# one, while it is IDLE or in an ERROR state — a busy runner keeps its in-flight job and is
# caught on a later pass once it finishes, so a settings change never kills a job. One-per-pass so
# the fleet migrates gradually and never drops all its capacity at once. Lock-free: the
# CALLER must hold the fleet lock (cmd_recycle, which this calls, assumes the dispatch or
# caller already locked). Returns 0 always; callers poll count_stale_runners to know when
# the fleet is fully migrated.
reconcile_stale_runners() {
  validate_runtime_config || { err "reconcile: $POOL_CONFIG_ERROR"; return 1; }
  cleanup_pool_runtime_state
  local cur c gen pool scope state docker_state desired rec target
  fleet_inventory_refresh || { err "reconcile: could not inventory managed runners"; return 1; }
  if pool_mode_enabled && [ "$(count_pool_missing_capacity)" -gt 0 ]; then
    provision_base || { err "reconcile: provisioning preflight failed before capacity transition"; return 1; }
  fi
  # Pass 1: retire identities whose pool/mode no longer exists. Invalid-managed
  # rows remain visible but are never adopted or mutated.
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    runner_identity_validate "$c" || { log "reconcile: $c has invalid managed metadata — leaving untouched"; continue; }
    pool="$(runner_pool "$c")"
    desired=true
    if pool_mode_enabled; then
      pool_record "$pool" >/dev/null 2>&1 || desired=false
    else
      [ "$pool" = default ] || desired=false
    fi
    docker_state="$(inventory_field "$c" state)"
    state="$(runner_state "$c")"
    if [ "$desired" = false ]; then
      if [ "$docker_state" != running ]; then
        log "reconcile: retiring stopped runner $c (pool identity no longer desired)"
        remove_runner_force "$c" && start_one_missing_desired
        return 0
      fi
      case "$state" in
        idle)
          log "reconcile: retiring idle runner $c (pool identity no longer desired)"
          if remove_runner "$c"; then start_one_missing_desired
          else log "reconcile: GitHub did not accept retirement of $c — will retry"; fi
          ;;
        error)
          if runner_authoritatively_failed "$c"; then
            log "reconcile: force-retiring authoritatively failed runner $c (pool identity no longer desired)"
            remove_runner_force "$c" && start_one_missing_desired
          else
            log "reconcile: $c has a non-authoritative error signal — preserving it"
          fi
          ;;
        *) log "reconcile: $c is retiring but $state — waiting" ;;
      esac
      return 0
    fi
    if [ "$docker_state" != running ]; then
      log "reconcile: recreating stopped desired runner $c"
      recreate_stopped_runner "$c"
      return 0
    fi
  done

  # Pass 2: honor fixed-mode runtime targets persistently. Highest indexes drain
  # first; a busy excess runner remains until a later worker pass sees it idle.
  if pool_mode_enabled && [ "$AUTOSCALE" != true ]; then
    while IFS= read -r rec; do
      pool="${rec%%|*}"; target="$(pool_effective_target "$pool")"
      [ "$(current_count "$pool")" -gt "$target" ] || continue
      for c in $(managed_names "$pool" | sort -rV); do
        [ "$(current_count "$pool")" -gt "$target" ] || break
        state="$(runner_state "$c")"
        case "$state" in
          idle)
            log "reconcile: draining idle excess runner $c to fixed target $target"
            remove_runner "$c" && return 0
            ;;
          error)
            if runner_authoritatively_failed "$c"; then
              log "reconcile: force-removing authoritatively failed excess runner $c to fixed target $target"
              remove_runner_force "$c" && return 0
            fi
            log "reconcile: $c has a non-authoritative error signal — preserving it"
            ;;
          *) log "reconcile: $c exceeds fixed target but is $state — waiting" ;;
        esac
      done
    done < <(pool_records)
  fi

  # Pass 3: recycle one current-but-stale identity.
  for c in $(managed_names); do
    [ -n "$c" ] || continue
    runner_identity_validate "$c" || continue
    pool="$(runner_pool "$c")"
    if pool_mode_enabled; then pool_record "$pool" >/dev/null 2>&1 || continue
    else [ "$pool" = default ] || continue; fi
    state="$(runner_state "$c")"
    if pool_mode_enabled; then
      scope="org:$GH_OWNER"
      cur="$(crf_confgen "$pool" "$scope")"
    else
      cur="$(crf_confgen)"
    fi
    gen="$(runner_confgen "$c")"
    [ "$gen" = "$cur" ] && continue                  # already on the current config
    # Migrate idle runners; also migrate error-state ones (a wedged runner will never
    # reach idle on its own, so leaving it would strand it on the old config forever).
    # Busy/starting runners are left for a later pass.
    case "$state" in
      idle) ;;
      error) runner_authoritatively_failed "$c" || continue ;;
      *) continue ;;
    esac
    log "reconcile: $c predates a config change — recycling it onto the current config"
    local recycle_mode=graceful
    [ "$state" = error ] && recycle_mode=force
    if ! recreate_runner "$c" "$recycle_mode" >/dev/null 2>&1; then
      if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
        log "reconcile: recycle of $c failed but it is still present — will retry next pass"
      else
        # cmd_recycle removed it but the replacement failed to start: the fleet just
        # shrank and no later pass can retry a runner that no longer exists. Record it
        # so the drain reports the loss instead of a clean-migration success.
        log "reconcile: $c was removed but its replacement failed to start — fleet is down one runner"
        echo "$c" >> "$RUNDIR/reconcile.shrink"
      fi
    fi
    return 0                                          # one per pass; the drain/tick loop re-invokes
  done
  start_one_missing_desired
  return 0
}

# Detached worker behind the Settings "Apply" button: migrate every stale runner onto the
# new config as each goes idle, except Docker-proven exited/dead/unhealthy runners may be
# replaced immediately because no job can still be running there. Re-reads the cfg each
# pass so an Apply made mid-drain retargets the SAME drain (the flock in the dispatch keeps
# it to one). Gives up after IMAGE_DRAIN_TIMEOUT on runners whose job outlasts it — they
# migrate on their next idle via the autoscale tick, or on the next Apply/recycle. Progress
# is logged to autoscale.log, which the farm-log panel tails.
cmd_reconcile_drain() {
  # Disown an inherited fleet-lock fd (this can be nohup'd from cmd_start, which holds
  # fd 8) so our own `with_fleet_lock wait` below isn't self-blocked. Keep fd 7 — the
  # dispatch wrapper holds it as this drain's own reconcile.lock. See autoscale_daemon.
  exec 8>&- 9>&- 2>/dev/null || true
  local deadline announced=0 lost backoff_announced=0 sleep_for=15
  rm -f "$RUNDIR/reconcile.shrink"                  # fresh tally of runners lost this drain (see reconcile_stale_runners)
  deadline=$(( $(date +%s) + ${IMAGE_DRAIN_TIMEOUT:-3600} ))
  while :; do
    load_cfg
    [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
    [ "$(count_reconcile_work)" -eq 0 ] && break
    [ "$announced" = 0 ] && { log "reconcile: config changed — migrating runners onto it as they go idle"; announced=1; }
    with_fleet_lock wait reconcile_stale_runners
    [ "$(count_reconcile_work)" -eq 0 ] && break
    # IMAGE_DRAIN_TIMEOUT=0 means "wait forever" (per the settings help), so only enforce
    # the deadline when it's positive — matching drain_and_recreate's `limit -gt 0` guard.
    # Retiring identities (removed pools or mode transitions) must eventually
    # disappear even when autoscale is off. Ordinary stale config migration may
    # honor the drain timeout, but a retiring runner keeps this worker alive.
    local retiring=0 c p durable missing
    for c in $(managed_names); do
      p="$(runner_pool "$c")"
      if pool_mode_enabled; then pool_record "$p" >/dev/null 2>&1 || retiring=$((retiring+1))
      else [ "$p" = default ] || retiring=$((retiring+1)); fi
    done
    durable=$((retiring + $(count_pool_desired_drift)))
    missing="$(count_pool_missing_capacity)"
    if [ "${IMAGE_DRAIN_TIMEOUT:-3600}" -gt 0 ] && [ "$(date +%s)" -ge "$deadline" ]; then
      if [ "$retiring" -gt 0 ] || [ "$durable" -gt "$missing" ]; then
        if [ "$backoff_announced" -eq 0 ]; then
          log "reconcile: $durable durable transition(s) remain blocked after the drain timeout — runners are preserved and retries continue every 120s"
          backoff_announced=1
        fi
        sleep_for=120
      elif [ "$missing" -gt 0 ]; then
        log "reconcile: capacity is still short by $missing runner(s) after the retry deadline — fix provisioning, then retry the pool Scale target (or use Start to reset to configured capacity)"
        break
      else
        log "reconcile: $(count_stale_runners) runner(s) still on the old config after the drain timeout — they'll migrate on their next Apply/Start"
        break
      fi
    fi
    sleep "$sleep_for"
  done
  lost="$([ -f "$RUNDIR/reconcile.shrink" ] && grep -c . "$RUNDIR/reconcile.shrink" 2>/dev/null || echo 0)"
  if [ "$announced" = 1 ]; then
    if [ "${lost:-0}" -gt 0 ]; then
      if [ "$(count_reconcile_work)" -eq 0 ]; then
        log "reconcile: migration finished but $lost runner(s) were removed without a replacement — Start/Restart the fleet to restore capacity"
      else
        log "reconcile: migration incomplete, and $lost runner(s) were also removed without a replacement — Start/Restart the fleet to restore capacity"
      fi
    elif [ "$(count_reconcile_work)" -eq 0 ]; then
      log "reconcile: fleet is now on the current config"
    fi
  fi
  rm -f "$RUNDIR/reconcile.shrink"
  rm -f "$RECONCILE_PID"
}

reconcile_start() {
  if [ -f "$RECONCILE_PID" ] && kill -0 "$(cat "$RECONCILE_PID" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  nohup "$0" reconcile-drain >>"$RUNDIR/autoscale.log" 2>&1 8>&- 9>&- &
  printf '%s\n' "$!" > "$RECONCILE_PID"
}

reconcile_stop() {
  [ -f "$RECONCILE_PID" ] && kill "$(cat "$RECONCILE_PID" 2>/dev/null)" 2>/dev/null || true
  rm -f "$RECONCILE_PID"
  pkill -f '[r]unner-farm.sh reconcile-drain' 2>/dev/null || true
}

# Kick off the drain detached so the Settings Apply returns immediately (recycling is
# slow). Safe no-op when nothing is stale (the drain exits on the first count). Output
# shows in the Apply progress frame — human text, not JSON.
cmd_reconcile_config() {
  validate_runtime_config || { err "$POOL_CONFIG_ERROR"; return 1; }
  rm -f "$RUNDIR"/scale-override.* 2>/dev/null || true
  rm -f "$RUNDIR"/autoscale.*.state 2>/dev/null || true
  reconcile_start
  local msg="Configuration saved. Any runner on a previous config will migrate as it goes idle (busy jobs finish first)."
  # A NETWORK_ISOLATION change applies per-runner only as each recycles — so running
  # jobs keep their OLD network until they finish. Say so plainly: a gradual, background
  # migration of a security-isolation setting can otherwise read as immediate enforcement.
  [ "$NETWORK_ISOLATION" != off ] && msg="$msg  NOTE: network isolation ($NETWORK_ISOLATION) takes effect on each runner only as it recycles — running jobs keep their current network until they finish. Restart the fleet to enforce it on every runner immediately."
  echo "$msg"
}

pool_effective_target() {
  local pool="$1" configured file value
  configured="$(pool_configured_target "$pool")"
  [ "$AUTOSCALE" = true ] && { printf '%s\n' "$configured"; return; }
  file="$RUNDIR/scale-override.${pool}.$(pool_state_generation "$pool")"
  if [ -f "$file" ]; then
    value="$(cat "$file" 2>/dev/null)"
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return ;; esac
  fi
  printf '%s\n' "$configured"
}

pool_configured_total() {
  local rec pool total=0
  if pool_mode_enabled; then
    while IFS= read -r rec; do pool="${rec%%|*}"; total=$((total + $(pool_configured_target "$pool"))); done < <(pool_records)
  else
    total="$RUNNER_COUNT"; [ "$AUTOSCALE" = true ] && total="$AUTOSCALE_MIN"
  fi
  printf '%s\n' "$total"
}

pool_effective_total() {
  local rec pool total=0
  if pool_mode_enabled; then
    while IFS= read -r rec; do
      pool="${rec%%|*}"
      total=$((total + $(pool_effective_target "$pool")))
    done < <(pool_records)
  else
    total="$RUNNER_COUNT"; [ "$AUTOSCALE" = true ] && total="$AUTOSCALE_MIN"
  fi
  printf '%s\n' "$total"
}

count_pool_missing_capacity() {
  pool_mode_enabled || { echo 0; return; }
  [ "$INVENTORY_ACTIVE" = 1 ] || fleet_inventory_refresh || { echo 0; return 1; }
  local rec pool current target missing=0
  while IFS= read -r rec; do
    pool="${rec%%|*}"; current="$(current_count "$pool")"; target="$(pool_effective_target "$pool")"
    [ "$current" -lt "$target" ] && missing=$((missing + target - current))
  done < <(pool_records)
  echo "$missing"
}

start_one_missing_desired() {
  local ceiling current rec pool target idx name
  ceiling="$(pool_effective_total)"; current="$(current_count)"
  [ "$current" -lt "$ceiling" ] || return 0
  provision_base || { err "reconcile: provisioning preflight failed; capacity healing deferred"; return 1; }
  if ! pool_mode_enabled; then
    target="$RUNNER_COUNT"; [ "$AUTOSCALE" = true ] && target="$AUTOSCALE_MIN"
    [ "$(current_count default)" -lt "$target" ] || return 0
    for idx in $(seq 1 "$target"); do
      name="$(runner_name_for "$idx" default)"
      if ! docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        start_one "$idx" default
        return $?
      fi
    done
    return 0
  fi
  while IFS= read -r rec; do
    pool="${rec%%|*}"; target="$(pool_effective_target "$pool")"
    [ "$(current_count "$pool")" -lt "$target" ] || continue
    for idx in $(seq 1 64); do
      name="$(runner_name_for "$idx" "$pool")"
      if ! docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        start_one "$idx" "$pool"
        return $?
      fi
    done
  done < <(pool_records)
}

cmd_start() {
  validate_runtime_config || { err "$POOL_CONFIG_ERROR"; return 1; }
  [ -z "$ACCESS_TOKEN" ] && { err "no GitHub token configured (set it in the web UI). Use 'validate' to test provisioning without one."; return 1; }
  rm -f "$RUNDIR"/scale-override.* 2>/dev/null || true
  rm -f "$SECURITY_CACHE"                       # force a fresh public-repo check on an explicit Start
  local secp orgp; secp="$(public_repo_problem)"; orgp="$(org_runner_group_problem)"
  [ -n "$secp" ] && err "SECURITY: $secp"       # warn, do not block (operator's call)
  [ -n "$orgp" ] && err "SECURITY: $orgp"
  provision_preflight || return 1               # cache-root guard + dirs/network/mirror/firewall/registry
  # If NETWORK_ISOLATION changed while the fleet was up, existing runners are still
  # on the old network — they must be recreated so the new mode actually applies (a
  # half-isolated fleet is a false sense of security). Do this in the BACKGROUND: a
  # network change bumps the confgen fingerprint, so the detached reconcile drain
  # migrates each stale runner onto the new network as it goes idle (running jobs
  # finish first), exactly like a Settings Apply. Draining inline here would block
  # this synchronous Start request under the fleet lock for up to IMAGE_DRAIN_TIMEOUT
  # (hours) while a busy runner finishes. Runners already on the right network match
  # and are left untouched, so a normal Start migrates nothing.
  local c need_migrate=0
  for c in $(managed_names); do
    [ -n "$c" ] && ! on_expected_network "$c" && { need_migrate=1; break; }
  done
  [ "$need_migrate" = 1 ] && { log "network mode changed -> migrating runners onto the new network in the background as they go idle"; reconcile_start; }
  local start_rc=0
  # bring back any runners Unraid/Docker left exited (array stop, daemon restart)
  start_stopped_managed || start_rc=1
  # With autoscaling on, start each floor and let the daemon grow independently.
  local startn="$RUNNER_COUNT" i rec pool ceiling initial
  if pool_mode_enabled; then
    initial="$(current_count)"; ceiling="$(pool_configured_total)"
    [ "$initial" -gt "$ceiling" ] && ceiling="$initial"
    [ "$ceiling" -gt 64 ] && ceiling=64
    while IFS= read -r rec; do
      pool="${rec%%|*}"; startn="$(pool_configured_target "$pool")"
      for i in $(seq 1 "$startn"); do
        [ "$(current_count)" -lt "$ceiling" ] || break
        start_one "$i" "$pool" || start_rc=1
      done
    done < <(pool_records)
    reconcile_start
  else
    [ "$AUTOSCALE" = "true" ] && startn="$AUTOSCALE_MIN"
    initial="$(current_count)"; ceiling="$startn"
    [ "$initial" -gt "$ceiling" ] && ceiling="$initial"
    [ "$ceiling" -gt 64 ] && ceiling=64
    for i in $(seq 1 "$startn"); do
      [ "$(current_count)" -lt "$ceiling" ] || break
      start_one "$i" || start_rc=1
    done
    reconcile_start
  fi
  log "fleet up: $(managed_names | wc -l) runner(s)"
  [ "$AUTOSCALE" = "true" ] && autoscale_start || true
  [ "$IMAGE_AUTOUPDATE" = "true" ] && imageupdate_start || true
  [ "$start_rc" -eq 0 ] || err "fleet started with partial capacity; see errors above and retry Start"
  return "$start_rc"
}

safe_remove_runner_cache() {
  local c="$1" root
  runner_identity_validate "$c" || { log "warning: preserving cache for invalid runner identity $c"; return 1; }
  root="$(crf_safe_cache_root)" || { log "warning: preserving cache for $c because CACHE_ROOT is unsafe"; return 1; }
  case "$c" in "$NAME_PREFIX"-*) ;; *) return 1 ;; esac
  rm -rf -- "${root:?}/docker/${c:?}" 2>/dev/null || true
}

remove_runner_container() {
  local c="$1" root=""
  if runner_identity_validate "$c"; then
    root="$(crf_safe_cache_root 2>/dev/null || true)"
  fi
  docker stop -t 30 "$c" >/dev/null 2>&1
  docker rm "$c" >/dev/null 2>&1
  fleet_inventory_invalidate
  if [ -n "$root" ]; then
    rm -rf -- "${root:?}/docker/${c:?}" 2>/dev/null || true
  else
    log "warning: preserving cache for $c because its identity or CACHE_ROOT could not be proven safe"
  fi
}

# Graceful controller removal: GitHub must first accept the deletion (or report
# the runner absent). Ambiguous API failures leave the idle container intact so a
# newly assigned job can never be interrupted by autoscale/reconciliation.
remove_runner() {
  local c="$1"
  [ -n "$c" ] || return 0
  runner_identity_validate "$c" || { err "refusing to remove invalid/unmanaged runner $c"; return 1; }
  [ "$(runner_state "$c")" = idle ] || { log "runner $c is not explicitly idle; deferring removal"; return 1; }
  deregister_runner_api "$c" || return 1
  remove_runner_container "$c"
}

# Explicit teardown path for Stop, dead containers, and confirmed manual recycle.
remove_runner_force() {
  local c="$1"
  [ -n "$c" ] || return 0
  runner_identity_validate "$c" || { err "refusing to force-remove invalid/unmanaged runner $c"; return 1; }
  deregister_runner_api "$c" || log "warning: forcing removal of $c after GitHub deregistration failed"
  remove_runner_container "$c"
}

# Full teardown: daemons, runner containers, and the shared pull-through mirror.
# Reached from the UI Stop button AND from plugin uninstall (the .plg remove step
# calls 'stop'), so it must leave nothing running. The mirror's on-pool cache dir
# ($CACHE_ROOT/registry-mirror) is intentionally left behind — like the config and
# token — so a later Start rebuilds the container with its cache warm; only the
# container is removed here, not the cached layers.
cmd_stop() {
  autoscale_stop
  imageupdate_stop
  reconcile_stop
  local names; names="$(managed_names)"
  if [ -z "$names" ]; then
    log "no managed runners running"
  else
    echo "$names" | while read -r c; do [ -n "$c" ] && { log "stopping $c (forced operator teardown)"; remove_runner_force "$c"; }; done
  fi
  # drop the shared image-cache container so uninstall/Stop don't orphan it
  if docker ps -a --format '{{.Names}}' | grep -qx "$MIRROR_NAME"; then
    log "removing shared image cache ($MIRROR_NAME)"
    docker rm -f "$MIRROR_NAME" >/dev/null 2>&1 || true
  fi
  # tear down the strict-mode egress rules and the now-empty dedicated network
  firewall_clear
  if [ "$NETWORK_ISOLATION" != "off" ] && docker network inspect "$RUNNER_NETWORK" >/dev/null 2>&1; then
    log "removing isolated runner network ($RUNNER_NETWORK)"
    docker network rm "$RUNNER_NETWORK" >/dev/null 2>&1 || true
  fi
}

cmd_scale_internal() {
  local pool="default" target
  if [ "$#" -ge 2 ]; then pool="$1"; target="$2"; else target="$1"; fi
  # Server-side validate + clamp. The form's max="20" is presentation-only, so a
  # crafted POST (n=99999) would otherwise drive an unbounded provisioning loop —
  # a container + a minted GitHub registration token per iteration (host / API
  # exhaustion). The autoscale path is already bounded by AUTOSCALE_MAX; bound the
  # manual path with a hard ceiling too.
  case "$target" in ''|*[!0-9]*) err "scale target must be a non-negative integer"; return 1 ;; esac
  local HARD_MAX=64
  [ "$target" -gt "$HARD_MAX" ] && { log "scale: clamping requested $target to hard max $HARD_MAX"; target=$HARD_MAX; }
  # Every scale path uses the same provisioning gate as Start/reconcile. In
  # particular, growth must never create a strict-network runner before the live
  # firewall rules are verified, or ignore a registry/network setup failure.
  provision_base || { err "refusing to scale: provisioning preflight failed"; return 1; }
  if pool_mode_enabled; then
    pool_record "$pool" >/dev/null 2>&1 || { err "unknown runner pool '$pool'"; return 1; }
  else
    pool="default"
  fi
  fleet_inventory_refresh || { err "scale: could not inventory managed runners"; return 1; }
  local current initial; current="$(current_count "$pool")"; initial="$current"
  if [ "$target" -gt "$current" ]; then
    [ -z "$ACCESS_TOKEN" ] && { err "no token configured"; return 1; }
    check_cache_root || return 1
    local i name total
    for i in $(seq 1 "$HARD_MAX"); do
      [ "$(current_count "$pool")" -ge "$target" ] && break
      total="$(current_count)"
      [ "$total" -lt "$HARD_MAX" ] || { err "scale: fleet hard cap reached with retiring/other pool runners still present"; break; }
      name="$(runner_name_for "$i" "$pool")"
      if ! docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        start_one "$i" "$pool" || { err "scale: failed to start $name"; break; }
      fi
    done
  elif [ "$target" -lt "$current" ]; then
    local c
    for c in $(managed_names "$pool" | sort -rV); do
      [ "$(current_count "$pool")" -le "$target" ] && break
      if [ "$(runner_state "$c")" = idle ]; then
        remove_runner "$c" && log "removed $c"
      else
        log "scale: $c is not idle; leaving it to finish before a later reconcile"
      fi
    done
  fi
  log "scaled pool $pool to $(current_count "$pool") runner(s) (target $target)"
  if [ "$target" -gt "$initial" ] && [ "$(current_count "$pool")" -lt "$target" ]; then
    err "scale: growth stopped before reaching target $target"
    return 1
  fi
}

cmd_scale() {
  # The autoscaler uses cmd_scale_internal above. A manual scale-up is useful
  # during a burst, but never bypass its configured ceiling or remove runners
  # that the autoscaler is managing.
  validate_runtime_config || { err "$POOL_CONFIG_ERROR"; return 1; }
  local pool="default" target
  if pool_mode_enabled; then
    [ "$#" -eq 2 ] || { err "usage: scale <pool> <target>"; return 1; }
    pool="$1"; target="$2"
    pool_record "$pool" >/dev/null 2>&1 || { err "unknown runner pool '$pool'"; return 1; }
  else
    target="$1"
  fi
  case "$target" in ''|*[!0-9]*) err "scale target must be a non-negative integer"; return 1 ;; esac
  pool_mode_enabled && [ "$target" -eq 0 ] && { err "runner pools cannot scale to zero"; return 1; }
  [ "$target" -le 64 ] || { err "manual scale target ($target) exceeds the fleet hard maximum (64)"; return 1; }
  if [ "$AUTOSCALE" = "true" ]; then
    local current max
    if pool_mode_enabled; then max="$(pool_max "$pool")"; else max="$AUTOSCALE_MAX"; fi
    case "$max" in ''|*[!0-9]*) max=16 ;; esac
    current="$(current_count "$pool")"
    [ "$target" -gt "$current" ] || { err "manual scale with Autoscaling on can only add runners (currently $current)"; return 1; }
    [ "$target" -le "$max" ] || { err "manual scale target ($target) exceeds autoscale max ($max); raise it in Settings first"; return 1; }
    rm -f "$RUNDIR"/autoscale."$pool".*.state 2>/dev/null || true
  elif pool_mode_enabled; then
    local rec other aggregate="$target" override tmp
    while IFS= read -r rec; do
      other="${rec%%|*}"; [ "$other" = "$pool" ] && continue
      aggregate=$((aggregate + $(pool_effective_target "$other")))
    done < <(pool_records)
    [ "$aggregate" -le 64 ] || { err "manual pool targets would exceed the fleet hard maximum (64)"; return 1; }
    override="$RUNDIR/scale-override.${pool}.$(pool_state_generation "$pool")"
    tmp="${override}.tmp.$$"
    printf '%s\n' "$target" > "$tmp" && mv "$tmp" "$override"
  fi
  local rc=0 actual
  if pool_mode_enabled; then cmd_scale_internal "$pool" "$target" || rc=$?
  else cmd_scale_internal "$target" || rc=$?; fi
  if pool_mode_enabled && [ "$AUTOSCALE" != true ] && [ "$(current_count "$pool")" -ne "$target" ]; then
    log "scale: pool $pool has pending capacity work; reconciliation will continue as runners become idle"
    reconcile_start
  fi
  actual="$(current_count "$pool")"
  if pool_mode_enabled && [ "$actual" -ne "$target" ]; then
    log "scale target set: pool=$pool actual=$actual target=$target pending=true"
  fi
  return "$rc"
}

cmd_status() {
  local names; names="$(managed_names)"
  printf "%-22s %-10s %-8s %-10s %s\n" "NAME" "STATE" "PHASE" "CPU/MEM" "IMAGE"
  [ -z "$names" ] && { echo "(no managed runners)"; return 0; }
  echo "$names" | while read -r c; do
    [ -z "$c" ] && continue
    local st; st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
    local cpus mem; cpus="$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$c" 2>/dev/null)"
    mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$c" 2>/dev/null)"
    printf "%-22s %-10s %-8s %-10s %s\n" "$c" "$st" "$(runner_state "$c")" "$((cpus/1000000000))c/$((mem/1024/1024/1024))g" "$(effective_image)"
  done
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037'; }
# JSON-encode stdin as a string literal (with surrounding quotes), preserving newlines
# as \n — for multi-line log payloads where json_escape's control-char stripping would
# collapse the log into one line.
json_string() {
  local str; str="$(cat)"
  str="${str//\\/\\\\}"; str="${str//\"/\\\"}"
  str="${str//$'\t'/\\t}"; str="${str//$'\r'/\\r}"; str="${str//$'\n'/\\n}"
  str="$(printf '%s' "$str" | tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$str"
}

cmd_image_info_json() {
  # Image facts for the settings page's Runner image tab: existence, id, age,
  # size, base image, and how many managed runners currently run on it.
  local img; img="$(effective_image)"
  local id; id="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)"
  if [ -z "$id" ]; then
    echo "{\"exists\":false,\"image\":\"$(echo "$img"|json_escape)\",\"source\":\"$(echo "$IMAGE_SOURCE"|json_escape)\"}"
    return 0
  fi
  local created size; created="$(docker image inspect -f '{{.Created}}' "$img")"
  size="$(docker image inspect -f '{{.Size}}' "$img")"
  local df="$CFGDIR/Dockerfile"
  [ -f "$df" ] || df="/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile"
  local base; base="$(grep -m1 '^FROM ' "$df" 2>/dev/null | awk '{print $2}')"
  local inuse=0 c cid
  for c in $(managed_names); do
    cid="$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null)"
    [ "$cid" = "$id" ] && inuse=$((inuse+1))
  done
  echo "{\"exists\":true,\"image\":\"$(echo "$img"|json_escape)\",\"id\":\"$(echo "$id" | cut -c8-19)\",\"created\":\"$created\",\"size_mb\":$(( ${size:-0}/1024/1024 )),\"base\":\"$(echo "$base"|json_escape)\",\"in_use\":$inuse,\"dockerfile\":\"$(echo "$df"|json_escape)\",\"source\":\"$(echo "$IMAGE_SOURCE"|json_escape)\"}"
}

# "1.5GiB" / "512MiB" / "900kB" -> integer MiB (docker stats human units)
to_mib() {
  echo "$1" | awk '{
    v=$0; sub(/[A-Za-z]+$/,"",v); u=$0; sub(/^[0-9.]+/,"",u);
    if (u ~ /^G/) v*=1024; else if (u ~ /^k/ || u ~ /^K/) v/=1024; else if (u ~ /^B/) v/=1048576;
    printf "%d", v }'
}

cmd_queued_refresh() {
  # Sum queued workflow runs across GH_REPOS into a cache file. Invoked in the
  # background from cmd_queued_json so the UI poll never blocks on 20+ curls.
  [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "$(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  local total=0 got=0 r n body tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "$(date +%s) -1" > "$RUNDIR/queued.cache"; return 0; }
  gh_fetch_all "/actions/runs?status=queued&per_page=1" "$tmpd"
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    i=$((i+1)); body="$(cat "$tmpd/$i" 2>/dev/null)"
    case "$body" in *'"total_count"'*) got=1 ;; esac
    n="$(printf '%s' "$body" | grep -m1 -oE '"total_count":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
    total=$(( total + ${n:-0} ))
  done
  rm -rf "$tmpd"
  # total=-1 signals "unavailable" (no token / every repo query failed) so the UI
  # shows a dash instead of a confident "0 queued" — same sentinel as stats/usage.
  [ "$got" = "1" ] || total=-1
  echo "$(date +%s) $total" > "$RUNDIR/queued.cache"
}

# Warm dependency caches under CACHE_ROOT — safe to clear even while runners are
# up (worst case is a cache miss, not a broken job). Deliberately EXCLUDES work/
# and docker/, which hold running runners' live workspaces and DinD data.
CACHE_PKG_DIRS="cargo-registry cargo-git sccache npm yarn pnpm-store ms-playwright"

# Resolve + validate CACHE_ROOT for destructive/expensive ops (rm -rf in
# cmd_prune_cache / cmd_cache_clear_pkg, chown -R in ensure_dirs). realpath -m
# collapses ../ . and trailing slashes lexically (target need not exist) so the guard
# checks the REAL location, not the raw string. CACHE_ROOT must be a dedicated
# SUBDIRECTORY under a pool/disk — /mnt/<mount>/<subdir> — never a bare mount root: a
# pool root (/mnt/cache), an array disk (/mnt/disk1), a UD device (/mnt/disks), or a
# share root (/mnt/user) all hold the operator's OTHER data (appdata, VM vdisks,
# docker.img, unrelated shares), so rm -rf / chown -R must never target one. The
# legacy shipped default /mnt/github-runner (a dedicated pool) is grandfathered so
# already-configured installs keep working. Echoes the canonical root on success; a
# reason on stderr and returns 1 otherwise.
crf_safe_cache_root() {
  local root
  root="$(realpath -m -- "$CACHE_ROOT" 2>/dev/null)" || { echo unresolvable >&2; return 1; }
  [ "$root" = "/mnt/github-runner" ] && { printf '%s' "$root"; return 0; }   # legacy default — grandfathered
  # System dirs and FUSE user-share roots are always unsafe.
  case "$root" in
    ""|"/"|"/mnt" \
    |"/mnt/user"|"/mnt/user"/*|"/mnt/user0"|"/mnt/user0"/* \
    |"/boot"*|"/usr"*|"/etc"*|"/var"*|"/root"*|"/bin"*|"/sbin"*|"/lib"*)
      echo unsafe >&2; return 1 ;;
  esac
  # Require a dedicated subdirectory, never a bare mount root. Unassigned Devices,
  # remote (SMB/NFS) mounts, and addons expose each device/share as
  # /mnt/<container>/<name>, where that <name> level is ITSELF a mount root holding
  # the operator's data — so for those containers require one level deeper
  # (e.g. /mnt/disks/<dev>/<subdir>), not just /mnt/disks/<dev>. For pools and array
  # disks, /mnt/<pool>/<subdir> (>=2 levels) is the dedicated subdir.
  case "$root" in
    /mnt/disks/*/*|/mnt/remotes/*/*|/mnt/addons/*/*) printf '%s' "$root"; return 0 ;;
    /mnt/disks/*|/mnt/remotes/*|/mnt/addons/*)
      echo "device/remote mount root (point CACHE_ROOT at a subdirectory under it, e.g. ${root%/}/github-runner)" >&2; return 1 ;;
    /mnt/*/*) printf '%s' "$root"; return 0 ;;
    /mnt/*)   echo "bare-mount-root (point CACHE_ROOT at a subdirectory, e.g. /mnt/<pool>/github-runner)" >&2; return 1 ;;
    *)        echo not-under-mnt >&2; return 1 ;;
  esac
}

# Resolve a CACHE_MOUNTS host subdir against the (canonical) cache root and confirm
# it stays UNDER that root — rejecting `../` traversal or absolute paths in the
# space-separated, web-settable CACHE_MOUNTS list before they reach mkdir/chown -R
# (ensure_dirs) or a bind mount into every runner (build_args). Echoes the safe
# absolute path on success; returns 1 (caller logs + skips the entry) otherwise.
crf_safe_mount_subdir() {
  local root real
  root="$(realpath -m -- "$CACHE_ROOT" 2>/dev/null)" || return 1
  real="$(realpath -m -- "$CACHE_ROOT/$1" 2>/dev/null)" || return 1
  case "$real" in "$root"/*) printf '%s' "$real"; return 0 ;; *) return 1 ;; esac
}

cmd_cache_usage_refresh() {
  # du can be slow on a multi-GB cache, so this runs detached and the result is
  # cached; the UI reads the cache and only triggers a refresh when it is stale.
  local root total=0 pkg=0 d n
  root="$(crf_safe_cache_root 2>/dev/null)" || { echo "$(date +%s) -1 0" > "$RUNDIR/cache-usage.cache"; return 0; }
  [ -d "$root" ] || { echo "$(date +%s) 0 0" > "$RUNDIR/cache-usage.cache"; return 0; }
  # Scope the "cache" total to the warm caches — exclude each runner's Docker data
  # root (docker/), the workspace (work/), the image mirror, and DinD logs, which are
  # the fleet's Docker storage (tens of GB per runner), not clearable cache.
  total="$(du -sb --exclude=docker --exclude=work --exclude=registry-mirror --exclude=dind-logs "$root" 2>/dev/null | cut -f1)"; [ -n "$total" ] || total=-1
  for d in $CACHE_PKG_DIRS; do
    [ -d "$root/$d" ] && { n="$(du -sb "$root/$d" 2>/dev/null | cut -f1)"; pkg=$(( pkg + ${n:-0} )); }
  done
  echo "$(date +%s) ${total:--1} ${pkg:-0}" > "$RUNDIR/cache-usage.cache"
}

cmd_cache_usage_json() {
  local now ts total pkg age=999999
  now=$(date +%s)
  if [ -f "$RUNDIR/cache-usage.cache" ]; then
    read -r ts total pkg < "$RUNDIR/cache-usage.cache"
    age=$(( now - ${ts:-0} ))
  fi
  if [ "$age" -gt 300 ]; then
    ( flock -n 9 || exit 0; "$0" cache-usage-refresh ) 9>"$RUNDIR/cache-usage.lock" >/dev/null 2>&1 &
  fi
  echo "{\"total\":${total:--1},\"pkg\":${pkg:-0},\"age\":$age}"
}

cmd_cache_clear_pkg() {
  # Clear ONLY the warm package caches (never work/ or docker/). Reuses the
  # prune-cache root-shape guard so a misconfigured CACHE_ROOT can't wipe a share.
  local root d removed=0 failed=0
  root="$(crf_safe_cache_root)" || { echo "{\"ok\":false,\"error\":\"unsafe cache root\"}"; return 1; }
  for d in $CACHE_PKG_DIRS; do
    [ -d "$root/$d" ] || continue
    if rm -rf "${root:?}/${d:?}/"* 2>/dev/null; then removed=$((removed+1)); else failed=$((failed+1)); fi
  done
  ( "$0" cache-usage-refresh ) >/dev/null 2>&1 &
  if [ "$failed" -gt 0 ]; then
    log "cache clear: $failed dir(s) could not be removed under $root"
    echo "{\"ok\":false,\"error\":\"could not remove $failed dir(s)\",\"cleared\":$removed}"; return 1
  fi
  log "package caches cleared ($removed dir(s)) under $root"
  echo "{\"ok\":true,\"cleared\":$removed}"
}

cmd_stats_refresh() {
  # Tally recent workflow-run conclusions across GH_REPOS. Detached + cached so
  # the per-repo API sweep never blocks the UI (see queued for the pattern).
  [ -z "$ACCESS_TOKEN" ] && [ -f "$TOKEN_FILE" ] && ACCESS_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null)"
  [ -n "$ACCESS_TOKEN" ] || { echo "$(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  local ok=0 fail=0 cancel=0 other=0 total got=0 r body c tmpd i=0
  tmpd="$(mktemp -d 2>/dev/null)"
  [ -n "$tmpd" ] || { echo "$(date +%s) 0 0 0 0 -1" > "$RUNDIR/stats.cache"; return 0; }
  gh_fetch_all "/actions/runs?per_page=50" "$tmpd"
  for r in $GH_REPOS; do
    [ -n "$r" ] || continue
    i=$((i+1)); body="$(cat "$tmpd/$i" 2>/dev/null)"
    case "$body" in *'"workflow_runs"'*) got=1 ;; esac
    while IFS= read -r c; do
      case "$c" in
        *'"success"'*)                              ok=$((ok+1)) ;;
        *'"failure"'*|*'"timed_out"'*|*'"startup_failure"'*) fail=$((fail+1)) ;;
        *'"cancelled"'*)                            cancel=$((cancel+1)) ;;
        *null*) : ;;  # in progress / queued — not a completed run
        ?*)     other=$((other+1)) ;;
      esac
    done <<< "$(echo "$body" | grep -oE '"conclusion": ?(null|"[a-z_]+")')"
  done
  rm -rf "$tmpd"
  # total=-1 signals "stats unavailable" (bad token / API down) vs a real zero.
  if [ "$got" = "1" ]; then total=$((ok+fail+cancel+other)); else total=-1; fi
  echo "$(date +%s) $ok $fail $cancel $other $total" > "$RUNDIR/stats.cache"
}

cmd_stats_json() {
  local now ts ok fail cancel other total age=999999
  now=$(date +%s)
  if [ -f "$RUNDIR/stats.cache" ]; then
    read -r ts ok fail cancel other total < "$RUNDIR/stats.cache"
    age=$(( now - ${ts:-0} ))
  fi
  if [ "$age" -gt 300 ]; then
    ( flock -n 9 || exit 0; "$0" stats-refresh ) 9>"$RUNDIR/stats.lock" >/dev/null 2>&1 &
  fi
  echo "{\"ok\":${ok:-0},\"fail\":${fail:-0},\"cancel\":${cancel:-0},\"other\":${other:-0},\"total\":${total:--1},\"age\":$age}"
}

cmd_queued_json() {
  local now ts count age=999999
  now=$(date +%s)
  if [ -f "$RUNDIR/queued.cache" ]; then
    read -r ts count < "$RUNDIR/queued.cache"
    age=$(( now - ${ts:-0} ))
  fi
  # flock, not a plain lock file: the advisory lock is released by the kernel
  # even on SIGKILL/reboot, so a killed refresh can never wedge future refreshes.
  if [ "$age" -gt 60 ]; then
    ( flock -n 9 || exit 0; "$0" queued-refresh ) 9>"$RUNDIR/queued.lock" >/dev/null 2>&1 &
  fi
  echo "{\"queued\":${count:--1},\"age\":$age}"
}

recreate_runner() {
  local name="$1" mode="${2:-force}" idx pool scope image
  runner_identity_validate "$name" || { echo '{"ok":false,"error":"runner is not a valid managed identity"}'; return 1; }
  idx="$(runner_index "$name")"; pool="$(runner_pool "$name")"
  if pool_mode_enabled; then
    pool_record "$pool" >/dev/null 2>&1 || { echo '{"ok":false,"error":"runner pool is retiring"}'; return 1; }
  elif [ "$pool" != default ]; then
    echo '{"ok":false,"error":"pool runner is retiring in single mode"}'; return 1
  fi
  if pool_mode_enabled; then scope="org:$GH_OWNER"
  elif [ "$GH_SCOPE" = org ]; then scope="org:$GH_OWNER"
  else scope="repo:$(repo_for_index "$idx")"; fi
  provision_base || { echo '{"ok":false,"error":"provisioning preflight failed"}'; return 1; }
  [ -n "$ACCESS_TOKEN" ] || { echo '{"ok":false,"error":"no GitHub token configured"}'; return 1; }
  build_args "$idx" "$name" "$pool" "$scope" || { echo '{"ok":false,"error":"cannot provision replacement"}'; return 1; }
  image="${ARGS[${#ARGS[@]}-1]}"
  if [ "$IMAGE_SOURCE" = remote ]; then
    docker pull "$image" >/dev/null 2>&1 || { echo '{"ok":false,"error":"cannot pull replacement image"}'; return 1; }
  else
    docker image inspect "$image" >/dev/null 2>&1 || { echo '{"ok":false,"error":"built-in replacement image is unavailable"}'; return 1; }
  fi
  if [ "$mode" = graceful ]; then
    [ "$(runner_state "$name")" = idle ] || { echo '{"ok":false,"error":"runner is not idle"}'; return 1; }
    deregister_runner_api "$name" || { echo '{"ok":false,"error":"GitHub did not accept runner retirement"}'; return 1; }
    remove_runner_container "$name"
  else
    remove_runner_force "$name" || { echo '{"ok":false,"error":"remove failed"}'; return 1; }
  fi
  log "recycling $name ($mode)"
  if ! docker run "${ARGS[@]}" >/dev/null 2>&1; then
    log "recycle: $name removed but its replacement failed to start"
    echo '{"ok":false,"error":"removed but not recreated"}'; return 1
  fi
  github_runner_inventory_invalidate "$scope" 2>/dev/null || true
  echo '{"ok":true}'
}

cmd_recycle() {
  validate_runtime_config || { echo "{\"ok\":false,\"error\":\"$(printf '%s' "$POOL_CONFIG_ERROR" | json_escape)\"}"; return 1; }
  recreate_runner "$1" force
}

cmd_logs_tail() {
  runner_identity_validate "$1" || return 1
  docker logs --tail "${2:-150}" "$1" 2>&1
}

# base64 a value for the space-delimited cache (empty -> "_" placeholder); _d64 reverses.
_b64() { local v; v="$(printf '%s' "$1" | base64 -w0 2>/dev/null)"; printf '%s' "${v:-_}"; }
_d64() { [ "$1" = "_" ] && return 0; printf '%s' "$1" | base64 -d 2>/dev/null; }
_uu()  { [ "$1" = "_" ] && return 0; printf '%s' "$1"; }

cmd_usage_refresh() {
  # Everything the 5s status poll would otherwise fork per runner, computed ONCE
  # out-of-band: batched docker stats (cpu/mem), the unified phase, and — for busy
  # runners — the job context. cmd_status_json then paints from this cache + a single
  # batched inspect, so the hot path no longer runs docker logs/exec per runner.
  # Line: "name cpu_pct mem_mib phase b64(job) jstarted b64(repo) pr b64(branch) run_id"
  # Also refresh the status-envelope verdicts here, OFF the poll hot path: cache the
  # cache-root (df) warning and keep the public-repo security cache warm, so
  # cmd_status_json never runs df or the per-repo curls inline (and there's no
  # unlocked stampede — this refresher is flock-guarded via usage.lock).
  cache_root_problem > "$RUNDIR/warn.cache" 2>/dev/null
  # Write the public-repo security verdict to a cache the poll reads (empty when
  # there's nothing to warn about, which also clears a stale warning after the config
  # is fixed) — so cmd_status_json never runs the per-repo curls on its own hot path.
  public_repo_problem > "$RUNDIR/sec.cache" 2>/dev/null
  local names; names="$(managed_names)"
  [ -n "$names" ] || { : > "$RUNDIR/usage.cache"; return 0; }
  local statsraw
  # shellcheck disable=SC2086  # $names is intentionally word-split into one arg per runner
  statsraw="$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' $names 2>/dev/null)"
  : > "$RUNDIR/usage.cache.tmp"
  local c
  for c in $names; do
    [ -z "$c" ] && continue
    local srow cpu="" mem_mib=0
    srow="$(printf '%s\n' "$statsraw" | grep -m1 -- "^${c}|")"
    cpu="$(printf '%s' "$srow" | cut -d'|' -f2 | tr -d '%' | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1)"
    mem_mib="$(to_mib "$(printf '%s' "$srow" | cut -d'|' -f3 | awk -F' / ' '{print $1}')")"
    local phase; phase="$(runner_state "$c")"
    local job="" jstarted="_" jrepo="" jpr="_" jbranch="" jrun="_"
    if [ "$phase" = "busy" ]; then
      local jline
      jline="$(docker logs --timestamps --tail 60 "$c" 2>&1 | grep 'Running job: ' | tail -1 | tr -d '\r')"
      job="${jline##*Running job: }"
      jstarted="$(echo "$jline" | awk '{print $1}' | grep -oE '^[0-9T:.Z-]+' | head -1)"; jstarted="${jstarted:-_}"
      local jenv jref
      jenv="$(docker exec "$c" sh -c 'for p in /proc/[0-9]*/environ; do if tr "\0" "\n" < $p 2>/dev/null | grep -q "^GITHUB_REPOSITORY="; then tr "\0" "\n" < $p | grep -E "^GITHUB_(REPOSITORY|RUN_ID|REF_NAME)="; break; fi; done' 2>/dev/null)"
      if [ -n "$jenv" ]; then
        jrepo="$(echo "$jenv" | grep '^GITHUB_REPOSITORY=' | head -1 | cut -d= -f2)"
        jrun="$(echo "$jenv" | grep '^GITHUB_RUN_ID=' | head -1 | cut -d= -f2 | grep -oE '^[0-9]+' | head -1)"; jrun="${jrun:-_}"
        jref="$(echo "$jenv" | grep '^GITHUB_REF_NAME=' | head -1 | cut -d= -f2-)"
        if echo "$jref" | grep -qE '^[0-9]+/merge$'; then jpr="${jref%%/merge*}"; else jbranch="$jref"; fi
      fi
    fi
    printf '%s %s %s %s %s %s %s %s %s %s\n' "$c" "${cpu:-0}" "${mem_mib:-0}" "$phase" \
      "$(_b64 "$job")" "$jstarted" "$(_b64 "$jrepo")" "$jpr" "$(_b64 "$jbranch")" "$jrun" >> "$RUNDIR/usage.cache.tmp"
  done
  mv "$RUNDIR/usage.cache.tmp" "$RUNDIR/usage.cache" 2>/dev/null
}

cmd_status_json() {
  local names
  if fleet_inventory_refresh; then names="$(inventory_names)"
  else
    printf '{"mode":"%s","config_error":"Docker inventory unavailable","count":0,"configured":0,"token":false,"autoscale_enabled":false,"autoscale_max":0,"autoscale":"off","image_autoupdate":"off","warning":"","security":"","stale":0,"retiring":0,"blocked_capacity":0,"pools":[],"runners":[]}\n' \
      "$(printf '%s' "$RUNNER_MODE" | json_escape)"
    return 1
  fi
  local config_error=""
  validate_runtime_config || config_error="$POOL_CONFIG_ERROR"
  # Per-runner cpu/mem/phase/job all come from a background-refreshed cache (see
  # cmd_usage_refresh) so this 5s-per-tab call makes just TWO docker calls total (the
  # `docker ps` in managed_names + one batched inspect for live state and resource
  # limits), never per runner; trigger a cache refresh when stale.
  local usage="" uage=999 nowu
  nowu=$(date +%s)
  if [ -f "$RUNDIR/usage.cache" ]; then
    usage="$(cat "$RUNDIR/usage.cache" 2>/dev/null)"
    uage=$(( nowu - $(stat -c %Y "$RUNDIR/usage.cache" 2>/dev/null || echo 0) ))
  fi
  # Trigger the background refresh whenever the cache is stale — even with an EMPTY
  # fleet, so the cache-root (df) and public-repo security warnings stay fresh during
  # first-time setup (before any runner exists), which is exactly when they matter.
  # Decouple the refresh cadence from the 5s poll for LARGE fleets: cmd_usage_refresh
  # runs one `docker exec` per runner (runner_state), so re-firing every poll would
  # saturate the daemon at scale. Small fleets stay snappy (4s); fleets above the UI's
  # 20-runner max throttle to ~9s, trading slightly staler cpu/mem bars for roughly
  # half the background docker load.
  local rthresh=4; [ "$(printf '%s\n' "$names" | grep -c .)" -gt 20 ] && rthresh=9
  if [ "$uage" -gt "$rthresh" ]; then
    ( flock -n 9 || exit 0; "$0" usage-refresh ) 9>"$RUNDIR/usage.lock" >/dev/null 2>&1 &
  fi
  # ONE batched inspect for the whole fleet's live state + cpu/mem limits (perf: was
  # three separate docker inspects per runner). {{.Name}} carries a leading '/'.
  local cur_gen stalec=0 retiringc=0 blockedc=0
  declare -A pc pup pbusy pidle pstarting perror pstale pretiring
  local out="["; local first=1
  local c st _health cpus mem cgen pool scope pidx _routing identity
  while IFS='|' read -r c st _health cpus mem cgen pool scope pidx _routing identity; do
    [ -z "$c" ] && continue
    local stale=false retiring=false
    pool="${pool:-default}"; pidx="${pidx:-${c##*-}}"
    pool_id_valid "$pool" || pool="invalid"
    case "$pidx" in ''|*[!0-9]*) pidx=0 ;; esac
    # A RUNNING runner whose baked-config fingerprint differs from the current cfg predates
    # a config change; the reconciler migrates it as it goes idle. Surface the count for the UI.
    if [ -z "$config_error" ]; then
      if [ "$identity" != valid ]; then
        retiring=true; retiringc=$((retiringc+1))
      elif pool_mode_enabled; then
        if pool_record "$pool" >/dev/null 2>&1; then
          cur_gen="$(crf_confgen "$pool" "org:$GH_OWNER")"
        else
          retiring=true; retiringc=$((retiringc+1))
        fi
      else
        if [ "$pool" = default ]; then cur_gen="$(crf_confgen)"
        else retiring=true; retiringc=$((retiringc+1)); fi
      fi
      [ "$retiring" = false ] && [ "$st" = running ] && [ "$cgen" != "$cur_gen" ] && { stale=true; stalec=$((stalec+1)); }
    fi
    # phase + cpu/mem usage + job context: all from the background cache line
    # "name cpu mem phase b64(job) jstarted b64(repo) pr b64(branch) run_id".
    local urow phase="starting" cpu_pct=-1 mem_used_mib=-1
    local job="" jstarted="" jrepo="" jpr="" jbranch="" jrun=""
    urow="$(printf '%s\n' "$usage" | grep -m1 -- "^${c} ")"
    if [ -n "$urow" ]; then
      # shellcheck disable=SC2086  # deliberate positional split of the fixed cache line
      set -- $urow
      cpu_pct="$2"; mem_used_mib="$3"; phase="$4"
      job="$(_d64 "$5" | json_escape)"; jstarted="$(_uu "$6")"
      jrepo="$(_d64 "$7" | json_escape)"; jpr="$(_uu "$8")"
      jbranch="$(_d64 "$9" | json_escape)"; jrun="$(_uu "${10}")"
    fi
    pc["$pool"]=$(( ${pc["$pool"]:-0} + 1 ))
    if [ "$st" = running ]; then
      pup["$pool"]=$(( ${pup["$pool"]:-0} + 1 ))
      case "$phase" in
        busy) pbusy["$pool"]=$(( ${pbusy["$pool"]:-0} + 1 )) ;;
        idle) pidle["$pool"]=$(( ${pidle["$pool"]:-0} + 1 )) ;;
        starting) pstarting["$pool"]=$(( ${pstarting["$pool"]:-0} + 1 )) ;;
        *) perror["$pool"]=$(( ${perror["$pool"]:-0} + 1 )) ;;
      esac
    else
      perror["$pool"]=$(( ${perror["$pool"]:-0} + 1 ))
    fi
    [ "$stale" = true ] && pstale["$pool"]=$(( ${pstale["$pool"]:-0} + 1 ))
    if [ "$retiring" = true ]; then
      pretiring["$pool"]=$(( ${pretiring["$pool"]:-0} + 1 ))
      [ "$phase" = idle ] || blockedc=$((blockedc+1))
    fi
    case "$cpu_pct" in ''|*[!0-9.-]*) cpu_pct=-1 ;; esac
    case "$mem_used_mib" in ''|*[!0-9-]*) mem_used_mib=-1 ;; esac
    case "$jpr" in *[!0-9]*) jpr="" ;; esac
    case "$jrun" in *[!0-9]*) jrun="" ;; esac
    local routing_label
    if pool_mode_enabled; then routing_label="$(pool_label "$pool" 2>/dev/null || true)"
    else routing_label="$RUNNER_LABELS"; fi
    [ $first -eq 0 ] && out+=","
    out+="{\"name\":\"$(echo "$c"|json_escape)\",\"pool\":\"$(printf '%s' "$pool"|json_escape)\",\"routing_label\":\"$(printf '%s' "$routing_label"|json_escape)\",\"scope_target\":\"$(printf '%s' "$scope"|json_escape)\",\"pool_index\":${pidx:-0},\"state\":\"${st:-unknown}\",\"phase\":\"$phase\",\"job\":\"${job}\",\"job_started\":\"${jstarted}\",\"repo\":\"${jrepo}\",\"pr\":\"${jpr}\",\"branch\":\"${jbranch}\",\"run_id\":\"${jrun}\",\"cpus\":$(( ${cpus:-0}/1000000000 )),\"mem_gb\":$(( ${mem:-0}/1024/1024/1024 )),\"cpu_pct\":${cpu_pct:-0},\"mem_used_mib\":${mem_used_mib:-0},\"stale\":${stale},\"retiring\":${retiring}}"
    first=0
  done < "$INVENTORY_FILE"
  out+="]"
  local pools="[" pfirst=1 rec pool min max idle configured effective label seen=" " pending=0
  if [ -z "$config_error" ]; then
    while IFS= read -r rec; do
      pool="${rec%%|*}"; min="$(pool_min "$pool")"
      max="$(pool_max "$pool")"; idle="$(pool_idle "$pool")"; configured="$(pool_configured_target "$pool")"
      if pool_mode_enabled; then effective="$(pool_effective_target "$pool")"; label="$(pool_label "$pool")"
      else effective="$configured"; label="$RUNNER_LABELS"; fi
      pending=0
      if pool_mode_enabled && [ "$AUTOSCALE" != true ] && [ "${pc["$pool"]:-0}" -gt "$effective" ]; then
        pending=$(( ${pc["$pool"]:-0} - effective ))
        blockedc=$((blockedc + pending))
      fi
      [ "$pfirst" -eq 0 ] && pools+=","
      pools+="{\"id\":\"$(printf '%s' "$pool"|json_escape)\",\"label\":\"$(printf '%s' "$label"|json_escape)\",\"configured\":${configured},\"effective_target\":${effective},\"count\":${pc["$pool"]:-0},\"up\":${pup["$pool"]:-0},\"busy\":${pbusy["$pool"]:-0},\"idle\":${pidle["$pool"]:-0},\"starting\":${pstarting["$pool"]:-0},\"error\":${perror["$pool"]:-0},\"stale\":${pstale["$pool"]:-0},\"retiring\":${pretiring["$pool"]:-0},\"pending\":${pending},\"min\":${min},\"max\":${max},\"idle_buffer\":${idle}}"
      pfirst=0; seen="${seen}${pool} "
    done < <(pool_records)
  fi
  for pool in "${!pc[@]}"; do
    case "$seen" in *" $pool "*) continue ;; esac
    [ "$pfirst" -eq 0 ] && pools+=","
    pools+="{\"id\":\"$(printf '%s' "$pool"|json_escape)\",\"label\":\"\",\"configured\":0,\"effective_target\":0,\"count\":${pc["$pool"]:-0},\"up\":${pup["$pool"]:-0},\"busy\":${pbusy["$pool"]:-0},\"idle\":${pidle["$pool"]:-0},\"starting\":${pstarting["$pool"]:-0},\"error\":${perror["$pool"]:-0},\"stale\":${pstale["$pool"]:-0},\"retiring\":${pretiring["$pool"]:-0},\"pending\":0,\"min\":0,\"max\":0,\"idle_buffer\":0}"
    pfirst=0
  done
  pools+="]"
  local as="off"; [ "$AUTOSCALE" = "true" ] && as="$(autoscale_status)"
  local iu="off"; [ "$IMAGE_AUTOUPDATE" = "true" ] && iu="$(imageupdate_status) (every $((IMAGE_AUTOUPDATE_INTERVAL/60))m)"
  local warn; warn="$(cat "$RUNDIR/warn.cache" 2>/dev/null | json_escape)"
  # Read the security verdict from cache (written by cmd_usage_refresh) — never call
  # public_repo_problem inline here: on a cold/expired cache that would run the
  # per-repo GitHub curls on the poll's own response path and stall it.
  local sec_raw sec orgp
  sec_raw="$(cat "$RUNDIR/sec.cache" 2>/dev/null)"
  orgp="$(org_runner_group_problem)"
  [ -n "$orgp" ] && sec_raw="${sec_raw}${sec_raw:+ }${orgp}"
  sec="$(printf '%s' "$sec_raw" | json_escape)"
  local autoscale_max="$AUTOSCALE_MAX" configured_total="$RUNNER_COUNT"
  if [ -z "$config_error" ] && pool_mode_enabled; then
    autoscale_max=0; configured_total=0
    while IFS= read -r rec; do
      pool="${rec%%|*}"
      autoscale_max=$((autoscale_max + $(pool_max "$pool")))
      configured_total=$((configured_total + $(pool_configured_target "$pool")))
    done < <(pool_records)
  elif [ "$AUTOSCALE" = true ]; then configured_total="$AUTOSCALE_MIN"; fi
  case "$autoscale_max" in ''|*[!0-9]*) autoscale_max=16 ;; esac
  echo "{\"mode\":\"$(printf '%s' "$RUNNER_MODE"|json_escape)\",\"config_error\":\"$(printf '%s' "$config_error"|json_escape)\",\"count\":$(echo "$names" | grep -c . ),\"configured\":${configured_total},\"token\":$([ -n "$ACCESS_TOKEN" ] && echo true || echo false),\"autoscale_enabled\":$([ "$AUTOSCALE" = "true" ] && echo true || echo false),\"autoscale_max\":${autoscale_max},\"autoscale\":\"$(printf '%s' "$as"|json_escape)\",\"image_autoupdate\":\"$(echo "$iu" | json_escape)\",\"warning\":\"${warn}\",\"security\":\"${sec}\",\"stale\":$((stalec+retiringc)),\"retiring\":${retiringc},\"blocked_capacity\":${blockedc},\"pools\":${pools},\"runners\":${out}}"
}

# Aggregate-only status for the Main -> Dashboard nchan widget: {count,up,busy,idle}.
# Deliberately OMITS the per-runner repo/branch/pr/run_id/job detail that status-json
# carries: the nchan "/sub/<channel>" endpoint is served by Unraid's nginx WITHOUT the
# webGUI login (nchan_authorize_request is commented out in stock locations.conf), so a
# payload pushed there is readable by any client that can reach the box — we must not
# broadcast private repo/job metadata to the whole LAN. The widget only renders these
# counts anyway. One batched inspect + the shared usage cache; triggers the same
# background refresh as status-json so busy/idle stay fresh when only the tile is open.
cmd_dashboard_json() {
  local names up=0 busy=0 idle=0 c st ph usage uage nowu rthresh
  fleet_inventory_refresh || { printf '{"count":0,"up":0,"busy":0,"idle":0}\n'; return 1; }
  names="$(inventory_names)"
  nowu=$(date +%s); uage=999
  [ -f "$RUNDIR/usage.cache" ] && uage=$(( nowu - $(stat -c %Y "$RUNDIR/usage.cache" 2>/dev/null || echo 0) ))
  rthresh=4; [ "$(printf '%s\n' "$names" | grep -c .)" -gt 20 ] && rthresh=9
  [ "$uage" -gt "$rthresh" ] && ( flock -n 9 || exit 0; "$0" usage-refresh ) 9>"$RUNDIR/usage.lock" >/dev/null 2>&1 &
  usage="$([ -f "$RUNDIR/usage.cache" ] && cat "$RUNDIR/usage.cache" 2>/dev/null)"
  for c in $names; do
    [ -n "$c" ] || continue
    st="$(inventory_field "$c" state)"
    [ "$st" = running ] || continue
    up=$((up+1))
    ph="$(printf '%s\n' "$usage" | grep -m1 -- "^${c} " | awk '{print $4}')"
    case "$ph" in busy) busy=$((busy+1)) ;; idle) idle=$((idle+1)) ;; esac
  done
  printf '{"count":%s,"up":%s,"busy":%s,"idle":%s}\n' "$(printf '%s\n' "$names" | grep -c .)" "$up" "$busy" "$idle"
}

cmd_logs() { docker logs --tail "${2:-100}" -f "${NAME_PREFIX}-${1:-1}"; }

cmd_validate() {
  # Prove the provisioning mechanics WITHOUT a GitHub token: launch the image
  # with an inert entrypoint, verify mounts/limits, then tear it down.
  check_cache_root || return 1
  ensure_dirs
  registry_login
  local name="${NAME_PREFIX}-validate"
  docker rm -f "$name" >/dev/null 2>&1
  local NO_REGISTER=1               # validate swaps the entrypoint for a sleep — never registers
  build_args 99 "$name"
  # swap real entrypoint for an inert sleep so no registration is attempted
  local injected=(); local a; local eimg; eimg="$(effective_image)"
  for a in "${ARGS[@]}"; do
    [ "$a" = "$eimg" ] && injected+=( --entrypoint /bin/sh "$eimg" -c "sleep 30" ) || injected+=( "$a" )
  done
  log "validate: launching inert container to verify mounts/limits..."
  local errf; errf="$(mktemp /tmp/crf-validate.XXXXXX)"
  if ! docker run "${injected[@]}" >/dev/null 2>"$errf"; then
    err "docker run failed:"; cat "$errf" >&2; rm -f "$errf"; return 1
  fi
  rm -f "$errf"
  echo "--- resource limits ---"
  docker inspect -f 'cpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}} pids={{.HostConfig.PidsLimit}}' "$name"
  echo "--- mounts ---"
  docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' "$name"
  echo "--- tmpfs ---"
  docker inspect -f '{{json .HostConfig.Tmpfs}}' "$name"
  echo "--- docker.sock reachable inside container ---"
  docker exec "$name" sh -c '[ -S /var/run/docker.sock ] && echo "yes: docker.sock present" || echo "no socket"' 2>/dev/null
  docker rm -f "$name" >/dev/null 2>&1
  [ -n "$name" ] && [ -n "$CACHE_ROOT" ] && rm -rf "$CACHE_ROOT/docker/$name" 2>/dev/null || true
  log "validate: OK (container removed). Provisioning mechanics verified on this host."
}

# Clear the plugin's caches under CACHE_ROOT. Two independent safeguards: (1) the
# root must pass crf_safe_cache_root — a dedicated subdir under a pool/disk, never a
# bare pool/disk/share root or system dir; and (2) even then we delete ONLY the
# subdirectories this plugin creates, never a wholesale "$root"/* glob — so a
# mis-pointed root can't take out unrelated data that shares the pool.
cmd_prune_cache() {
  # Guard + canonicalize the root, then delete ONLY the subdirectories THIS plugin
  # creates under it — the warm package caches, each runner's DinD data root +
  # workspace, the image mirror, the DinD logs, and the generated daemon config.
  # NEVER a bare "$root"/* glob: even if CACHE_ROOT is somehow mis-pointed at a
  # shared location, prune then cannot wipe unrelated data (appdata, VMs, other
  # shares) that happens to sit alongside our subdirs on the same pool.
  local root d m dirs removed=0
  root="$(crf_safe_cache_root)" || { err "refusing to prune-cache: CACHE_ROOT='$CACHE_ROOT' is unsafe (system dir, share/pool root, or unresolvable — point it at /mnt/<pool>/<subdir>)"; return 1; }
  dirs="docker work dind-logs registry-mirror $CACHE_PKG_DIRS"
  for m in $CACHE_MOUNTS; do dirs="$dirs ${m%%:*}"; done
  for d in $dirs; do
    case "$d" in ''|.|..|*/*) continue ;; esac   # simple child names only — never a path/traversal
    [ -e "$root/$d" ] && { rm -rf "${root:?}/${d:?}" && removed=$((removed+1)); }
  done
  rm -f "${root:?}/dind-daemon.json" 2>/dev/null
  log "cache pruned ($removed dir(s)) under $root"
}

# --- Runner-image build orchestration. The engine owns the flock/launch/liveness
#     state machine (previously inlined in exec.php); exec.php now just runs the verb. ---

# Start a build serialized by an flock, reporting success only once the lock is held.
# Open fd 9 on the lock, take it non-blocking, branch on the exit code: 0 = won ->
# truncate the log HERE (before returning, so a poll can't read a prior build's
# __BUILD_RC__) then run the build in a nohup'd child that INHERITS fd 9 (holding the
# lock for the whole build, released only when that child exits — even on SIGKILL);
# 1 = held; anything else (flock missing / unwritable flash) -> launch error.
cmd_build_async() {
  # Log + lock on tmpfs (RUNDIR), NOT flash: a docker build streams thousands of
  # lines and appending each to /boot would hammer the USB stick. The log is only
  # needed for the current session's build, so losing it on reboot is fine.
  local log="$RUNDIR/build.log" lock="$RUNDIR/build.lock" inner
  mkdir -p "$RUNDIR" 2>/dev/null
  exec 9> "$lock" || { echo '{"ok":false,"error":"could not open the build lock (runtime dir not writable?)"}'; return 0; }
  flock -n 9; local rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$log"
    inner="'$0' build-image >> '$log' 2>&1; echo \"__BUILD_RC__=\$?\" >> '$log'"
    nohup sh -c "$inner" </dev/null >/dev/null 2>&1 &
    echo '{"ok":true,"action":"build-image"}'
  elif [ "$rc" -eq 1 ]; then
    echo '{"ok":false,"error":"a build is already running"}'
  else
    echo '{"ok":false,"error":"could not start the build (is flock available and the config dir writable?)"}'
  fi
}

# {ok,running,rc,log} for the current/last build. running = the build-image process is
# live (the [r] bracket-glob keeps this pgrep from matching its own cmdline); rc parses
# from the __BUILD_RC__ sentinel only once the build is no longer running.
cmd_build_status() {
  local log="$RUNDIR/build.log" txt running rc n disp
  txt="$([ -f "$log" ] && tail -n 120 "$log")"
  if pgrep -f '[r]unner-farm.sh build-image' >/dev/null 2>&1; then running=true; else running=false; fi
  rc=null
  if [ "$running" = false ]; then
    n="$(printf '%s' "$txt" | grep -oE '__BUILD_RC__=[0-9]+' | tail -1 | grep -oE '[0-9]+')"
    [ -n "$n" ] && rc="$n"
  fi
  disp="$(printf '%s' "$txt" | grep -v '__BUILD_RC__=')"
  printf '{"ok":true,"running":%s,"rc":%s,"log":%s}\n' "$running" "$rc" "$(printf '%s' "$disp" | json_string)"
}

# {ok,log} — live farm activity for the Fleet log idle state: the autoscale daemon log
# (tmpfs) or boot.log before the daemon ran, minus docker's noisy swap-limit warning.
cmd_farm_log() {
  local as="$RUNDIR/autoscale.log" bt="$CFGDIR/boot.log" src txt
  src="$as"; [ -f "$as" ] || src="$bt"
  txt="$([ -f "$src" ] && tail -n 150 "$src" | grep -v 'swap limit capabilities' | tail -n 60)"
  printf '{"ok":true,"log":%s}\n' "$(printf '%s' "$txt" | json_string)"
}

cmd_build_image() {
  # Build the runner image from the editable Dockerfile. Uses a CLEAN temp
  # context (only the Dockerfile) so the token/config never enter the build.
  local df="$CFGDIR/Dockerfile"
  [ -f "$df" ] || df="/usr/local/emhttp/plugins/$PLUGIN/default.Dockerfile"
  [ -f "$df" ] || { err "no Dockerfile found"; return 1; }
  local ctx; ctx="$(mktemp -d)"
  cp "$df" "$ctx/Dockerfile"
  log "building image '$BUILTIN_IMAGE' from $df"
  docker build -t "$BUILTIN_IMAGE" "$ctx"; local rc=$?
  rm -rf "$ctx"
  if [ $rc -eq 0 ]; then
    log "build complete: $BUILTIN_IMAGE — set Image source to Built-in and restart the fleet to use it"
  else
    err "build failed (rc=$rc)"
  fi
  return $rc
}

# Called from the plugin install step (which ALSO re-runs on every boot via
# rc.local reinstalling all .plg) AND from the Unraid `docker_started` event hook
# (which fires on an array stop->start or Docker service restart without a
# reboot). It may fire before the array/dockerd are up, so wait for both, then
# bring the fleet up idempotently. The caller detaches it so it never blocks
# install/boot/the event sequence. No-op until a token is configured (a fresh
# install waits for the user); cmd_start restarts exited runners, skips running
# ones, and (re)starts the autoscale daemon, so the fleet self-heals after a
# reboot OR a Docker restart.
cmd_boot_autostart() {
  [ -n "$ACCESS_TOKEN" ] || { log "boot-autostart: no token configured yet — skipping"; return 0; }
  local i
  for i in $(seq 1 150); do
    docker info >/dev/null 2>&1 && check_cache_root >/dev/null 2>&1 && break
    sleep 4
  done
  docker info >/dev/null 2>&1 || { err "boot-autostart: dockerd not ready after wait — giving up"; return 1; }
  check_cache_root >/dev/null 2>&1 || { err "boot-autostart: cache pool not ready after wait — giving up"; return 1; }
  log "boot-autostart: docker + cache pool ready — bringing fleet up"
  # Serialize the actual fleet bring-up behind the same lock every other mutation
  # uses: on a Docker-service restart (no reboot) the autoscale/image daemons may
  # still be alive and ticking, so an unlocked cmd_start here would race them into
  # duplicate 'docker run's. The long readiness wait above stays OUTSIDE the lock.
  with_fleet_lock wait cmd_start
}

cmd_validate_pools() {
  local mode="${1:-$RUNNER_MODE}" pools="${2:-$RUNNER_POOLS}" scope="${3:-$GH_SCOPE}" owner="${4-$GH_OWNER}"
  if pool_config_validate "$mode" "$pools" "$scope" "$owner"; then
    printf '{"ok":true}\n'
  else
    printf '{"ok":false,"error":"%s"}\n' "$(printf '%s' "$POOL_CONFIG_ERROR" | json_escape)"
    return 1
  fi
}

case "${1:-status}" in
  start)        with_fleet_lock wait cmd_start ;;
  boot-autostart)   cmd_boot_autostart ;;
  stop)         with_fleet_lock wait cmd_stop ;;
  restart)      with_fleet_lock wait cmd_restart ;;
  mirror-up)    with_fleet_lock wait cmd_mirror_up ;;
  scale)
    if [ -n "${3:-}" ]; then with_fleet_lock wait cmd_scale "${2}" "${3}"
    else with_fleet_lock wait cmd_scale "${2:?usage: scale [pool] <N>}"; fi ;;
  validate-pools)
    if [ "$#" -ge 5 ]; then cmd_validate_pools "${2:-}" "${3:-}" "${4:-}" "$5"
    else cmd_validate_pools "${2:-}" "${3:-}" "${4:-}"; fi ;;
  status)       cmd_status ;;
  status-json)  cmd_status_json ;;
  dashboard-json) cmd_dashboard_json ;;
  image-info-json) cmd_image_info_json ;;
  queued-json)  cmd_queued_json ;;
  queued-refresh) cmd_queued_refresh ;;
  cache-usage-json) cmd_cache_usage_json ;;
  cache-usage-refresh) cmd_cache_usage_refresh ;;
  usage-refresh) cmd_usage_refresh ;;
  cache-clear-pkg) cmd_cache_clear_pkg ;;
  stats-json)   cmd_stats_json ;;
  stats-refresh) cmd_stats_refresh ;;
  recycle)      with_fleet_lock wait cmd_recycle "${2:?usage: recycle <name>}" ;;
  reconcile-config) cmd_reconcile_config ;;
  reconcile-drain)  ( flock -w 5 7 || { echo "reconcile: a drain is already running (it re-reads the cfg each pass and will pick up this change) — skipping duplicate" >>"$RUNDIR/autoscale.log"; exit 0; }; cmd_reconcile_drain ) 7>"$RUNDIR/reconcile.lock" ;;
  logs-tail)    cmd_logs_tail "${2:?usage: logs-tail <name> [n]}" "${3:-150}" ;;
  logs)         cmd_logs "${2:-1}" "${3:-100}" ;;
  validate)         cmd_validate ;;
  build-image)      cmd_build_image ;;
  build-async)      cmd_build_async ;;
  build-status)     cmd_build_status ;;
  farm-log)         cmd_farm_log ;;
  prune-cache)      cmd_prune_cache ;;
  autoscale-daemon) autoscale_daemon ;;
  autoscale-tick)   autoscale_tick ;;
  autoscale-start)  autoscale_start ;;
  autoscale-stop)   autoscale_stop ;;
  autoscale-status) autoscale_status ;;
  imageupdate-daemon) imageupdate_daemon ;;
  imageupdate-tick)   imageupdate_tick ;;
  imageupdate-start)  imageupdate_start ;;
  imageupdate-stop)   imageupdate_stop ;;
  imageupdate-status) imageupdate_status ;;
  *) echo "usage: $0 {start|boot-autostart|stop|restart|scale N|status|status-json|logs i|validate|build-image|prune-cache|autoscale-tick|autoscale-start|autoscale-stop|autoscale-status|imageupdate-tick|imageupdate-start|imageupdate-stop|imageupdate-status}"; exit 1 ;;
esac
