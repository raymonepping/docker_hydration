#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HYDRATOR="${PROJECT_ROOT}/scripts/oci-volume-hydrate.sh"
HELPER_CONTEXT="${PROJECT_ROOT}/docker/volume-helper"
VERSION_FILE="${PROJECT_ROOT}/VERSION"
BASE_COMPOSE="${SCRIPT_DIR}/docker-compose.yml"
READER_COMPOSE="${SCRIPT_DIR}/docker-compose.reader.yml"
SOURCE_VOLUME="oci_hydrate_test_demo_data"
WRITER_CONTAINER="oci_hydrate_test_writer"
READER_CONTAINER="oci_hydrate_test_reader"
SYNC_MODE="incremental"
CHECKSUM_JOBS=2
CAPACITY_MARGIN=10
PROGRESS_INTERVAL=2
PROGRESS_STYLE="auto"
PAYLOAD_MB=2048
KEEP_MIGRATION=false
MIGRATION_ID="storybook-$(date -u +%Y%m%dT%H%M%SZ)-$$"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
STATE_ROOT="${TEMP_BASE}/oci-volume-hydrate-storybook-${MIGRATION_ID}"
ACTION_LOCK="${TEMP_BASE}/oci-volume-hydrate-storybook.lock"
ACTION_LOCK_OWNED=false
DESTINATION_VOLUME=""
CURRENT_STEP="initialization"

if [[ -t 1 ]]; then
  BLUE=$'\033[1;34m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  BLUE="" GREEN="" YELLOW="" RESET=""
fi

