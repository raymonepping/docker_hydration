#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${PROJECT_ROOT}/VERSION"
VERSION=""
if [[ ! -r "$VERSION_FILE" ]]; then
  printf '%s: version file is missing or unreadable: %s\n' "$PROGRAM" "$VERSION_FILE" >&2
  exit 1
fi
IFS= read -r VERSION < "$VERSION_FILE" || [[ -n "$VERSION" ]]
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)*$ ]]; then
  printf '%s: invalid version in %s: %s\n' "$PROGRAM" "$VERSION_FILE" "$VERSION" >&2
  exit 1
fi
STATE_ROOT="${STATE_ROOT:-${PROJECT_ROOT}/.volume-hydrations}"
HELPER_IMAGE="${HELPER_IMAGE:-}"
HELPER_CONTEXT="${PROJECT_ROOT}/docker/volume-helper"
DEFAULT_FULL_HELPER_IMAGE="alpine:3.20"
DEFAULT_INCREMENTAL_HELPER_IMAGE="oci-volume-hydrate-helper:${VERSION}"
COMPOSE_FILE=""
COMPOSE_FILES=()
COMPOSE_DIGESTS=()
COMPOSE_VERSION=""
COMPOSE_CAPABILITIES_CHECKED=false
PROJECT_NAME=""
SOURCE_VOLUME=""
SOURCE_VOLUMES=()
DEST_VOLUME=""
MIGRATION_ID=""
VERIFY_MODE="checksum"
SYNC_MODE="incremental"
DRY_RUN=false
AUTO_CUTOVER=false
EXECUTE_SET=false
FORCE=false
WAIT_HEALTH=120
RETENTION_DAYS=30
CHECKSUM_JOBS=1
PROGRESS_INTERVAL=15
CAPACITY_MARGIN_PERCENT=10
RUNTIME="${RUNTIME:-auto}"
COMPOSE_PROVIDER="${COMPOSE_PROVIDER:-auto}"
ENGINE=""
CMD=""
STATUS=""
LOCK_DIR=""
LOCK_TOKEN=""
RESTART_ON_FAILURE=false
RECOVERY_TARGET="original"
TEMP_FILE=""
HELPER_IMAGE_ID=""
SOURCE_BYTES=""
SOURCE_INODES=""
ACTIVE_PID=""
ACTIVE_HELPER_CONTAINER=""

