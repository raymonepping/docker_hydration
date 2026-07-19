# OCI volume hydration

`oci-volume-hydrate.sh` performs a non-destructive, resumable copy of one
Docker or Podman named volume and can recreate the affected Compose services
on the verified destination.

The CLI version is read from the repository `VERSION` file, so releases and
`oci-volume-hydrate.sh --version` use the same source of truth. A standalone
copy can still display help or report version `unknown` when that sibling file
is absent, while operational commands fail clearly instead of using an
unversioned helper image.

The source volume is always mounted read-only during forward copies, is never
deleted, and remains the rollback target. Services using it are stopped during
copying so the destination is internally consistent. If copying, verification,
or override generation fails, the script attempts to restart those services on
the authoritative volume.

## Requirements

- Bash 3.2 or newer
- Python 3
- Docker with current Compose v2, or Podman with a compatible Compose provider
- Access to the selected container runtime
- Permission to build the repository helper image for volume synchronization

The Compose provider must support `--profile '*'` and
`config --format json`. The script extracts and records its semantic version,
requires Docker Compose 2.20+, legacy `docker-compose` 1.29+, or a compatible
Podman Compose provider 1.0+, and executes feature probes before planning.

The preflight verifies helper capabilities, records the immutable helper image
ID, measures source bytes and inodes, and requires both plus a configurable 10%
margin. The check is repeated against the actual destination after it is
created. It also fingerprints every Compose input. A resumed hydration,
cutover, or rollback stops before changing volumes or containers if a Compose
file, Compose version, or helper image has changed. The managed helper's base
image comes from `ARG HELPER_BASE_IMAGE` in its Dockerfile; the pre-pull and
build use that same declaration so the two cannot silently drift apart.

## Discover volumes

Commands require a subcommand before their options. Start with `inventory` to
obtain the rendered runtime names, including external-volume mappings:

```bash
./scripts/oci-volume-hydrate.sh inventory \
  --compose-file ../vault_reference/docker-compose.yml \
  --runtime docker
```

Use the value in the `RUNTIME_VOLUME` column as `--source-volume`.
`CONFIGURED_CONSUMERS` comes from the rendered Compose model, while
`LIVE_CONSUMERS` reports current container mounts and states. Hydrated
destination volumes are listed separately with their migration IDs, making a
completed cutover visible even though the original Compose file still declares
the retained source volume.

Preview hydration plans for every existing named volume without changing
anything:

```bash
./scripts/oci-volume-hydrate.sh hydrate-set \
  --compose-file ../vault_reference/docker-compose.yml \
  --compose-file ../vault_reference/compose/compose.softhsm-config.yml \
  --runtime docker \
  --dry-run
```

Repeat `--source-volume` to preview a subset. Set hydration never cuts services
over automatically. After reviewing the preview, real set hydration additionally
requires `--execute`; each volume receives its own resumable migration ID. Pass
every Compose override that defines a live or stopped consumer of the selected
volumes; profile-gated services are included automatically.

## Plan and hydrate

Validate a migration and save its state without changing application
containers or volumes. The first non-dry incremental plan may build the local
`oci-volume-hydrate-helper:<version>-<definition-hash>` image from
`docker/volume-helper/Dockerfile`:

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file ../vault_reference/docker-compose.yml \
  --source-volume malware_scan_vault_1_data \
  --runtime docker
```

For a validation-only preview that writes no state, add `--dry-run`.
On a new installation, build the helper once before the first incremental dry
run, or run a non-dry plan and let the script build and pin it automatically.

Run hydration with the same inputs, or resume using the migration ID printed by
`plan`:

```bash
./scripts/oci-volume-hydrate.sh hydrate --migration-id MIGRATION_ID
```

Hydration creates a uniquely named destination, stops only services consuming
the source, copies the data, comprehensively verifies content and metadata, generates a
Compose override, and restarts the original services. It does not cut over
unless `--auto-cutover` is explicitly supplied. Auto-cutover proceeds directly
from the quiesced, verified copy into the final synchronization, avoiding an
unnecessary intermediate restart on the source.

Incremental rsync is the default for initial hydration, final cutover sync, and
reverse rollback sync. It enables rsync's delta algorithm even for the local
volume-to-volume transfer, preserves ownership, modes, links, ACLs, extended
attributes and sparse files, stays on the mounted filesystem, and deletes
destination entries that no longer exist at the authoritative source:

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file ../vault_reference/docker-compose.yml \
  --source-volume malware_scan_vault_1_data \
  --sync-mode incremental
```

