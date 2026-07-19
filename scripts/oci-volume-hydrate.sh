#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

PROGRAM="${0##*/}"
VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_ROOT="${STATE_ROOT:-${PROJECT_ROOT}/.volume-hydrations}"
HELPER_IMAGE="${HELPER_IMAGE:-alpine:3.20}"
COMPOSE_FILE=""
COMPOSE_FILES=()
COMPOSE_DIGESTS=()
PROJECT_NAME=""
SOURCE_VOLUME=""
SOURCE_VOLUMES=()
DEST_VOLUME=""
MIGRATION_ID=""
VERIFY_MODE="checksum"
DRY_RUN=false
AUTO_CUTOVER=false
EXECUTE_SET=false
FORCE=false
WAIT_HEALTH=120
RETENTION_DAYS=30
CHECKSUM_JOBS=1
PROGRESS_INTERVAL=15
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
ACTIVE_PID=""

log(){ printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ log ERROR "$*"; exit 1; }
run(){ if $DRY_RUN; then printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
safe(){ printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'; }
now(){ date -u +%Y%m%dT%H%M%SZ; }
option_value(){ local option="$1" value="${2-}"; [[ -n "$value" ]] || die "$option requires a value"; printf '%s' "$value"; }
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
  $PROGRAM list

Commands:
  inventory  Show Compose named volumes, consumers, runtime names, and status
  plan       Validate one source volume and create a resumable migration plan
  hydrate    Copy and verify one planned volume without cutting over
  hydrate-set
             Preview all existing Compose volumes, or hydrate them sequentially
             with --execute; --source-volume may be repeated to select a subset
  cutover    Recreate affected services on the verified destination volume
  rollback   Recreate affected services on the retained source volume
  status     Show a migration's saved state
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
  --auto-cutover            Cut over after successful hydration
  --execute                 Required for a non-dry-run hydrate-set
  --wait-health SECONDS     Health-check timeout (default: 120)
  --state-root DIR          State directory (default: <project>/.volume-hydrations)
  --dry-run                 Validate and preview without writing or stopping
  -h, --help                Show help

Safety invariants:
  * Source is mounted read-only during hydration and verification.
  * Original Compose YAML is never modified.
  * Source volume is never deleted by this program.
  * Destination is never reused across unrelated migrations.
  * Cutover uses a generated Compose override.
  * Rollback recreates services on the original volume.
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
    owner_data="$(python3 - "$owner_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    owner = json.load(handle)
print(f"{owner.get('pid', '')}\t{owner.get('hostname', '')}\t{owner.get('process_start', '')}")
PY
)" || die "Invalid lock owner metadata; use --force to remove it"
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
    "$PROJECT_NAME" "$SOURCE_VOLUME" "$DEST_VOLUME" "$VERIFY_MODE" "${ENGINE:-$RUNTIME}" \
    "$COMPOSE_PROVIDER" "${STATUS:-planned}" "${CONSUMERS:-}" "${SERVICES:-}" \
    "${MOUNT_TARGETS:-}" "$HELPER_IMAGE" "${HELPER_IMAGE_ID:-}" "${SOURCE_BYTES:-}" \
    "${CREATED_UTC:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json
import os
import sys

(path, migration_id, compose_file, compose_files, compose_digests, project_name,
 source_volume, dest_volume, verify_mode, runtime, compose_provider, status,
 consumers, services, mount_targets, helper_image, helper_image_id, source_bytes,
 created_utc, updated_utc) = sys.argv[1:]
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
    "runtime": runtime,
    "compose_provider": compose_provider,
    "status": status,
    "consumers": consumers,
    "services": services,
    "mount_targets": mount_targets,
    "helper_image": helper_image,
    "helper_image_id": helper_image_id,
    "source_bytes": int(source_bytes) if source_bytes else None,
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
  [[ -n "$MIGRATION_ID" ]] || die "--migration-id is required"
  validate_migration_id
  migration_exists || die "Migration not found: $MIGRATION_ID"
  acquire_lock
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
    "RUNTIME": "runtime", "COMPOSE_PROVIDER": "compose_provider",
    "STATUS": "status", "CONSUMERS": "consumers", "SERVICES": "services",
    "MOUNT_TARGETS": "mount_targets", "HELPER_IMAGE": "helper_image",
    "HELPER_IMAGE_ID": "helper_image_id", "SOURCE_BYTES": "source_bytes",
    "CREATED_UTC": "created_utc", "UPDATED_UTC": "updated_utc",
}
for shell_name, json_name in mapping.items():
    value = state.get(json_name)
    print(f"{shell_name}={shlex.quote('' if value is None else str(value))}")
for shell_name, json_name in (("COMPOSE_FILES", "compose_files"), ("COMPOSE_DIGESTS", "compose_digests")):
    values = state.get(json_name) or []
    print(f"{shell_name}=({' '.join(shlex.quote(str(value)) for value in values)})")