log(){ printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ log ERROR "$*"; exit 1; }
run(){ if $DRY_RUN; then printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
safe(){ printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'; }
now(){ date -u +%Y%m%dT%H%M%SZ; }
set_helper_container_name(){
  ACTIVE_HELPER_CONTAINER="oci-hydrate-$(safe "${MIGRATION_ID:-preflight}")-$$-$RANDOM"
  ACTIVE_HELPER_CONTAINER="${ACTIVE_HELPER_CONTAINER:0:120}"
}
option_value(){
  local option="$1" value="${2-}"
  [[ -n "$value" && "$value" != -* ]] || die "$option requires a value before the next option"
  printf '%s' "$value"
}
file_sha256(){
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

usage(){ cat <<USAGE
$PROGRAM $VERSION

Non-destructive, resumable OCI volume hydration and Compose cutover.

Usage:
  $PROGRAM inventory --compose-file FILE [options]
  $PROGRAM plan     --compose-file FILE --source-volume VOLUME [options]
  $PROGRAM hydrate  --compose-file FILE --source-volume VOLUME [options]
  $PROGRAM hydrate-set --compose-file FILE [--source-volume VOLUME ...] --dry-run
  $PROGRAM cutover  --migration-id ID
  $PROGRAM rollback --migration-id ID
  $PROGRAM status   --migration-id ID
  $PROGRAM unlock   --migration-id ID [--force]
  $PROGRAM prune    (--dry-run|--execute) [--retention-days DAYS]
  $PROGRAM list

Commands:
  inventory  Show Compose named volumes, consumers, runtime names, and status
  plan       Validate one source volume and create a resumable migration plan
  hydrate    Copy and verify one planned volume without cutting over
  hydrate-set
             Preview all existing Compose volumes, or hydrate them sequentially
             with --execute; --source-volume may be repeated to select a subset
  cutover    Final-sync, verify, and recreate services on the destination
  rollback   Reverse-sync current data and recreate services on the source
  status     Show a migration's saved state
  unlock     Remove a stale migration lock; active locks require --force
  prune      Remove old, inactive migration artifacts with explicit --execute
  list       List saved migrations

Options:
  -f, --compose-file FILE   Compose YAML; repeat for override files in order
  --runtime NAME            auto, docker, or podman (default: auto)
  --compose-provider NAME    auto, native, docker-compose, or podman-compose
  --project-name NAME       Compose project name
  -s, --source-volume NAME  Actual runtime volume name
  -d, --destination-volume NAME
                            Explicit destination name
  --migration-id ID         Resume or operate on an existing migration
  --verify MODE             metadata, size, checksum (default: checksum)
  --sync-mode MODE          incremental or full (default: incremental)
  --capacity-margin PERCENT Free-space/inode margin (default: 10)
  --auto-cutover            Cut over after successful hydration
  --execute                 Execute hydrate-set or prune (both default safe)
  --retention-days DAYS     Minimum age for prune candidates (default: 30)
  --jobs COUNT              Parallel checksum workers (default: 1)
  --progress-interval SEC   Progress log interval (default: 15)
  --wait-health SECONDS     Health-check timeout (default: 120)
  --state-root DIR          State directory (default: <project>/.volume-hydrations)
  --force                   Allow unlock of a lock that may still be active
  --dry-run                 Validate and preview without writing or stopping
  -h, --help                Show help

Safety invariants:
  * Source is mounted read-only during hydration and verification.
  * Original Compose YAML is never modified.
  * Source volume is never deleted by this program.
  * Destination is never reused across unrelated migrations.
  * Cutover uses a generated Compose override.
  * Cutover performs a final sync after quiescing consumers.
  * Consumer drift is checked before cutover and after consumers stop.
  * Rollback reverse-syncs destination changes before recreating services.
  * Failures or interruptions after stopping services trigger recovery.
USAGE
}

state_dir(){ printf '%s/%s' "$STATE_ROOT" "$MIGRATION_ID"; }
state_file(){ printf '%s/state.json' "$(state_dir)"; }
legacy_state_file(){ printf '%s/state.env' "$(state_dir)"; }
migration_exists(){ [[ -f "$(state_file)" || -f "$(legacy_state_file)" ]]; }

canonicalize_compose_files(){
  local index file compose_dir
  if [[ "${#COMPOSE_FILES[@]}" -eq 0 && -n "$COMPOSE_FILE" ]]; then
    COMPOSE_FILES=("$COMPOSE_FILE")
  fi
  for ((index = 0; index < ${#COMPOSE_FILES[@]}; index++)); do
    file="${COMPOSE_FILES[$index]}"
    [[ -f "$file" ]] || die "Compose file not found: $file"
    compose_dir="$(cd "$(dirname "$file")" && pwd)"
    COMPOSE_FILES[index]="$compose_dir/$(basename "$file")"
  done
  if [[ "${#COMPOSE_FILES[@]}" -gt 0 ]]; then
    COMPOSE_FILE="${COMPOSE_FILES[0]}"
  fi
}

capture_compose_digests(){
  local file
  COMPOSE_DIGESTS=()
  for file in "${COMPOSE_FILES[@]}"; do
    COMPOSE_DIGESTS+=("$(file_sha256 "$file")")
  done
}

verify_compose_digests(){
  local index actual
  if [[ "${#COMPOSE_DIGESTS[@]}" -eq 0 ]]; then
    log WARN "Legacy migration has no Compose fingerprints; configuration drift cannot be verified"
    return
  fi
  [[ "${#COMPOSE_FILES[@]}" -eq "${#COMPOSE_DIGESTS[@]}" ]] || die "Compose input count changed since planning"
  for ((index = 0; index < ${#COMPOSE_FILES[@]}; index++)); do
    [[ -f "${COMPOSE_FILES[$index]}" ]] || die "Compose file disappeared: ${COMPOSE_FILES[$index]}"
    actual="$(file_sha256 "${COMPOSE_FILES[$index]}")"
    [[ "$actual" == "${COMPOSE_DIGESTS[$index]}" ]] ||
      die "Compose file changed since planning: ${COMPOSE_FILES[$index]}"
  done
}

validate_migration_id(){
  [[ "$MIGRATION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    die "Invalid migration ID. Use only letters, digits, '.', '_', and '-' (not path components)."
}

acquire_lock(){
  local requested owner_file owner_data owner_pid owner_host owner_start current_host current_start
  requested="$(state_dir)/.lock"
  [[ "$LOCK_DIR" == "$requested" ]] && return 0
  owner_file="$requested/owner.json"
  current_host="$(hostname 2>/dev/null || printf unknown)"
  current_start="$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if ! mkdir "$requested" 2>/dev/null; then
    if [[ -f "$owner_file" ]]; then
      owner_data="$(python3 - "$owner_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        owner = json.load(handle)
    print(f"{owner.get('pid', '')}\t{owner.get('hostname', '')}\t{owner.get('process_start', '')}")
except Exception:
    pass
PY
)"
      IFS=$'\t' read -r owner_pid owner_host owner_start <<< "$owner_data"
      if [[ "$owner_host" == "$current_host" && "$owner_pid" =~ ^[0-9]+$ ]]; then
        if ! kill -0 "$owner_pid" 2>/dev/null; then
          log WARN "Recovering stale lock owned by dead PID $owner_pid"
          rm -f "$owner_file"
          rmdir "$requested" 2>/dev/null || die "Cannot recover stale lock: $requested"
          mkdir "$requested" || die "Cannot acquire recovered lock: $requested"
        else
          local observed_start
          observed_start="$(ps -o lstart= -p "$owner_pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          if [[ -n "$owner_start" && "$observed_start" != "$owner_start" ]]; then
            log WARN "Recovering stale lock after PID reuse: $owner_pid"
            rm -f "$owner_file"
            rmdir "$requested" 2>/dev/null || die "Cannot recover stale lock: $requested"
            mkdir "$requested" || die "Cannot acquire recovered lock: $requested"
          else
            die "Migration is locked by active PID $owner_pid on $owner_host"
          fi
        fi
      else
        die "Migration lock ownership cannot be verified; use unlock --migration-id $MIGRATION_ID --force"
      fi
    else
      die "Migration has a lock without valid owner metadata; use unlock --migration-id $MIGRATION_ID --force"
    fi
  fi
  LOCK_DIR="$requested"
  LOCK_TOKEN="${current_host}-$$-${RANDOM}-$(now)"
  python3 - "$owner_file" "$$" "$current_host" "$current_start" "$LOCK_TOKEN" <<'PY'
import json, os, sys
path, pid, hostname, process_start, token = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"pid": int(pid), "hostname": hostname, "process_start": process_start,
               "token": token}, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.chmod(path, 0o600)
PY
}

release_lock(){
  [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]] || return 0
  local owner_file="$LOCK_DIR/owner.json" token=""
  if [[ -f "$owner_file" ]]; then
    token="$(python3 - "$owner_file" 2>/dev/null <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("token", ""))
PY
)"
  fi
  if [[ -n "$LOCK_TOKEN" && "$token" == "$LOCK_TOKEN" ]]; then
    rm -f "$owner_file"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  LOCK_DIR=""
  LOCK_TOKEN=""
}

unlock_migration(){
  [[ -n "$MIGRATION_ID" ]] || die "unlock requires --migration-id"
  validate_migration_id
  local lock_dir owner_file owner_data owner_pid owner_host owner_start current_host observed_start active=false
  lock_dir="$(state_dir)/.lock"
  owner_file="$lock_dir/owner.json"
  [[ -d "$lock_dir" ]] || { log INFO "Migration is not locked: $MIGRATION_ID"; return; }
  current_host="$(hostname 2>/dev/null || printf unknown)"
  if [[ -f "$owner_file" ]]; then
    if ! owner_data="$(python3 - "$owner_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    owner = json.load(handle)
print(f"{owner.get('pid', '')}\t{owner.get('hostname', '')}\t{owner.get('process_start', '')}")
PY
)"; then
      $FORCE || die "Invalid lock owner metadata; use --force to remove it"
      owner_data=""
    fi
    IFS=$'\t' read -r owner_pid owner_host owner_start <<< "$owner_data"
    if [[ "$owner_host" == "$current_host" && "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      observed_start="$(ps -o lstart= -p "$owner_pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$owner_start" || "$observed_start" == "$owner_start" ]] && active=true
    fi
  fi
  if $active && ! $FORCE; then
    die "Lock owner PID $owner_pid is still active; use --force only after verifying it is safe"
  fi
  if [[ "${owner_host:-$current_host}" != "$current_host" && "$FORCE" != true ]]; then
    die "Lock belongs to host ${owner_host:-unknown}; use --force after verifying the remote owner"
  fi
  [[ -f "$owner_file" ]] && rm -f "$owner_file"
  rmdir "$lock_dir" || die "Lock directory contains unexpected files: $lock_dir"
  log INFO "Removed migration lock: $MIGRATION_ID"
}

cleanup(){
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ -n "$ACTIVE_PID" ]] && kill -0 "$ACTIVE_PID" 2>/dev/null; then
    kill "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  if [[ -n "$ACTIVE_HELPER_CONTAINER" && -n "$ENGINE" ]]; then
    "$ENGINE" rm -f "$ACTIVE_HELPER_CONTAINER" >/dev/null 2>&1 || true
    ACTIVE_HELPER_CONTAINER=""
  fi
  if $RESTART_ON_FAILURE; then
    case "$RECOVERY_TARGET" in
      original)
        log WARN "Operation did not complete; restarting services on the source volume"
        start_original || log ERROR "Automatic source recovery failed; run rollback for migration $MIGRATION_ID"
        ;;
      destination)
        log WARN "Operation did not complete; restarting services on the authoritative destination"
        start_destination || log ERROR "Automatic destination recovery failed; inspect migration $MIGRATION_ID"
        ;;
      reverse-to-original)
        log WARN "Cutover did not complete; synchronizing destination back to source"
        stop_services >/dev/null 2>&1 || true
        if sync_volume_data "$DEST_VOLUME" "$SOURCE_VOLUME" "Emergency reverse synchronization"; then
          start_original || log ERROR "Automatic source restart failed; inspect migration $MIGRATION_ID"
        else
          log ERROR "Emergency reverse synchronization failed; destination may be authoritative"
          start_destination || true
        fi
        ;;
    esac
  fi
  release_lock
  if [[ -n "$TEMP_FILE" && -f "$TEMP_FILE" ]]; then
    rm -f "$TEMP_FILE"
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

save_state(){
  local d tmp compose_files_blob compose_digests_blob
  d="$(state_dir)"
  tmp="$(state_file).tmp"
  compose_files_blob="$(printf '%s\n' "${COMPOSE_FILES[@]}")"
  compose_digests_blob="$(printf '%s\n' "${COMPOSE_DIGESTS[@]}")"
  mkdir -p "$d"
  python3 - "$tmp" \
    "$MIGRATION_ID" "$COMPOSE_FILE" "$compose_files_blob" "$compose_digests_blob" \
    "$PROJECT_NAME" "$SOURCE_VOLUME" "$DEST_VOLUME" "$VERIFY_MODE" "$SYNC_MODE" "${ENGINE:-$RUNTIME}" \
    "$COMPOSE_PROVIDER" "$COMPOSE_VERSION" "${STATUS:-planned}" "${CONSUMERS:-}" "${SERVICES:-}" \
    "${MOUNT_TARGETS:-}" "$HELPER_IMAGE" "${HELPER_IMAGE_ID:-}" "${SOURCE_BYTES:-}" "${SOURCE_INODES:-}" \
    "$CHECKSUM_JOBS" "$PROGRESS_INTERVAL" "$WAIT_HEALTH" "$CAPACITY_MARGIN_PERCENT" \
    "${CREATED_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json
import os
import sys

(path, migration_id, compose_file, compose_files, compose_digests, project_name,
 source_volume, dest_volume, verify_mode, sync_mode, runtime, compose_provider,
 compose_version, status, consumers, services, mount_targets, helper_image,
 helper_image_id, source_bytes, source_inodes, checksum_jobs, progress_interval,
 wait_health, capacity_margin, created_utc, updated_utc) = sys.argv[1:]
state = {
    "schema_version": 2,
    "migration_id": migration_id,
    "compose_file": compose_file,
    "compose_files": compose_files.splitlines(),
    "compose_digests": compose_digests.splitlines(),
    "project_name": project_name,
    "source_volume": source_volume,
    "destination_volume": dest_volume,
    "verify_mode": verify_mode,
    "sync_mode": sync_mode,
    "runtime": runtime,
    "compose_provider": compose_provider,
    "compose_version": compose_version,
    "status": status,
    "consumers": consumers,
    "services": services,
    "mount_targets": mount_targets,
    "helper_image": helper_image,
    "helper_image_id": helper_image_id,
    "source_bytes": int(source_bytes) if source_bytes else None,
    "source_inodes": int(source_inodes) if source_inodes else None,
    "checksum_jobs": int(checksum_jobs),
    "progress_interval": int(progress_interval),
    "wait_health": int(wait_health),
    "capacity_margin_percent": int(capacity_margin),
    "created_utc": created_utc,
    "updated_utc": updated_utc,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
  mv "$tmp" "$(state_file)"
  chmod 600 "$(state_file)"
}

load_state(){
  local mode="${1:-operational}"
  need python3
  [[ -n "$MIGRATION_ID" ]] || die "--migration-id is required"
  validate_migration_id
  migration_exists || die "Migration not found: $MIGRATION_ID"
  [[ "$mode" == "read-only" ]] || acquire_lock
  if [[ -f "$(state_file)" ]]; then
    [[ ! -L "$(state_file)" ]] || die "Refusing symlinked migration state: $(state_file)"
    local assignments
    assignments="$(python3 - "$(state_file)" "$MIGRATION_ID" <<'PY'
import json
import shlex
import sys

path, requested_id = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
if state.get("schema_version") != 2:
    raise SystemExit("unsupported state schema")
if state.get("migration_id") != requested_id:
    raise SystemExit("migration ID does not match state directory")
mapping = {
    "MIGRATION_ID": "migration_id", "COMPOSE_FILE": "compose_file",
    "PROJECT_NAME": "project_name", "SOURCE_VOLUME": "source_volume",
    "DEST_VOLUME": "destination_volume", "VERIFY_MODE": "verify_mode",
    "SYNC_MODE": "sync_mode",
    "RUNTIME": "runtime", "COMPOSE_PROVIDER": "compose_provider",
    "COMPOSE_VERSION": "compose_version",
    "STATUS": "status", "CONSUMERS": "consumers", "SERVICES": "services",
    "MOUNT_TARGETS": "mount_targets", "HELPER_IMAGE": "helper_image",
    "HELPER_IMAGE_ID": "helper_image_id", "SOURCE_BYTES": "source_bytes",
    "SOURCE_INODES": "source_inodes",
    "CHECKSUM_JOBS": "checksum_jobs", "PROGRESS_INTERVAL": "progress_interval",
    "WAIT_HEALTH": "wait_health", "CAPACITY_MARGIN_PERCENT": "capacity_margin_percent",
    "CREATED_UTC": "created_utc", "UPDATED_UTC": "updated_utc",
}
defaults = {
    "sync_mode": "full", "checksum_jobs": 1, "progress_interval": 15,
    "wait_health": 120, "capacity_margin_percent": 10,
}
for shell_name, json_name in mapping.items():
    value = state.get(json_name, defaults.get(json_name))
    print(f"{shell_name}={shlex.quote('' if value is None else str(value))}")
for shell_name, json_name in (("COMPOSE_FILES", "compose_files"), ("COMPOSE_DIGESTS", "compose_digests")):
    values = state.get(json_name) or []
    print(f"{shell_name}=({' '.join(shlex.quote(str(value)) for value in values)})")
PY
)" || die "Invalid migration state: $(state_file)"
    eval "$assignments"
  else
    [[ ! -L "$(legacy_state_file)" ]] || die "Refusing symlinked legacy state: $(legacy_state_file)"
    log WARN "Reading legacy state with the restricted compatibility parser; the next update will migrate it to JSON"
    local legacy_assignments
    legacy_assignments="$(python3 - "$(legacy_state_file)" "$MIGRATION_ID" <<'PY'
import codecs
import re
import shlex
import sys

path, requested_id = sys.argv[1:]
allowed = {
    "MIGRATION_ID", "COMPOSE_FILE", "COMPOSE_FILES", "PROJECT_NAME",
    "SOURCE_VOLUME", "DEST_VOLUME", "VERIFY_MODE", "RUNTIME",
    "COMPOSE_PROVIDER", "STATUS", "CONSUMERS", "SERVICES", "MOUNT_TARGETS",
    "CREATED_UTC", "UPDATED_UTC",
}
values = {}
for number, raw in enumerate(open(path, encoding="utf-8"), 1):
    line = raw.rstrip("\n")
    match = re.fullmatch(r"([A-Z_]+)=(.*)", line)
    if not match or match.group(1) not in allowed:
        raise SystemExit(f"unsupported legacy state syntax on line {number}")
    key, encoded = match.groups()
    if key == "COMPOSE_FILES":
        if not (encoded.startswith("(") and encoded.endswith(")")):
            raise SystemExit("invalid legacy Compose file array")
        values[key] = shlex.split(encoded[1:-1])
    elif encoded.startswith("$'") and encoded.endswith("'"):
        values[key] = codecs.decode(encoded[2:-1], "unicode_escape")
    else:
        parsed = shlex.split(encoded)
        values[key] = parsed[0] if parsed else ""
if values.get("MIGRATION_ID") != requested_id:
    raise SystemExit("migration ID does not match legacy state directory")
for key in sorted(allowed - {"COMPOSE_FILES"}):
    print(f"{key}={shlex.quote(str(values.get(key, '')))}")
files = values.get("COMPOSE_FILES") or ([values.get("COMPOSE_FILE", "")] if values.get("COMPOSE_FILE") else [])
print(f"COMPOSE_FILES=({' '.join(shlex.quote(value) for value in files)})")
print("COMPOSE_DIGESTS=()")
print("HELPER_IMAGE_ID=''")
print("HELPER_IMAGE=alpine:3.20")
print("SOURCE_BYTES=''")
print("SOURCE_INODES=''")
print("SYNC_MODE=full")
print("COMPOSE_VERSION=''")
print("CAPACITY_MARGIN_PERCENT=10")
print("CHECKSUM_JOBS=1")
print("PROGRESS_INTERVAL=15")
print("WAIT_HEALTH=120")
PY
)" || die "Invalid legacy migration state: $(legacy_state_file)"
    eval "$legacy_assignments"
  fi
  if [[ "${#COMPOSE_FILES[@]}" -eq 0 ]]; then COMPOSE_FILES=("$COMPOSE_FILE"); fi
  if [[ "$mode" != "read-only" ]]; then
    ENGINE="$RUNTIME"
    resolve_runtime
    resolve_compose_provider
    check_compose_capabilities "$COMPOSE_VERSION"
  fi
}

resolve_runtime(){
  if [[ -n "$ENGINE" ]]; then return 0; fi
  case "$RUNTIME" in
    auto)
      if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        ENGINE="docker"
      elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        ENGINE="podman"
      else
        die "No usable container runtime found. Install/start Docker or Podman, or use --runtime."
      fi
      ;;
    docker|podman)
      need "$RUNTIME"
      "$RUNTIME" info >/dev/null 2>&1 || die "$RUNTIME runtime is unavailable"
      ENGINE="$RUNTIME"
      ;;
    *) die "Unsupported runtime: $RUNTIME" ;;
  esac
}