Use `--sync-mode full` to retain the clear-and-tar behavior. The selected mode
is saved with the migration and cannot change while resuming it. Existing
migrations created before sync modes were introduced remain on `full` for
compatibility. Override `HELPER_IMAGE` only with an image containing rsync,
`pv`, GNU tar, `getfacl`, `getfattr`, and the validation utilities checked by
preflight.

`--verify comprehensive` is the default for new migrations. It compares file
content, entry types, ownership, modes, link counts, timestamps, symbolic-link
targets, device numbers, numeric ACLs, and extended attributes. The lighter
`metadata`, `size`, and `checksum` modes remain available when their narrower
guarantees are intentional. A resumed migration keeps the verification mode
recorded in its state.

Use `--capacity-margin 20` to change the byte and inode safety margin.

Long copies and manifest builds emit periodic elapsed-time messages. Use
`--progress-interval 30` to adjust the interval and `--jobs 4` to checksum files
in parallel; checksum output is sorted before comparison so verification stays
deterministic. On resumed operational commands, explicitly supplied
`--wait-health`, `--jobs`, `--progress-interval`, and `--capacity-margin`
override their saved values and the change is logged. Migration invariants such
as synchronization and verification mode continue to come from saved state.

Copy operations display a single updating progress bar when stderr is attached
to an interactive terminal. Non-interactive runs retain timestamped periodic
messages suitable for CI logs. Use `--progress-style bar` to force the bar or
`--progress-style log` to force line-oriented output; `auto` is the default.
The bar renderer is best-effort: if terminal rendering itself fails, the tool
warns, drains the remaining raw copy output, and preserves the copy command's
actual result instead of triggering a false migration failure.

## Cut over, inspect, and roll back

```bash
./scripts/oci-volume-hydrate.sh status   --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh cutover  --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh rollback --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh list
```

Cutover recreates only affected services using the generated override and
waits for them to become running or healthy. Immediately before cutover it
rescans the source volume and aborts if its logical service/mount consumers
differ from the saved plan. After quiescing it verifies that no running consumer
remains, performs and verifies a final source-to-destination sync, then validates
both container health and live volume mounts. A failed check reverse-syncs to
the source and rolls back. A later explicit rollback also quiesces consumers,
checks the destination has no running consumers, and reverse-syncs destination
changes before switching. Immediately before each directional sync, the script
remeasures both volumes and the target filesystem and enforces byte and inode
headroom with the configured safety margin. Both source and destination volumes
are retained.

## Locks, state, and cleanup

New state is stored as permission-restricted JSON under `.volume-hydrations/`.
Legacy `state.env` is read by a restricted compatibility parser and is never
executed. Locks include PID, host, process-start time, and a random ownership
token; dead local locks are recovered automatically. To inspect or deliberately
remove one:

```bash
./scripts/oci-volume-hydrate.sh unlock --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh unlock --migration-id MIGRATION_ID --force
```

`--force` is required if the recorded process is still alive or belongs to a
different host. Verify that no migration process is active before forcing it.

Old inactive migrations can be garbage-collected. Preview is mandatory unless
`--execute` is explicit:

```bash
./scripts/oci-volume-hydrate.sh prune --runtime docker --retention-days 30 --dry-run
./scripts/oci-volume-hydrate.sh prune --runtime docker --retention-days 30 --execute
```

Only `planned`, `destination-created`, `verification-failed`, and `rolled-back`
JSON migrations are eligible. Prune refuses mounted volumes or volumes whose
ownership labels do not match, and never removes a source volume. Active,
verified, cutover-ready, and active-on-destination migrations are excluded.
If an eligible migration is actively locked, prune logs and skips it, continues
with the remaining candidates, and reports removed and skipped-lock totals.

## Important database note

Hydration is a storage-level migration, not a substitute for application-native
backups. Keep separate Vault Raft snapshots and native PostgreSQL/Couchbase
backups before migrating those services.

Run `./scripts/oci-volume-hydrate.sh --help` for all options.