PY
)" || die "Invalid migration state: $(state_file)"
    eval "$assignments"
  else
    [[ ! -L "$(legacy_state_file)" ]] || die "Refusing symlinked legacy state: $(legacy_state_file)"
    log WARN "Loading legacy executable state once; it will be migrated to JSON on the next state update"
    # shellcheck disable=SC1090
    source "$(legacy_state_file)"
  fi
  if [[ "${#COMPOSE_FILES[@]}" -eq 0 ]]; then COMPOSE_FILES=("$COMPOSE_FILE"); fi
  ENGINE="$RUNTIME"
  resolve_runtime
  resolve_compose_provider
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

ensure_helper_image(){
  if ! "$ENGINE" image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
    $DRY_RUN && die "Helper image is not local: $HELPER_IMAGE (pull it before dry-run)"
    log INFO "Pulling helper image before service downtime: $HELPER_IMAGE"
    "$ENGINE" pull "$HELPER_IMAGE" >/dev/null
  fi
  HELPER_IMAGE_ID="$("$ENGINE" image inspect -f '{{.Id}}' "$HELPER_IMAGE")"
  "$ENGINE" run --rm "$HELPER_IMAGE" sh -ceu \
    'command -v tar; command -v find; command -v stat; command -v sha256sum; command -v sort; command -v xargs' \
    >/dev/null
}

verify_helper_image(){
  local current
  current="$("$ENGINE" image inspect -f '{{.Id}}' "$HELPER_IMAGE" 2>/dev/null)" ||
    die "Planned helper image is unavailable: $HELPER_IMAGE"
  if [[ -n "$HELPER_IMAGE_ID" && "$current" != "$HELPER_IMAGE_ID" ]]; then
    die "Helper image changed since planning: $HELPER_IMAGE"
  fi
  HELPER_IMAGE_ID="$current"
}

measure_source_and_capacity(){
  local metrics available
  metrics="$("$ENGINE" run --rm -v "$SOURCE_VOLUME:/source:ro" "$HELPER_IMAGE" sh -ceu '
    bytes=$(du -sk /source | awk "{print \$1 * 1024}")
    available=$(df -Pk /source | awk "NR == 2 {print \$4 * 1024}")
    printf "%s %s\n" "$bytes" "$available"
  ')"
  read -r SOURCE_BYTES available <<< "$metrics"
  [[ "$SOURCE_BYTES" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || die "Could not measure source size and runtime capacity"
  log INFO "Source size: ${SOURCE_BYTES} bytes; runtime free space: ${available} bytes"
  if (( SOURCE_BYTES + SOURCE_BYTES / 10 > available )); then
    die "Insufficient runtime space: require source size plus 10% safety margin"
  fi
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

label_value(){
  local id="$1" key="$2"
  "$ENGINE" inspect -f "{{ index .Config.Labels \"$key\" }}" "$id" 2>/dev/null || true
}

compose_project_label(){
  local id="$1" value
  value="$(label_value "$id" com.docker.compose.project)"
  [[ -n "$value" ]] || value="$(label_value "$id" io.podman.compose.project)"
  printf '%s' "$value"
}

compose_service_label(){
  local id="$1" value
  value="$(label_value "$id" com.docker.compose.service)"
  [[ -n "$value" ]] || value="$(label_value "$id" io.podman.compose.service)"
  printf '%s' "$value"
}

all_volume_consumers(){
  local id name ids
  ids="$("$ENGINE" ps -aq --filter "volume=$SOURCE_VOLUME")"
  while read -r id; do
    [[ -n "$id" ]] || continue
    while read -r name; do
      [[ "$name" == "$SOURCE_VOLUME" ]] && { printf '%s\n' "$id"; break; }
    done < <("$ENGINE" inspect -f '{{range .Mounts}}{{println .Name}}{{end}}' "$id" 2>/dev/null)
  done <<< "$ids"
  return 0
}

inspect_consumers(){
  local ids id project service target rows="" services="" targets=""
  ids="$(all_volume_consumers)"
  [[ -n "$ids" ]] || die "No containers mount source volume: $SOURCE_VOLUME"
  while read -r id; do
    [[ -n "$id" ]] || continue
    project="$(compose_project_label "$id")"
    service="$(compose_service_label "$id")"
    [[ -n "$project" && -n "$service" ]] || die "Container $id mounts the volume but is not Compose-managed"
    if [[ -z "$PROJECT_NAME" ]]; then PROJECT_NAME="$project"; fi
    [[ "$project" == "$PROJECT_NAME" ]] || die "Volume is shared with Compose project '$project'; expected '$PROJECT_NAME'"
    target="$("$ENGINE" inspect -f "{{range .Mounts}}{{if eq .Name \"$SOURCE_VOLUME\"}}{{.Destination}}{{end}}{{end}}" "$id")"
    rows+="$id|$service|$target"$'\n'
    services+="$service"$'\n'
    targets+="$service|$target"$'\n'
  done <<< "$ids"
  CONSUMERS="$(printf '%s' "$rows" | sed '/^$/d' | sort -u)"
  SERVICES="$(printf '%s' "$services" | sed '/^$/d' | sort -u | paste -sd, -)"
  MOUNT_TARGETS="$(printf '%s' "$targets" | sed '/^$/d' | sort -u)"
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
  log INFO "$description: $from_volume -> $to_volume"
  run_with_progress "$description" "$ENGINE" run --rm \
    -v "$from_volume:/source:ro" \
    -v "$to_volume:/destination" \
    "$HELPER_IMAGE" sh -ceu '
      test -d /source && test -d /destination
      find /destination -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      cd /source
      set -o pipefail 2>/dev/null || true
      tar cpf - . | tar xpf - -C /destination
      sync
    '
}

hydrate_data(){
  assert_destination_owned
  sync_volume_data "$SOURCE_VOLUME" "$DEST_VOLUME" "Hydrating volume"
  STATUS="copied"; save_state
}

manifest_volume(){
  local volume="$1" output="$2" mode="$3"
  case "$mode" in
    metadata)
      run_with_progress "Metadata manifest for $volume" \
        "$ENGINE" run --rm -v "$volume:/data:ro" "$HELPER_IMAGE" sh -ceu '
        cd /data
        find . -xdev -print0 | sort -z | xargs -0 -r stat -c "%F|%n|%s|%a|%u|%g" 2>/dev/null
      ' > "$output"
      ;;
    size)
      run_with_progress "Size manifest for $volume" \
        "$ENGINE" run --rm -v "$volume:/data:ro" "$HELPER_IMAGE" sh -ceu '
        cd /data
        find . -xdev -type f -print0 | sort -z | xargs -0 -r stat -c "%n|%s|%a|%u|%g" 2>/dev/null
      ' > "$output"
      ;;
    checksum)
      run_with_progress "Checksum manifest for $volume" \
        "$ENGINE" run --rm -v "$volume:/data:ro" "$HELPER_IMAGE" sh -ceu '
        jobs="$1"
        cd /data
        find . -xdev -type f -print0 | sort -z | xargs -0 -r -n 32 -P "$jobs" sha256sum | LC_ALL=C sort
        find . -xdev ! -type f -print0 | sort -z | xargs -0 -r stat -c "META|%F|%n|%a|%u|%g" 2>/dev/null
      ' sh "$CHECKSUM_JOBS" > "$output"
      ;;
    *) die "Unknown verification mode: $mode" ;;
  esac
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
  local id project service
  while read -r id; do
    [[ -n "$id" ]] || continue
    project="$(compose_project_label "$id")"
    service="$(compose_service_label "$id")"
    [[ "$project" == "$PROJECT_NAME" && -n "$service" ]] || continue
    [[ ",$SERVICES," == *",$service,"* ]] && printf '%s|%s\n' "$id" "$service"
  done < <("$ENGINE" ps -aq)
  return 0
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
  [[ "$STATUS" == "cutover-ready" || "$STATUS" == "rolled-back" ]] || die "Migration is not cutover-ready; current status: $STATUS"
  verify_compose_digests
  assert_destination_owned

  RECOVERY_TARGET="original"
  RESTART_ON_FAILURE=true
  log INFO "Quiescing consumers for final synchronization"
  stop_services
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
  verify_compose_digests
  case "$STATUS" in
    active-on-destination|cutover-starting|rollback-syncing) rollback_internal true ;;
    cutover-ready|rolled-back) rollback_internal false ;;
    *) die "Migration cannot be rolled back from status: $STATUS" ;;
  esac
  log INFO "Rollback complete. Both volumes retained and source is current."
}