resolve_compose_provider(){
  resolve_runtime
  case "$COMPOSE_PROVIDER" in
    auto)
      if [[ "$ENGINE" == "docker" ]] && docker compose version >/dev/null 2>&1; then
        COMPOSE_PROVIDER="native"
      elif [[ "$ENGINE" == "podman" ]] && podman compose version >/dev/null 2>&1; then
        COMPOSE_PROVIDER="native"
      elif [[ "$ENGINE" == "docker" ]] && command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_PROVIDER="docker-compose"
      elif [[ "$ENGINE" == "podman" ]] && command -v podman-compose >/dev/null 2>&1; then
        COMPOSE_PROVIDER="podman-compose"
      else
        die "No compatible Compose provider found for $ENGINE"
      fi
      ;;
    native)
      "$ENGINE" compose version >/dev/null 2>&1 || die "$ENGINE compose is unavailable"
      ;;
    docker-compose)
      [[ "$ENGINE" == "docker" ]] || die "docker-compose requires --runtime docker"
      need docker-compose
      ;;
    podman-compose)
      [[ "$ENGINE" == "podman" ]] || die "podman-compose requires --runtime podman"
      need podman-compose
      ;;
    *) die "Unsupported Compose provider: $COMPOSE_PROVIDER" ;;
  esac
}

select_helper_image(){
  [[ -n "$HELPER_IMAGE" ]] && return
  case "$SYNC_MODE" in
    incremental) HELPER_IMAGE="$DEFAULT_INCREMENTAL_HELPER_IMAGE" ;;
    full) HELPER_IMAGE="$DEFAULT_FULL_HELPER_IMAGE" ;;
    *) die "Unsupported sync mode: $SYNC_MODE" ;;
  esac
}

compose_version_output(){
  case "$COMPOSE_PROVIDER" in
    native) "$ENGINE" compose version 2>&1 ;;
    docker-compose) docker-compose version 2>&1 ;;
    podman-compose) podman-compose version 2>&1 ;;
  esac
}

check_compose_capabilities(){
  local expected_version="${1:-}" output detected minimum help_output
  $COMPOSE_CAPABILITIES_CHECKED && return
  output="$(compose_version_output)" || die "Could not query Compose provider version"
  detected="$(python3 - "$output" <<'PY'
import re, sys
match = re.search(r"(?<!\d)(\d+\.\d+(?:\.\d+)?)(?!\d)", sys.argv[1])
if not match:
    raise SystemExit(1)
parts = match.group(1).split(".")
print(".".join(parts + ["0"] * (3 - len(parts))))
PY
)" || die "Compose provider did not report a semantic version: $output"
  case "$COMPOSE_PROVIDER:$ENGINE" in
    native:docker) minimum="2.20.0" ;;
    docker-compose:docker) minimum="1.29.0" ;;
    *) minimum="1.0.0" ;;
  esac
  python3 - "$detected" "$minimum" <<'PY' || die "Compose $detected is too old; minimum supported version is $minimum"
import sys
def version(value):
    return tuple(int(part) for part in value.split(".")[:3])
raise SystemExit(0 if version(sys.argv[1]) >= version(sys.argv[2]) else 1)
PY
  case "$COMPOSE_PROVIDER" in
    native) help_output="$("$ENGINE" compose --help 2>&1)" ;;
    docker-compose) help_output="$(docker-compose --help 2>&1)" ;;
    podman-compose) help_output="$(podman-compose --help 2>&1)" ;;
  esac
  grep -F -- '--profile' <<< "$help_output" >/dev/null ||
    die "Compose $detected does not advertise required --profile support"

  TEMP_FILE="$(mktemp -t oci-volume-compose-capabilities)"
  if ! compose config --format json > "$TEMP_FILE"; then
    die "Compose $detected cannot render JSON with wildcard profiles"
  fi
  python3 - "$TEMP_FILE" <<'PY' || die "Compose JSON output does not contain services and volumes objects"
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
raise SystemExit(0 if isinstance(config.get("services"), dict) and isinstance(config.get("volumes", {}), dict) else 1)
PY
  rm -f "$TEMP_FILE"
  TEMP_FILE=""
  if [[ -n "$expected_version" && "$detected" != "$expected_version" ]]; then
    die "Compose provider changed since planning: expected $expected_version, found $detected"
  fi
  COMPOSE_VERSION="$detected"
  COMPOSE_CAPABILITIES_CHECKED=true
  log INFO "Compose capabilities verified: $COMPOSE_PROVIDER $COMPOSE_VERSION"
}