usage(){ cat <<USAGE
Usage: ${0##*/} [options]

Run a narrated, disposable hydration lifecycle against the local writer/reader
Compose fixture. The source fixture is left running after the story completes.

Options:
  --sync-mode MODE       incremental or full (default: incremental)
  --jobs COUNT           Parallel checksum workers (default: 2)
  --capacity-margin PCT  Byte/inode safety margin (default: 10)
  --progress-interval S  Progress message interval (default: 2)
  --progress-style STYLE auto, bar, or log (default: auto)
  --payload-mb SIZE      Multi-file fixture size in MiB (default: 2048)
  --keep-migration       Keep the rolled-back destination and migration state
  -h, --help             Show this help

Lifecycle:
  start -> validate -> inventory -> dry-run -> hydrate -> cutover
        -> destination write -> rollback -> verify -> prune
USAGE
}

die(){ printf '%s[ERROR]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

file_sha256(){
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

step(){
  CURRENT_STEP="$1"
  printf '\n%s=== Step %s: %s ===%s\n' "$BLUE" "$2" "$1" "$RESET"
}

note(){ printf '%s[story]%s %s\n' "$GREEN" "$RESET" "$*"; }

run(){
  printf '  $'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

on_exit(){
  local exit_status=$?
  trap - EXIT INT TERM
  if $ACTION_LOCK_OWNED; then
    rm -f "$ACTION_LOCK/owner.pid"
    rmdir "$ACTION_LOCK" 2>/dev/null || true
    ACTION_LOCK_OWNED=false
  fi
  if [[ "$exit_status" -ne 0 ]]; then
    printf '\n%s[FAILED]%s Story stopped during: %s\n' "$YELLOW" "$RESET" "$CURRENT_STEP" >&2
    printf 'The fixture was left available for inspection.\n' >&2
    if [[ -f "$STATE_ROOT/$MIGRATION_ID/state.json" ]]; then
      printf 'Migration state: %s/%s/state.json\n' "$STATE_ROOT" "$MIGRATION_ID" >&2
      "$HYDRATOR" status --state-root "$STATE_ROOT" --migration-id "$MIGRATION_ID" >&2 || true
    fi
  fi
  exit "$exit_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_action_lock(){
  local owner_pid=""
  if ! mkdir "$ACTION_LOCK" 2>/dev/null; then
    [[ -f "$ACTION_LOCK/owner.pid" ]] && IFS= read -r owner_pid < "$ACTION_LOCK/owner.pid"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      die "Another storybook run is active with PID $owner_pid"
    fi
    rm -f "$ACTION_LOCK/owner.pid"
    rmdir "$ACTION_LOCK" 2>/dev/null || die "Cannot recover stale storybook lock: $ACTION_LOCK"
    mkdir "$ACTION_LOCK" || die "Cannot acquire storybook lock: $ACTION_LOCK"
  fi
  printf '%s\n' "$$" > "$ACTION_LOCK/owner.pid"
  ACTION_LOCK_OWNED=true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sync-mode) [[ $# -ge 2 ]] || die "$1 requires a value"; SYNC_MODE="$2"; shift 2 ;;
    --jobs) [[ $# -ge 2 ]] || die "$1 requires a value"; CHECKSUM_JOBS="$2"; shift 2 ;;
    --capacity-margin) [[ $# -ge 2 ]] || die "$1 requires a value"; CAPACITY_MARGIN="$2"; shift 2 ;;
    --progress-interval) [[ $# -ge 2 ]] || die "$1 requires a value"; PROGRESS_INTERVAL="$2"; shift 2 ;;
    --progress-style) [[ $# -ge 2 ]] || die "$1 requires a value"; PROGRESS_STYLE="$2"; shift 2 ;;
    --payload-mb) [[ $# -ge 2 ]] || die "$1 requires a value"; PAYLOAD_MB="$2"; shift 2 ;;
    --keep-migration) KEEP_MIGRATION=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

case "$SYNC_MODE" in incremental|full) ;; *) die "--sync-mode must be incremental or full" ;; esac
[[ "$CHECKSUM_JOBS" =~ ^[0-9]+$ && "$CHECKSUM_JOBS" -gt 0 ]] || die "--jobs must be a positive integer"
[[ "$CAPACITY_MARGIN" =~ ^[0-9]+$ && "$CAPACITY_MARGIN" -le 100 ]] || die "--capacity-margin must be between 0 and 100"
[[ "$PROGRESS_INTERVAL" =~ ^[0-9]+$ && "$PROGRESS_INTERVAL" -gt 0 ]] || die "--progress-interval must be positive"
case "$PROGRESS_STYLE" in auto|bar|log) ;; *) die "--progress-style must be auto, bar, or log" ;; esac
[[ "$PAYLOAD_MB" =~ ^[0-9]+$ && "$PAYLOAD_MB" -ge 64 && "$PAYLOAD_MB" -le 8192 ]] || die "--payload-mb must be from 64 through 8192"

need docker
need python3
[[ -x "$HYDRATOR" ]] || die "Hydration script is not executable: $HYDRATOR"
[[ -f "$BASE_COMPOSE" && -f "$READER_COMPOSE" ]] || die "Compose fixture files are missing"
[[ -r "$VERSION_FILE" && -f "$HELPER_CONTEXT/Dockerfile" ]] || die "Helper build inputs are missing"
docker info >/dev/null 2>&1 || die "Docker is unavailable"
docker compose version >/dev/null 2>&1 || die "Docker Compose is unavailable"
acquire_action_lock
mkdir -p "$STATE_ROOT"
export HYDRATE_TEST_PAYLOAD_MB="$PAYLOAD_MB"

COMPOSE=(docker compose -f "$BASE_COMPOSE" -f "$READER_COMPOSE")
COMMON=(
  --runtime docker
  --state-root "$STATE_ROOT"
  --migration-id "$MIGRATION_ID"
  --progress-style "$PROGRESS_STYLE"
)
PLAN_INPUTS=(
  --compose-file "$BASE_COMPOSE"
  --compose-file "$READER_COMPOSE"
  --source-volume "$SOURCE_VOLUME"
  --sync-mode "$SYNC_MODE"
  --verify checksum
  --jobs "$CHECKSUM_JOBS"
  --capacity-margin "$CAPACITY_MARGIN"
  --progress-interval "$PROGRESS_INTERVAL"
)

step "Prepare the fingerprinted progress helper" 0
IFS= read -r tool_version < "$VERSION_FILE"
helper_sha="$(file_sha256 "$HELPER_CONTEXT/Dockerfile")"
helper_image="oci-volume-hydrate-helper:$tool_version-${helper_sha:0:12}"
installed_sha="$(docker image inspect -f '{{ index .Config.Labels "io.hydrate.helper-definition-sha" }}' "$helper_image" 2>/dev/null || true)"
if [[ "$installed_sha" == "$helper_sha" ]]; then
  note "Helper is current: $helper_image"
else
  run docker build --label "io.hydrate.helper-definition-sha=$helper_sha" -t "$helper_image" "$HELPER_CONTEXT"
  note "Built helper with rsync and pv progress support."
fi

step "Start both Compose services" 1
run "${COMPOSE[@]}" up -d

step "Validate the running fixture" 2
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
  writer_status="$(docker inspect -f '{{.State.Status}}' "$WRITER_CONTAINER" 2>/dev/null || true)"
  reader_status="$(docker inspect -f '{{.State.Status}}' "$READER_CONTAINER" 2>/dev/null || true)"
  fixture_ready=false
  if [[ "$writer_status" == running ]] && docker exec "$WRITER_CONTAINER" test -f /data/.fixture-ready 2>/dev/null; then
    fixture_ready=true
  fi
  [[ "$writer_status" == running && "$reader_status" == running && "$fixture_ready" == true ]] && break
  sleep 1
done
[[ "${writer_status:-}" == running && "${reader_status:-}" == running && "${fixture_ready:-false}" == true ]] ||
  die "Fixture containers did not become ready within 300 seconds"
sleep 3
run "${COMPOSE[@]}" ps
note "Dataset size and shape exercise large files, thousands of small files, links, permissions, and empty directories:"
run docker exec "$WRITER_CONTAINER" sh -ceu 'du -sh /data/dataset; printf "regular files: "; find /data/dataset -type f | wc -l; printf "directories: "; find /data/dataset -type d | wc -l; printf "links: "; find /data/dataset -type l | wc -l'
note "Writer heartbeat proves the source volume is changing:"
run docker exec "$WRITER_CONTAINER" tail -n 5 /data/heartbeat.log
note "Reader output proves the second read-only consumer sees the same data:"
run docker logs "$READER_CONTAINER" --tail 6

step "Inventory the source and both consumers" 3
run "$HYDRATOR" inventory \
  --compose-file "$BASE_COMPOSE" \
  --compose-file "$READER_COMPOSE" \
  --runtime docker

step "Preview the migration without changing state" 4
run "$HYDRATOR" plan "${PLAN_INPUTS[@]}" "${COMMON[@]}" --dry-run

step "Hydrate and verify the destination" 5
run "$HYDRATOR" hydrate "${PLAN_INPUTS[@]}" "${COMMON[@]}"
run "$HYDRATOR" status "${COMMON[@]}"
STATE_FILE="$STATE_ROOT/$MIGRATION_ID/state.json"
[[ -f "$STATE_FILE" ]] || die "Migration state was not created: $STATE_FILE"
DESTINATION_VOLUME="$(python3 - "$STATE_FILE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["destination_volume"])
PY
)"
[[ -n "$DESTINATION_VOLUME" ]] || die "Migration state has no destination volume"
note "Hydration is verified; services are intentionally still on $SOURCE_VOLUME."
source_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$WRITER_CONTAINER")"
[[ "$source_mount" == "$SOURCE_VOLUME" ]] || die "Writer is not on the source after hydration: $source_mount"

step "Cut over after consumer-drift and final-sync checks" 6
run "$HYDRATOR" cutover "${COMMON[@]}"
destination_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$WRITER_CONTAINER")"
[[ "$destination_mount" == "$DESTINATION_VOLUME" ]] || die "Writer did not move to the destination: $destination_mount"
note "Live writer mount: $destination_mount"
run docker exec "$WRITER_CONTAINER" tail -n 5 /data/heartbeat.log

step "Create data that exists only after cutover" 7
MARKER="storybook-marker-$MIGRATION_ID"
run docker exec "$WRITER_CONTAINER" sh -ceu 'printf "%s\n" "$1" >> /data/rollback-marker.txt' sh "$MARKER"
run docker exec "$WRITER_CONTAINER" grep -Fx "$MARKER" /data/rollback-marker.txt

step "Rollback using $SYNC_MODE reverse synchronization" 8
run "$HYDRATOR" rollback "${COMMON[@]}"
rolled_back_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$WRITER_CONTAINER")"
[[ "$rolled_back_mount" == "$SOURCE_VOLUME" ]] || die "Writer did not return to the source: $rolled_back_mount"
run docker exec "$WRITER_CONTAINER" grep -Fx "$MARKER" /data/rollback-marker.txt
note "The destination-only marker is now present on the original source."
run "$HYDRATOR" status "${COMMON[@]}"

step "Clean up only the rolled-back migration" 9
if $KEEP_MIGRATION; then
  note "--keep-migration selected; retained $DESTINATION_VOLUME and $STATE_FILE"
else
  run "$HYDRATOR" prune --state-root "$STATE_ROOT" --retention-days 0 --dry-run
  run "$HYDRATOR" prune --state-root "$STATE_ROOT" --retention-days 0 --runtime docker --execute
  if docker volume inspect "$DESTINATION_VOLUME" >/dev/null 2>&1; then
    die "Prune did not remove the hydrated destination: $DESTINATION_VOLUME"
  fi
  rmdir "$STATE_ROOT" 2>/dev/null || true
  note "Prune removed only the hydrated destination and migration state."
fi

step "Final validation" 10
run "${COMPOSE[@]}" ps
run docker exec "$WRITER_CONTAINER" tail -n 5 /data/heartbeat.log
final_mount="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$WRITER_CONTAINER")"
[[ "$final_mount" == "$SOURCE_VOLUME" ]] || die "Final writer mount is unexpected: $final_mount"

printf '\n%s=== Story complete ===%s\n' "$GREEN" "$RESET"
note "Hydrate, $SYNC_MODE cutover, destination write, reverse rollback, and prune all passed."
note "Writer and reader remain running on $SOURCE_VOLUME for another run."