hydrate(){
  local resumed=false
  if [[ -n "$MIGRATION_ID" ]] && migration_exists; then
    load_state
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
    destination-created) stop_consumers ;;
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
  load_state
  if [[ ! -f "$(state_file)" ]]; then save_state; fi
  python3 -m json.tool "$(state_file)"
}
list_migrations(){
  [[ -d "$STATE_ROOT" ]] || exit 0
  find "$STATE_ROOT" -mindepth 2 -maxdepth 2 \( -name state.json -o -name state.env \) -print |
    sed 's#/state\.json$##;s#/state\.env$##' | sort -u
}

parse(){
  [[ $# -gt 0 ]] || { usage; exit 1; }
  case "$1" in
    -h|--help|help) usage; exit 0;;
    -V|--version) echo "$PROGRAM $VERSION"; exit 0;;
    inventory|plan|hydrate|hydrate-set|cutover|rollback|status|list) CMD="$1"; shift;;
    -*) die "Missing command. Expected one of: inventory, plan, hydrate, hydrate-set, cutover, rollback, status, list";;
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
      --auto-cutover) AUTO_CUTOVER=true; shift;;
      --execute) EXECUTE_SET=true; shift;;
      --wait-health) WAIT_HEALTH="$(option_value "$1" "${2-}")"; shift 2;;
      --state-root) STATE_ROOT="$(option_value "$1" "${2-}")"; shift 2;;
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
  [[ "$WAIT_HEALTH" =~ ^[0-9]+$ && "$WAIT_HEALTH" -gt 0 ]] || die "--wait-health must be a positive integer"
  [[ -n "$STATE_ROOT" ]] || die "--state-root cannot be empty"
  if $EXECUTE_SET && [[ "$CMD" != "hydrate-set" ]]; then
    die "--execute is only valid with hydrate-set"
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
    list) list_migrations;;
  esac
}
main "$@"