ensure_helper_image(){
  local helper_definition_sha="" installed_definition_sha=""
  select_helper_image
  if [[ "$HELPER_IMAGE" == "$DEFAULT_INCREMENTAL_HELPER_IMAGE" ]]; then
    [[ -f "$HELPER_CONTEXT/Dockerfile" ]] || die "Default helper Dockerfile is missing: $HELPER_CONTEXT/Dockerfile"
    helper_definition_sha="$(file_sha256 "$HELPER_CONTEXT/Dockerfile")"
    if "$ENGINE" image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
      installed_definition_sha="$("$ENGINE" image inspect -f '{{ index .Config.Labels "io.hydrate.helper-definition-sha" }}' "$HELPER_IMAGE" 2>/dev/null || true)"
    fi
    if [[ "$installed_definition_sha" != "$helper_definition_sha" ]]; then
      $DRY_RUN && die "Incremental helper image is missing or stale; build it with: $ENGINE build --label io.hydrate.helper-definition-sha=$helper_definition_sha -t $HELPER_IMAGE $HELPER_CONTEXT"
      log INFO "Building pinned rsync helper before service downtime: $HELPER_IMAGE"
      "$ENGINE" pull alpine:3.20 >/dev/null
      "$ENGINE" build --label "io.hydrate.helper-definition-sha=$helper_definition_sha" \
        -t "$HELPER_IMAGE" "$HELPER_CONTEXT" >/dev/null
    fi
  fi
  if ! "$ENGINE" image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
    $DRY_RUN && die "Helper image is not local: $HELPER_IMAGE (pull it before dry-run)"
    log INFO "Pulling helper image before service downtime: $HELPER_IMAGE"
    "$ENGINE" pull "$HELPER_IMAGE" >/dev/null
  fi
  HELPER_IMAGE_ID="$("$ENGINE" image inspect -f '{{.Id}}' "$HELPER_IMAGE")"
  set_helper_container_name
  # shellcheck disable=SC2016
  "$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" "$HELPER_IMAGE" sh -ceu \
    'command -v tar; command -v find; command -v stat; command -v sha256sum; command -v sort; command -v xargs
     printf "a\0b\0" | sort -z >/dev/null
     printf "a\0" | xargs -0 -r -P 1 printf "%s" >/dev/null
     stat -c "%F|%n" / >/dev/null
     if [ "$1" = incremental ]; then command -v rsync >/dev/null; fi' sh "$SYNC_MODE" \
    >/dev/null
  ACTIVE_HELPER_CONTAINER=""
}

verify_helper_image(){
  local current
  select_helper_image
  if [[ -z "$HELPER_IMAGE_ID" ]]; then
    ensure_helper_image
    return
  fi
  current="$("$ENGINE" image inspect -f '{{.Id}}' "$HELPER_IMAGE" 2>/dev/null)" ||
    die "Planned helper image is unavailable: $HELPER_IMAGE"
  if [[ -n "$HELPER_IMAGE_ID" && "$current" != "$HELPER_IMAGE_ID" ]]; then
    die "Helper image changed since planning: $HELPER_IMAGE"
  fi
  HELPER_IMAGE_ID="$current"
}

measure_source_and_capacity(){
  local metrics available inode_total inode_available required_bytes required_inodes
  set_helper_container_name
  # shellcheck disable=SC2016
  metrics="$("$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" -v "$SOURCE_VOLUME:/source:ro" "$HELPER_IMAGE" sh -ceu '
    bytes=$(du -sk /source | awk "{print \$1 * 1024}")
    inodes=$(find /source -xdev -exec stat -c . {} + | wc -l | tr -d " ")
    available=$(df -Pk /source | awk "NR == 2 {print \$4 * 1024}")
    inode_metrics=$(df -Pi /source | awk "NR == 2 {print \$2 \" \" \$4}")
    set -- $inode_metrics
    printf "%s\t%s\t%s\t%s\t%s\n" "$bytes" "$inodes" "$available" "$1" "$2"
  ')"
  ACTIVE_HELPER_CONTAINER=""
  IFS=$'\t' read -r SOURCE_BYTES SOURCE_INODES available inode_total inode_available <<< "$metrics"
  [[ "$SOURCE_BYTES" =~ ^[0-9]+$ && "$SOURCE_INODES" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ &&
     "$inode_total" =~ ^[0-9]+$ && "$inode_available" =~ ^[0-9]+$ ]] ||
    die "Could not measure source bytes, inodes, and runtime capacity"
  required_bytes=$((SOURCE_BYTES + (SOURCE_BYTES * CAPACITY_MARGIN_PERCENT + 99) / 100))
  required_inodes=$((SOURCE_INODES + (SOURCE_INODES * CAPACITY_MARGIN_PERCENT + 99) / 100))
  log INFO "Source requirements: ${SOURCE_BYTES} bytes, ${SOURCE_INODES} inodes; runtime available: ${available} bytes, ${inode_available} inodes"
  if (( required_bytes > available )); then
    die "Insufficient runtime space: require $required_bytes bytes including ${CAPACITY_MARGIN_PERCENT}% margin"
  fi
  if (( inode_total == 0 )); then
    log WARN "Runtime filesystem does not report inode limits; inode capacity cannot be enforced"
  elif (( required_inodes > inode_available )); then
    die "Insufficient runtime inodes: require $required_inodes including ${CAPACITY_MARGIN_PERCENT}% margin"
  fi
}

verify_destination_capacity(){
  local metrics available inode_total inode_available required_bytes required_inodes
  assert_destination_owned
  set_helper_container_name
  # shellcheck disable=SC2016
  metrics="$("$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" \
    -v "$SOURCE_VOLUME:/source:ro" -v "$DEST_VOLUME:/destination:ro" \
    "$HELPER_IMAGE" sh -ceu '
      bytes=$(du -sk /source | awk "{print \$1 * 1024}")
      inodes=$(find /source -xdev -exec stat -c . {} + | wc -l | tr -d " ")
      available=$(df -Pk /destination | awk "NR == 2 {print \$4 * 1024}")
      inode_metrics=$(df -Pi /destination | awk "NR == 2 {print \$2 \" \" \$4}")
      set -- $inode_metrics
      printf "%s\t%s\t%s\t%s\t%s\n" "$bytes" "$inodes" "$available" "$1" "$2"
    ')"
  ACTIVE_HELPER_CONTAINER=""
  IFS=$'\t' read -r SOURCE_BYTES SOURCE_INODES available inode_total inode_available <<< "$metrics"
  [[ "$SOURCE_BYTES" =~ ^[0-9]+$ && "$SOURCE_INODES" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ &&
     "$inode_total" =~ ^[0-9]+$ && "$inode_available" =~ ^[0-9]+$ ]] ||
    die "Could not measure destination byte and inode capacity"
  required_bytes=$((SOURCE_BYTES + (SOURCE_BYTES * CAPACITY_MARGIN_PERCENT + 99) / 100))
  required_inodes=$((SOURCE_INODES + (SOURCE_INODES * CAPACITY_MARGIN_PERCENT + 99) / 100))
  log INFO "Destination capacity: ${available} bytes and ${inode_available} inodes available; source requires ${SOURCE_BYTES} bytes and ${SOURCE_INODES} inodes"
  (( required_bytes <= available )) || die "Destination lacks required byte capacity including ${CAPACITY_MARGIN_PERCENT}% margin"
  if (( inode_total == 0 )); then
    log WARN "Destination filesystem does not report inode limits; inode capacity cannot be enforced"
  else
    (( required_inodes <= inode_available )) || die "Destination lacks required inode capacity including ${CAPACITY_MARGIN_PERCENT}% margin"
  fi
  save_state
}

run_with_progress(){
  local label="$1" start elapsed status next_log
  shift
  start=$SECONDS
  next_log=$((start + PROGRESS_INTERVAL))
  "$@" &
  ACTIVE_PID=$!
  while kill -0 "$ACTIVE_PID" 2>/dev/null; do
    sleep 1 & wait $! || true
    if kill -0 "$ACTIVE_PID" 2>/dev/null && (( SECONDS >= next_log )); then
      elapsed=$((SECONDS - start))
      log INFO "$label still running (${elapsed}s elapsed)"
      next_log=$((SECONDS + PROGRESS_INTERVAL))
    fi
  done
  if wait "$ACTIVE_PID"; then status=0; else status=$?; fi
  ACTIVE_PID=""
  elapsed=$((SECONDS - start))
  [[ "$status" -eq 0 ]] || return "$status"
  log INFO "$label completed in ${elapsed}s"
}

compose_command_base(){
  resolve_compose_provider
  local file
  COMPOSE_COMMAND=()
  case "$COMPOSE_PROVIDER" in
    native) COMPOSE_COMMAND=("$ENGINE" compose) ;;
    docker-compose) COMPOSE_COMMAND=(docker-compose) ;;
    podman-compose) COMPOSE_COMMAND=(podman-compose) ;;
  esac
  COMPOSE_COMMAND+=(--profile '*')
  for file in "${COMPOSE_FILES[@]}"; do
    COMPOSE_COMMAND+=(-f "$file")
  done
  if [[ -n "$PROJECT_NAME" ]]; then
    COMPOSE_COMMAND+=(--project-name "$PROJECT_NAME")
  fi
}

compose(){
  compose_command_base
  "${COMPOSE_COMMAND[@]}" "$@"
}

inventory(){
  need python3
  canonicalize_compose_files
  resolve_runtime
  resolve_compose_provider
  check_compose_capabilities

  umask 077
  TEMP_FILE="$(mktemp -t oci-volume-inventory)"
  if ! compose config --format json > "$TEMP_FILE"; then
    die "Compose provider cannot render JSON configuration; use a current native Docker/Podman Compose provider"
  fi

  python3 - "$TEMP_FILE" "$ENGINE" <<'PY'
import json
import subprocess
import sys

config_path, engine = sys.argv[1:]
with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)

def runtime_consumers(volume):
    result = subprocess.run(
        [engine, "ps", "-aq", "--filter", f"volume={volume}"],
        text=True,
        capture_output=True,
        check=False,
    )
    ids = result.stdout.split()
    if not ids:
        return "-"
    inspected = subprocess.run(
        [engine, "inspect", *ids],
        text=True,
        capture_output=True,
        check=False,
    )
    if inspected.returncode != 0:
        return "inspection-error"
    consumers = []
    for container in json.loads(inspected.stdout):
        name = container.get("Name", "unknown").lstrip("/")
        state = (container.get("State") or {}).get("Status", "unknown")
        for mount in container.get("Mounts", []) or []:
            if mount.get("Name") == volume:
                consumers.append(f"{name}:{mount.get('Destination', '?')}({state})")
    return ",".join(sorted(consumers)) or "-"

usage = {}
for service, spec in sorted(config.get("services", {}).items()):
    for mount in spec.get("volumes", []) or []:
        if mount.get("type") != "volume":
            continue
        source = mount.get("source", "")
        target = mount.get("target", "")
        usage.setdefault(source, []).append(f"{service}:{target}")

project = config.get("name", "")
print(f"Compose project: {project or '(not declared)'}")
print("RUNTIME_VOLUME\tCOMPOSE_KEY\tEXTERNAL\tEXISTS\tCONFIGURED_CONSUMERS\tLIVE_CONSUMERS")
for key, definition in sorted(config.get("volumes", {}).items()):
    definition = definition or {}
    actual = definition.get("name") or (f"{project}_{key}" if project else key)
    external = "yes" if definition.get("external", False) else "no"
    exists = subprocess.run(
        [engine, "volume", "inspect", actual],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0
    configured = ",".join(usage.get(key, [])) or "-"
    live = runtime_consumers(actual) if exists else "-"
    print(f"{actual}\t{key}\t{external}\t{'yes' if exists else 'no'}\t{configured}\t{live}")

hydrated = subprocess.run(
    [engine, "volume", "ls", "-q", "--filter", "label=io.hydrate.role=destination"],
    text=True,
    capture_output=True,
    check=False,
).stdout.split()
if hydrated:
    print("\nHYDRATED_VOLUME\tSOURCE_VOLUME\tMIGRATION_ID\tLIVE_CONSUMERS")
for volume in sorted(hydrated):
    inspected = subprocess.run(
        [engine, "volume", "inspect", volume],
        text=True,
        capture_output=True,
        check=False,
    )
    if inspected.returncode != 0:
        continue
    details = json.loads(inspected.stdout)[0]
    labels = details.get("Labels") or {}
    source = labels.get("io.hydrate.source", "-")
    migration = labels.get("io.hydrate.migration-id", "-")
    print(f"{volume}\t{source}\t{migration}\t{runtime_consumers(volume)}")
PY

  rm -f "$TEMP_FILE"
  TEMP_FILE=""
}

compose_volume_names(){
  need python3
  canonicalize_compose_files
  resolve_runtime
  resolve_compose_provider
  check_compose_capabilities

  TEMP_FILE="$(mktemp -t oci-volume-set)"
  compose config --format json > "$TEMP_FILE"
  python3 - "$TEMP_FILE" "$ENGINE" <<'PY'
import json
import subprocess
import sys

config_path, engine = sys.argv[1:]
with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)
project = config.get("name", "")
for key, definition in sorted(config.get("volumes", {}).items()):
    definition = definition or {}
    actual = definition.get("name") or (f"{project}_{key}" if project else key)
    exists = subprocess.run(
        [engine, "volume", "inspect", actual],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0
    if exists:
        print(actual)
PY
  rm -f "$TEMP_FILE"
  TEMP_FILE=""
}

hydrate_set(){
  local volumes_text="" volume runner failures=0
  local selected=()
  runner="${SCRIPT_DIR}/${PROGRAM}"

  if ! $DRY_RUN && ! $EXECUTE_SET; then
    die "hydrate-set defaults to safety. Add --dry-run to preview or --execute to perform hydration."
  fi

  if [[ "${#SOURCE_VOLUMES[@]}" -gt 0 ]]; then
    volumes_text="$(printf '%s\n' "${SOURCE_VOLUMES[@]}" | sort -u)"
  else
    volumes_text="$(compose_volume_names)"
  fi
  [[ -n "$volumes_text" ]] || die "No existing named volumes were found in the Compose configuration"
  while IFS= read -r volume; do
    [[ -n "$volume" ]] && selected+=("$volume")
  done <<< "$volumes_text"

  log INFO "Hydration set contains ${#selected[@]} volume(s); automatic cutover is disabled"
  for volume in "${selected[@]}"; do
    local command_args=(
      "$runner" hydrate
      --source-volume "$volume"
      --runtime "$RUNTIME"
      --compose-provider "$COMPOSE_PROVIDER"
      --verify "$VERIFY_MODE"
      --sync-mode "$SYNC_MODE"
      --capacity-margin "$CAPACITY_MARGIN_PERCENT"
      --jobs "$CHECKSUM_JOBS"
      --progress-interval "$PROGRESS_INTERVAL"
      --wait-health "$WAIT_HEALTH"
      --state-root "$STATE_ROOT"
    )
    local compose_path
    for compose_path in "${COMPOSE_FILES[@]}"; do
      command_args+=(--compose-file "$compose_path")
    done
    [[ -n "$PROJECT_NAME" ]] && command_args+=(--project-name "$PROJECT_NAME")
    $DRY_RUN && command_args+=(--dry-run)
    log INFO "Processing set volume: $volume"
    if ! "${command_args[@]}"; then
      failures=$((failures + 1))
      log ERROR "Set volume failed validation or hydration: $volume"
      $DRY_RUN || return 1
    fi
  done
  [[ "$failures" -eq 0 ]] || die "hydrate-set found $failures blocked volume(s); include the missing Compose override files and retry"
  log INFO "Hydration set complete; review each migration before cutover"
}

all_volume_consumers(){
  "$ENGINE" ps -aq --filter "volume=$SOURCE_VOLUME"
}

inspect_consumers(){
  local ids id project service target details rows="" services="" targets=""
  local id_array=()
  ids="$(all_volume_consumers)"
  [[ -n "$ids" ]] || die "No containers mount source volume: $SOURCE_VOLUME"
  while IFS= read -r id; do [[ -n "$id" ]] && id_array+=("$id"); done <<< "$ids"
  details="$("$ENGINE" inspect "${id_array[@]}" | python3 -c '
import json, sys
source = sys.argv[1]
for container in json.load(sys.stdin):
    labels = (container.get("Config") or {}).get("Labels") or {}
    project = labels.get("com.docker.compose.project") or labels.get("io.podman.compose.project") or ""
    service = labels.get("com.docker.compose.service") or labels.get("io.podman.compose.service") or ""
    identifier = container.get("Id", "")[:12]
    for mount in container.get("Mounts") or []:
        if mount.get("Name") == source:
            print("|".join((identifier, project, service, mount.get("Destination", "?"))))
' "$SOURCE_VOLUME")"
  while IFS='|' read -r id project service target; do
    [[ -n "$id" ]] || continue
    [[ -n "$project" && -n "$service" ]] || die "Container $id mounts the volume but is not Compose-managed"
    if [[ -z "$PROJECT_NAME" ]]; then PROJECT_NAME="$project"; fi
    [[ "$project" == "$PROJECT_NAME" ]] || die "Volume is shared with Compose project '$project'; expected '$PROJECT_NAME'"
    rows+="$id|$service|$target"$'\n'
    services+="$service"$'\n'
    targets+="$service|$target"$'\n'
  done <<< "$details"
  CONSUMERS="$(printf '%s' "$rows" | sed '/^$/d' | sort -u)"
  SERVICES="$(printf '%s' "$services" | sed '/^$/d' | sort -u | paste -sd, -)"
  MOUNT_TARGETS="$(printf '%s' "$targets" | sed '/^$/d' | sort -u)"
}

verify_source_consumer_snapshot(){
  local expected_consumers="$CONSUMERS" expected_services="$SERVICES" expected_targets="$MOUNT_TARGETS"
  local expected_project="$PROJECT_NAME" actual_targets
  inspect_consumers
  actual_targets="$MOUNT_TARGETS"
  CONSUMERS="$expected_consumers"
  SERVICES="$expected_services"
  MOUNT_TARGETS="$expected_targets"
  PROJECT_NAME="$expected_project"
  if [[ "$actual_targets" != "$expected_targets" ]]; then
    log ERROR "Source-volume consumers changed since planning"
    printf 'Expected service mounts:\n%s\nCurrent service mounts:\n%s\n' \
      "$expected_targets" "$actual_targets" >&2
    die "Consumer drift detected; create a new migration plan before cutover"
  fi
  log INFO "Consumer snapshot verified before cutover"
}

assert_no_running_consumers(){
  local volume="$1" running
  running="$("$ENGINE" ps -q --filter "volume=$volume")"
  [[ -z "$running" ]] || die "Volume still has running consumers after quiesce: $volume ($running)"
}

validate_compose_mapping(){
  umask 077
  TEMP_FILE="$(mktemp -t oci-volume-compose)"
  compose config --format json > "$TEMP_FILE"
  if ! python3 - "$TEMP_FILE" "$SOURCE_VOLUME" "$MOUNT_TARGETS" <<'PY'
import json
import sys

config_path, source_volume, expected_rows = sys.argv[1:]
with open(config_path, encoding="utf-8") as handle:
    config = json.load(handle)

project = config.get("name", "")
definitions = config.get("volumes", {})

def actual_name(key):
    definition = definitions.get(key) or {}
    return definition.get("name") or (f"{project}_{key}" if project else key)

errors = []
for row in expected_rows.splitlines():
    if not row:
        continue
    service, target = row.split("|", 1)
    mounts = (config.get("services", {}).get(service, {}) or {}).get("volumes", []) or []
    matches = [
        mount for mount in mounts
        if mount.get("type") == "volume" and mount.get("target") == target
    ]
    if not matches:
        errors.append(f"Compose service {service!r} has no named volume at {target!r}")
        continue
    configured = actual_name(matches[0].get("source", ""))
    if configured != source_volume:
        errors.append(
            f"Compose maps {service}:{target} to {configured!r}, not {source_volume!r}"
        )

if errors:
    print("; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    die "Source volume does not match the rendered Compose configuration"
  fi
  rm -f "$TEMP_FILE"
  TEMP_FILE=""
}

preflight(){
  need python3
  canonicalize_compose_files
  resolve_runtime
  resolve_compose_provider
  check_compose_capabilities
  "$ENGINE" volume inspect "$SOURCE_VOLUME" >/dev/null 2>&1 || die "Source volume not found: $SOURCE_VOLUME"
  compose config >/dev/null
  inspect_consumers
  validate_compose_mapping
  ensure_helper_image
  measure_source_and_capacity
}

create_plan(){
  preflight
  capture_compose_digests
  [[ -n "$MIGRATION_ID" ]] || MIGRATION_ID="$(safe "${PROJECT_NAME}-${SOURCE_VOLUME}-$(now)")"
  validate_migration_id
  [[ -n "$DEST_VOLUME" ]] || DEST_VOLUME="${SOURCE_VOLUME}__hydrated__$(now)"
  if "$ENGINE" volume inspect "$DEST_VOLUME" >/dev/null 2>&1; then
    die "Destination already exists: $DEST_VOLUME"
  fi
  STATUS="planned"; CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local d; d="$(state_dir)"
  log INFO "Migration planned: $MIGRATION_ID"
  log INFO "Source remains authoritative: $SOURCE_VOLUME"
  log INFO "Destination: $DEST_VOLUME"
  if $DRY_RUN; then
    log INFO "Dry run complete; no state, volume, or container was changed"
    return
  fi
  [[ ! -e "$d" ]] || die "Migration state already exists: $MIGRATION_ID"
  umask 077
  mkdir -p "$d"
  chmod 700 "$d"
  acquire_lock
  local index
  for ((index = 0; index < ${#COMPOSE_FILES[@]}; index++)); do
    cp "${COMPOSE_FILES[$index]}" "$d/compose.original.${index}.yml"
  done
  "$ENGINE" volume inspect "$SOURCE_VOLUME" > "$d/source-volume.inspect.json"
  chmod 600 "$d"/*
  save_state
}

ensure_destination(){
  if "$ENGINE" volume inspect "$DEST_VOLUME" >/dev/null 2>&1; then
    local owner
    owner="$("$ENGINE" volume inspect -f '{{ index .Labels "io.hydrate.migration-id" }}' "$DEST_VOLUME")"
    [[ "$owner" == "$MIGRATION_ID" ]] || die "Destination exists but belongs to another migration"
    STATUS="destination-created"
    save_state
    return
  fi
  run "$ENGINE" volume create \
    --label "io.hydrate.migration-id=$MIGRATION_ID" \
    --label "io.hydrate.source=$SOURCE_VOLUME" \
    --label "io.hydrate.role=destination" \
    "$DEST_VOLUME" >/dev/null
  STATUS="destination-created"; save_state
}

assert_destination_owned(){
  local owner
  "$ENGINE" volume inspect "$DEST_VOLUME" >/dev/null 2>&1 || die "Destination volume is missing: $DEST_VOLUME"
  owner="$("$ENGINE" volume inspect -f '{{ index .Labels "io.hydrate.migration-id" }}' "$DEST_VOLUME")"
  [[ "$owner" == "$MIGRATION_ID" ]] || die "Destination volume is not owned by migration $MIGRATION_ID"
}

stop_consumers(){
  local svc_array=(); IFS=',' read -r -a svc_array <<< "$SERVICES"
  $DRY_RUN || RESTART_ON_FAILURE=true
  run compose stop "${svc_array[@]}"
  assert_no_running_consumers "$SOURCE_VOLUME"
  STATUS="consumers-stopped"; save_state
}

stop_services(){
  local svc_array=(); IFS=',' read -r -a svc_array <<< "$SERVICES"
  run compose stop "${svc_array[@]}"
}

start_original(){
  local svc_array=(); IFS=',' read -r -a svc_array <<< "$SERVICES"
  run compose up -d --force-recreate "${svc_array[@]}"
  RESTART_ON_FAILURE=false
}

start_destination(){
  local d svc_array=()
  d="$(state_dir)"
  IFS=',' read -r -a svc_array <<< "$SERVICES"
  compose_command_base
  local cmd=("${COMPOSE_COMMAND[@]}" -f "$d/compose.hydrated.override.yml")
  cmd+=(up -d --force-recreate "${svc_array[@]}")
  run "${cmd[@]}"
}

sync_volume_data(){
  local from_volume="$1" to_volume="$2" description="$3"
  log INFO "$description ($SYNC_MODE): $from_volume -> $to_volume"
  set_helper_container_name
  # shellcheck disable=SC2016
  run_with_progress "$description" "$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" \
    -v "$from_volume:/source:ro" \
    -v "$to_volume:/destination" \
    "$HELPER_IMAGE" sh -ceu '
      mode="$1"
      test -d /source && test -d /destination
      case "$mode" in
        incremental)
          rsync -aHAXSx --no-whole-file --numeric-ids --delete --delete-delay --stats /source/ /destination/
          ;;
        full)
          find /destination -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
          cd /source
          set -o pipefail 2>/dev/null || true
          tar cpf - . | tar xpf - -C /destination
          ;;
        *) printf "Unsupported sync mode: %s\n" "$mode" >&2; exit 2 ;;
      esac
      sync
    ' sh "$SYNC_MODE"
  ACTIVE_HELPER_CONTAINER=""
}

hydrate_data(){
  assert_destination_owned
  sync_volume_data "$SOURCE_VOLUME" "$DEST_VOLUME" "Hydrating volume"
  STATUS="copied"; save_state
}

manifest_volume(){
  local volume="$1" output="$2" mode="$3"
  set_helper_container_name
  case "$mode" in
    metadata)
      run_with_progress "Metadata manifest for $volume" \
        "$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" -v "$volume:/data:ro" "$HELPER_IMAGE" sh -ceu '
        cd /data
        find . -xdev -print0 | sort -z | xargs -0 -r stat -c "%F|%n|%s|%a|%u|%g" 2>/dev/null
      ' > "$output"
      ;;
    size)
      run_with_progress "Size manifest for $volume" \
        "$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" -v "$volume:/data:ro" "$HELPER_IMAGE" sh -ceu '
        cd /data
        find . -xdev -type f -print0 | sort -z | xargs -0 -r stat -c "%n|%s|%a|%u|%g" 2>/dev/null
      ' > "$output"
      ;;
    checksum)
      # shellcheck disable=SC2016
      run_with_progress "Checksum manifest for $volume" \
        "$ENGINE" run --rm --name "$ACTIVE_HELPER_CONTAINER" -v "$volume:/data:ro" "$HELPER_IMAGE" sh -ceu '
        jobs="$1"
        cd /data
        find . -xdev -type f -print0 | sort -z | xargs -0 -r -n 32 -P "$jobs" sha256sum | LC_ALL=C sort
        find . -xdev ! -type f -print0 | sort -z | xargs -0 -r stat -c "META|%F|%n|%a|%u|%g" 2>/dev/null
      ' sh "$CHECKSUM_JOBS" > "$output"
      ;;
    *) die "Unknown verification mode: $mode" ;;
  esac
  ACTIVE_HELPER_CONTAINER=""
}

verify_volume_pair(){
  local left_volume="$1" right_volume="$2" label="$3"
  local d src dst
  d="$(state_dir)"
  src="$d/${label}.left.manifest"
  dst="$d/${label}.right.manifest"
  manifest_volume "$left_volume" "$src" "$VERIFY_MODE"
  manifest_volume "$right_volume" "$dst" "$VERIFY_MODE"
  if ! cmp -s "$src" "$dst"; then
    diff -u "$src" "$dst" > "$d/${label}.verification.diff" || true
    return 1
  fi
  log INFO "Volume pair verified using mode: $VERIFY_MODE ($label)"
}

verify_data(){
  if ! verify_volume_pair "$SOURCE_VOLUME" "$DEST_VOLUME" hydration; then
    STATUS="verification-failed"; save_state
    die "Verification failed; recovery will restart the authoritative services"
  fi
  STATUS="verified"; save_state
  log INFO "Hydration verified using mode: $VERIFY_MODE"
}

generate_override(){
  local d; d="$(state_dir)"
  python3 - "$MOUNT_TARGETS" "$DEST_VOLUME" > "$d/compose.hydrated.override.yml" <<'PY'
import sys
rows, dest = sys.argv[1], sys.argv[2]
services = {}
for row in rows.splitlines():
    if not row:
        continue
    service, target = row.split('|', 1)
    services.setdefault(service, []).append(target)
print('services:')
for service in sorted(services):
    print(f'  {service}:')
    print('    volumes:')
    for target in sorted(set(services[service])):
        print('      - type: volume')
        print('        source: hydrated_data')
        print(f'        target: {target}')
print('volumes:')
print('  hydrated_data:')
print('    external: true')
print(f'    name: {dest}')
PY
  compose -f "$d/compose.hydrated.override.yml" config >/dev/null
  STATUS="cutover-ready"; save_state
}

project_service_containers(){
  local ids id
  local id_array=()
  ids="$("$ENGINE" ps -aq)"
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do [[ -n "$id" ]] && id_array+=("$id"); done <<< "$ids"
  "$ENGINE" inspect "${id_array[@]}" | python3 -c '
import json, sys
project, services_csv = sys.argv[1:]
services = set(filter(None, services_csv.split(",")))
for container in json.load(sys.stdin):
    labels = (container.get("Config") or {}).get("Labels") or {}
    actual_project = labels.get("com.docker.compose.project") or labels.get("io.podman.compose.project")
    service = labels.get("com.docker.compose.service") or labels.get("io.podman.compose.service")
    if actual_project == project and service in services:
        identifier = container.get("Id", "?")[:12]
        print(f"{identifier}|{service}")
' "$PROJECT_NAME" "$SERVICES"
}

container_for_service(){
  local wanted="$1" id service
  while IFS='|' read -r id service; do
    [[ "$service" == "$wanted" ]] && { printf '%s' "$id"; return 0; }
  done < <(project_service_containers)
  return 1
}

wait_for_health(){
  local deadline=$((SECONDS + WAIT_HEALTH)) id svc status found
  while (( SECONDS < deadline )); do
    local all_ok=true
    found=0
    while IFS='|' read -r id svc; do
      [[ -n "$id" ]] || continue
      found=$((found + 1))
      status="$("$ENGINE" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
      [[ "$status" == "healthy" || "$status" == "running" ]] || all_ok=false
    done < <(project_service_containers)
    [[ "$found" -gt 0 ]] && $all_ok && return 0
    sleep 2
  done
  return 1
}

validate_service_mounts(){
  local expected_volume="$1" svc target actual
  while IFS='|' read -r svc target; do
    [[ -n "$svc" ]] || continue
    actual="$(container_for_service "$svc" || true)"
    if [[ -z "$actual" ]]; then
      log ERROR "Service missing after transition: $svc"
      return 1
    fi
    if ! "$ENGINE" inspect -f '{{range .Mounts}}{{println .Name "|" .Destination}}{{end}}' "$actual" |
      grep -F "$expected_volume | $target" >/dev/null; then
      log ERROR "Mount validation failed for $svc:$target (expected $expected_volume)"
      return 1
    fi
  done <<< "$MOUNT_TARGETS"
}

validate_services(){
  local expected_volume="$1"
  if ! wait_for_health; then
    log ERROR "Service health validation timed out after ${WAIT_HEALTH}s"
    return 1
  fi
  validate_service_mounts "$expected_volume"
}

cutover(){
  load_state
  verify_helper_image
  verify_compose_digests
  assert_destination_owned
  if [[ "$STATUS" == "active-on-destination" ]]; then
    validate_services "$DEST_VOLUME" || die "Existing cutover failed health or mount validation"
    log INFO "Cutover is already complete and validated: $MIGRATION_ID"
    return
  fi
  [[ "$STATUS" == "cutover-ready" || "$STATUS" == "rolled-back" ]] || die "Migration is not cutover-ready; current status: $STATUS"
  verify_source_consumer_snapshot

  RECOVERY_TARGET="original"
  RESTART_ON_FAILURE=true
  log INFO "Quiescing consumers for final synchronization"
  stop_services
  assert_no_running_consumers "$SOURCE_VOLUME"
  STATUS="cutover-syncing"; save_state
  sync_volume_data "$SOURCE_VOLUME" "$DEST_VOLUME" "Final cutover synchronization"
  if ! verify_volume_pair "$SOURCE_VOLUME" "$DEST_VOLUME" cutover; then
    die "Final cutover verification failed"
  fi
  STATUS="cutover-starting"; save_state
  RECOVERY_TARGET="reverse-to-original"
  start_destination
  if ! validate_services "$DEST_VOLUME"; then
    log ERROR "Cutover validation failed; reverse-synchronizing and rolling back"
    rollback_internal true
    die "Cutover failed and was rolled back"
  fi
  "$ENGINE" volume inspect "$SOURCE_VOLUME" >/dev/null || die "Safety invariant violated: source volume disappeared"
  RESTART_ON_FAILURE=false
  STATUS="active-on-destination"; save_state
  log INFO "Cutover complete. Source volume retained: $SOURCE_VOLUME"
}

rollback_internal(){
  local reverse_sync="${1:-false}"
  if [[ "$reverse_sync" == true ]]; then
    RECOVERY_TARGET="destination"
    RESTART_ON_FAILURE=true
    stop_services
    assert_no_running_consumers "$DEST_VOLUME"
    STATUS="rollback-syncing"; save_state
    sync_volume_data "$DEST_VOLUME" "$SOURCE_VOLUME" "Reverse rollback synchronization"
    if ! verify_volume_pair "$DEST_VOLUME" "$SOURCE_VOLUME" rollback; then
      die "Rollback reverse synchronization failed; destination remains authoritative"
    fi
  fi
  start_original
  RESTART_ON_FAILURE=true
  RECOVERY_TARGET="destination"
  validate_services "$SOURCE_VOLUME" || die "Rollback service validation failed"
  RESTART_ON_FAILURE=false
  STATUS="rolled-back"; save_state
}

rollback(){
  load_state
  verify_helper_image
  verify_compose_digests
  if [[ "$STATUS" == "rolled-back" ]]; then
    validate_services "$SOURCE_VOLUME" || die "Existing rollback failed health or mount validation"
    log INFO "Rollback is already complete and validated: $MIGRATION_ID"
    return
  fi
  case "$STATUS" in
    active-on-destination|cutover-starting|rollback-syncing) rollback_internal true ;;
    cutover-ready) rollback_internal false ;;
    *) die "Migration cannot be rolled back from status: $STATUS" ;;
  esac
  log INFO "Rollback complete. Both volumes retained and source is current."
}

hydrate(){
  local resumed=false
  if [[ -n "$MIGRATION_ID" ]] && migration_exists; then
    load_state
    verify_helper_image
    resumed=true
  else
    create_plan
  fi
  if $DRY_RUN; then
    log INFO "Would execute hydration phases after status: ${STATUS:-planned}"
    log INFO "Dry run stops before creating a destination or stopping services"
    return
  fi
  if $resumed && [[ "$STATUS" == "consumers-stopped" || "$STATUS" == "copied" || "$STATUS" == "verification-failed" ]]; then
    log INFO "Re-quiescing source consumers before resuming hydration"
    stop_consumers
  fi
  if [[ "$STATUS" == "consumers-stopped" || "$STATUS" == "copied" || "$STATUS" == "verified" ]]; then
    RESTART_ON_FAILURE=true
  fi
  case "$STATUS" in
    planned) ensure_destination ;;
  esac
  case "$STATUS" in
    destination-created) verify_destination_capacity; stop_consumers ;;
  esac
  case "$STATUS" in
    consumers-stopped) hydrate_data ;;
  esac
  case "$STATUS" in
    copied) verify_data ;;
  esac
  case "$STATUS" in
    verified) generate_override; start_original ;;
  esac
  log INFO "Hydration state: $STATUS"
  if $AUTO_CUTOVER; then
    cutover
  fi
}

show_status(){
  load_state read-only
  if [[ -f "$(state_file)" ]]; then
    python3 -m json.tool "$(state_file)"
    return
  fi
  python3 - "$MIGRATION_ID" "$STATUS" "$SOURCE_VOLUME" "$DEST_VOLUME" "$RUNTIME" "$PROJECT_NAME" <<'PY'
import json, sys
migration_id, status, source, destination, runtime, project = sys.argv[1:]
print(json.dumps({
    "schema_version": 1,
    "legacy_state": True,
    "migration_id": migration_id,
    "status": status,
    "source_volume": source,
    "destination_volume": destination,
    "runtime": runtime,
    "project_name": project,
}, indent=2, sort_keys=True))
PY
}
list_migrations(){
  [[ -d "$STATE_ROOT" ]] || exit 0
  find "$STATE_ROOT" -mindepth 2 -maxdepth 2 \( -name state.json -o -name state.env \) -print |
    sed 's#/state\.json$##;s#/state\.env$##' | sort -u
}

prune_migrations(){
  need python3
  [[ -d "$STATE_ROOT" ]] || { log INFO "No migration state directory exists: $STATE_ROOT"; return; }
  if ! $DRY_RUN && ! $EXECUTE_SET; then
    die "prune requires --dry-run to preview or --execute to remove eligible artifacts"
  fi
  $DRY_RUN && $EXECUTE_SET && die "Choose either --dry-run or --execute for prune"
  $EXECUTE_SET && resolve_runtime

  local candidates migration destination status age current_status owner role consumers d
  candidates="$(python3 - "$STATE_ROOT" "$RETENTION_DAYS" <<'PY'
import datetime as dt
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
retention = int(sys.argv[2])
now = dt.datetime.now(dt.timezone.utc)
eligible = {"planned", "destination-created", "verification-failed", "rolled-back"}
for state_file in sorted(root.glob("*/state.json")):
    try:
        state = json.loads(state_file.read_text(encoding="utf-8"))
        migration = str(state.get("migration_id", ""))
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", migration):
            continue
        if state_file.parent.name != migration or state_file.parent.parent.resolve() != root:
            continue
        status = str(state.get("status", ""))
        if status not in eligible:
            continue
        stamp = state.get("updated_utc") or state.get("created_utc")
        updated = dt.datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
        age = max(0, (now - updated).days)
        if age >= retention:
            destination = str(state.get("destination_volume") or "")
            print(f"{migration}|{destination}|{status}|{age}")
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        continue
PY
)"
  if [[ -z "$candidates" ]]; then
    log INFO "No eligible migrations are at least ${RETENTION_DAYS} day(s) old"
    return
  fi

  while IFS='|' read -r migration destination status age; do
    [[ -n "$migration" ]] || continue
    log INFO "Prune candidate: $migration (status=$status, age=${age}d, destination=${destination:-none})"
    if $DRY_RUN; then
      continue
    fi

    MIGRATION_ID="$migration"
    validate_migration_id
    acquire_lock
    d="$(state_dir)"
    current_status="$(python3 - "$d/state.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("status", ""))
PY
)"
    [[ "$current_status" == "$status" ]] || die "Migration changed while pruning: $migration"

    if [[ -n "$destination" ]] && "$ENGINE" volume inspect "$destination" >/dev/null 2>&1; then
      owner="$("$ENGINE" volume inspect -f '{{ index .Labels "io.hydrate.migration-id" }}' "$destination")"
      role="$("$ENGINE" volume inspect -f '{{ index .Labels "io.hydrate.role" }}' "$destination")"
      [[ "$owner" == "$migration" && "$role" == "destination" ]] ||
        die "Refusing to prune volume with mismatched ownership labels: $destination"
      consumers="$("$ENGINE" ps -aq --filter "volume=$destination")"
      [[ -z "$consumers" ]] || die "Refusing to prune mounted destination volume: $destination"
      "$ENGINE" volume rm "$destination" >/dev/null
      log INFO "Removed destination volume: $destination"
    fi

    python3 - "$d" <<'PY'
import pathlib, shutil, sys
directory = pathlib.Path(sys.argv[1]).resolve()
for child in directory.iterdir():
    if child.name == ".lock":
        continue
    if child.is_dir() and not child.is_symlink():
        shutil.rmtree(child)
    else:
        child.unlink()
PY
    release_lock
    rmdir "$d" || die "Could not remove pruned state directory: $d"
    log INFO "Removed migration state: $migration"
  done <<< "$candidates"
}

parse(){
  [[ $# -gt 0 ]] || { usage; exit 1; }
  case "$1" in
    -h|--help|help) usage; exit 0;;
    -V|--version) echo "$PROGRAM $VERSION"; exit 0;;
    inventory|plan|hydrate|hydrate-set|cutover|rollback|status|unlock|prune|list) CMD="$1"; shift;;
    -*) die "Missing command. Expected one of: inventory, plan, hydrate, hydrate-set, cutover, rollback, status, unlock, prune, list";;
    *) die "Unknown command: $1";;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--compose-file)
        COMPOSE_FILE="$(option_value "$1" "${2-}")"
        COMPOSE_FILES+=("$COMPOSE_FILE")
        shift 2
        ;;
      --runtime) RUNTIME="$(option_value "$1" "${2-}")"; ENGINE=""; shift 2;;
      --compose-provider) COMPOSE_PROVIDER="$(option_value "$1" "${2-}")"; shift 2;;
      --project-name) PROJECT_NAME="$(option_value "$1" "${2-}")"; shift 2;;
      -s|--source-volume)
        SOURCE_VOLUME="$(option_value "$1" "${2-}")"
        SOURCE_VOLUMES+=("$SOURCE_VOLUME")
        shift 2
        ;;
      -d|--destination-volume) DEST_VOLUME="$(option_value "$1" "${2-}")"; shift 2;;
      --migration-id) MIGRATION_ID="$(option_value "$1" "${2-}")"; shift 2;;
      --verify) VERIFY_MODE="$(option_value "$1" "${2-}")"; shift 2;;
      --sync-mode) SYNC_MODE="$(option_value "$1" "${2-}")"; shift 2;;
      --capacity-margin) CAPACITY_MARGIN_PERCENT="$(option_value "$1" "${2-}")"; shift 2;;
      --auto-cutover) AUTO_CUTOVER=true; shift;;
      --execute) EXECUTE_SET=true; shift;;
      --retention-days) RETENTION_DAYS="$(option_value "$1" "${2-}")"; shift 2;;
      --jobs) CHECKSUM_JOBS="$(option_value "$1" "${2-}")"; shift 2;;
      --progress-interval) PROGRESS_INTERVAL="$(option_value "$1" "${2-}")"; shift 2;;
      --wait-health) WAIT_HEALTH="$(option_value "$1" "${2-}")"; shift 2;;
      --state-root) STATE_ROOT="$(option_value "$1" "${2-}")"; shift 2;;
      --force) FORCE=true; shift;;
      --dry-run) DRY_RUN=true; shift;;
      --) shift; [[ $# -eq 0 ]] || die "Unexpected positional argument: $1";;
      -h|--help) usage; exit 0;;
      -V|--version) echo "$PROGRAM $VERSION"; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done
}

validate_cli(){
  case "$RUNTIME" in auto|docker|podman) ;; *) die "--runtime must be auto, docker, or podman";; esac
  case "$COMPOSE_PROVIDER" in auto|native|docker-compose|podman-compose) ;; *) die "Invalid --compose-provider: $COMPOSE_PROVIDER";; esac
  case "$VERIFY_MODE" in metadata|size|checksum) ;; *) die "--verify must be metadata, size, or checksum";; esac
  case "$SYNC_MODE" in incremental|full) ;; *) die "--sync-mode must be incremental or full";; esac
  [[ "$WAIT_HEALTH" =~ ^[0-9]+$ && "$WAIT_HEALTH" -gt 0 ]] || die "--wait-health must be a positive integer"
  [[ "$CHECKSUM_JOBS" =~ ^[0-9]+$ && "$CHECKSUM_JOBS" -gt 0 ]] || die "--jobs must be a positive integer"
  [[ "$PROGRESS_INTERVAL" =~ ^[0-9]+$ && "$PROGRESS_INTERVAL" -gt 0 ]] || die "--progress-interval must be a positive integer"
  [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "--retention-days must be a non-negative integer"
  [[ "$CAPACITY_MARGIN_PERCENT" =~ ^[0-9]+$ && "$CAPACITY_MARGIN_PERCENT" -le 100 ]] || die "--capacity-margin must be an integer from 0 through 100"
  [[ -n "$STATE_ROOT" ]] || die "--state-root cannot be empty"
  if $EXECUTE_SET && [[ "$CMD" != "hydrate-set" && "$CMD" != "prune" ]]; then
    die "--execute is only valid with hydrate-set or prune"
  fi
  if $FORCE && [[ "$CMD" != "unlock" ]]; then
    die "--force is only valid with unlock"
  fi
  if [[ -n "$MIGRATION_ID" ]]; then validate_migration_id; fi
}

main(){
  parse "$@"
  validate_cli
  case "$CMD" in
    inventory) [[ -n "$COMPOSE_FILE" ]] || die "inventory requires --compose-file"; inventory;;
    plan)
      [[ "${#SOURCE_VOLUMES[@]}" -le 1 ]] || die "plan accepts one --source-volume; use hydrate-set for multiple volumes"
      [[ -n "$COMPOSE_FILE" && -n "$SOURCE_VOLUME" ]] || die "plan requires --compose-file and --source-volume"
      create_plan
      ;;
    hydrate)
      [[ "${#SOURCE_VOLUMES[@]}" -le 1 ]] || die "hydrate accepts one --source-volume; use hydrate-set for multiple volumes"
      [[ -n "$MIGRATION_ID" || ( -n "$COMPOSE_FILE" && -n "$SOURCE_VOLUME" ) ]] || die "hydrate requires an existing --migration-id or compose/source options"
      hydrate
      ;;
    hydrate-set)
      [[ -n "$COMPOSE_FILE" ]] || die "hydrate-set requires --compose-file"
      [[ -z "$MIGRATION_ID" ]] || die "hydrate-set creates separate resumable migration IDs; do not pass --migration-id"
      [[ -z "$DEST_VOLUME" ]] || die "hydrate-set creates unique destinations; do not pass --destination-volume"
      $AUTO_CUTOVER && die "hydrate-set does not allow automatic cutover; review and cut over migrations individually"
      hydrate_set
      ;;
    cutover) cutover;;
    rollback) rollback;;
    status) show_status;;
    unlock) need python3; unlock_migration;;
    prune) prune_migrations;;
    list) list_migrations;;
  esac
}
main "$@"
