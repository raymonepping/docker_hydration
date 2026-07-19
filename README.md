# OCI volume hydration

`oci-volume-hydrate.sh` safely copies a Docker or Podman named volume, verifies
the result, and recreates only the affected Compose services on the new volume.
Migrations are non-destructive, resumable, and reversible: the original volume
is retained and rollback reverse-syncs changes before moving services back.

This tool is designed for Compose-managed named volumes. It does not modify the
original Compose files and it never deletes a source volume.

## Why use it?

- Discover the real runtime names and consumers of Compose volumes.
- Hydrate one volume or a selected set into uniquely named destinations.
- Minimize cutover downtime with an incremental final synchronization.
- Verify content, ownership, permissions, links, ACLs, and extended attributes.
- Detect Compose, helper-image, and consumer drift before cutover.
- Roll back without discarding writes made after cutover.
- Resume interrupted migrations from permission-restricted JSON state.

## Requirements

- Bash 3.2 or newer
- Python 3
- Docker or Podman and access to its daemon or socket
- A compatible Compose provider:
  - Docker Compose 2.20 or newer
  - legacy `docker-compose` 1.29 or newer
  - compatible Podman Compose provider 1.0 or newer
- Permission to pull and build the repository's helper image

The Compose provider must support `--profile '*'` and `config --format json`.
The script checks these capabilities before planning rather than assuming that
a provider with a recognizable version is compatible.

## Quick start

Inventory the rendered Compose volumes first. Repeat `--compose-file` in the
same order used to start the application:

```bash
./scripts/oci-volume-hydrate.sh inventory \
  --compose-file ../vault_reference/docker-compose.yml \
  --runtime docker
```

Use a value from the `RUNTIME_VOLUME` column as the source. Preview without
creating state, volumes, or stopping containers:

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file ../vault_reference/docker-compose.yml \
  --source-volume malware_scan_vault_1_data \
  --runtime docker \
  --dry-run
```

Create a persistent plan and hydrate it:

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file ../vault_reference/docker-compose.yml \
  --source-volume malware_scan_vault_1_data \
  --runtime docker

./scripts/oci-volume-hydrate.sh hydrate --migration-id MIGRATION_ID
```

Review the saved status, then cut over. Rollback remains available afterward:

```bash
./scripts/oci-volume-hydrate.sh status   --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh cutover  --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh rollback --migration-id MIGRATION_ID
```

The normal lifecycle is:

```text
plan → hydrate → cutover-ready → cutover → active-on-destination
                                            ↓
                                      rollback → rolled-back
```

Hydration stops and restarts only the services consuming the selected volume.
It does not cut them over unless `--auto-cutover` is explicitly supplied.

## Safety model

The script enforces the following invariants:

- The source is mounted read-only during forward copying and verification.
- The source is never deleted or reused as a destination.
- Every migration gets a unique destination and generated Compose override.
- Compose inputs, provider version, and helper image are fingerprinted in state.
- Source bytes and inodes are measured with a configurable capacity margin.
- Capacity is checked again against the destination immediately before syncing.
- Source consumers are rescanned immediately before cutover.
- Consumers are quiesced and checked again before the final synchronization.
- Health and live mount targets are validated after cutover and rollback.
- Failure or interruption after services stop triggers recovery on the
  authoritative volume.
- Rollback reverse-syncs destination changes before recreating services on the
  source.

The source and destination both remain available after cutover or rollback.
Deletion is a separate, guarded `prune --execute` operation.

## Inventory and volume sets

`inventory` distinguishes between the consumers rendered from Compose and the
containers actually mounting each volume. Hydrated destinations are shown in a
separate table with their migration IDs.

Preview all existing named volumes in a Compose application:

```bash
./scripts/oci-volume-hydrate.sh hydrate-set \
  --compose-file ../vault_reference/docker-compose.yml \
  --compose-file ../vault_reference/compose/compose.softhsm-config.yml \
  --runtime docker \
  --dry-run
```

Repeat `--source-volume` to select a subset. A real set hydration additionally
requires `--execute`, processes volumes sequentially, and never automatically
cuts them over. Each volume receives its own migration ID for individual review.

Always provide every Compose override that defines a live or stopped consumer
of the selected volumes. Profile-gated services are included automatically.

## Synchronization and verification

Incremental rsync is the default for initial hydration, final cutover, and
reverse rollback. It preserves ownership, modes, hard and symbolic links,
ACLs, extended attributes, and sparse files. It also removes target entries
that no longer exist on the authoritative side.

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file ../vault_reference/docker-compose.yml \
  --source-volume malware_scan_vault_1_data \
  --sync-mode incremental
```

Use `--sync-mode full` for a clear-and-GNU-tar copy. Full mode preserves the
same important filesystem properties. The synchronization mode is immutable
after planning; older saved migrations retain their recorded behavior.

New migrations default to `--verify comprehensive`, which compares:

- regular-file content hashes;
- entry types, numeric ownership, raw modes, link counts, and timestamps;
- symbolic-link targets and device numbers;
- numeric POSIX ACLs;
- extended attributes.

The lighter `metadata`, `size`, and `checksum` modes remain available when
their narrower guarantees are intentional. Verification mode is saved as a
migration invariant and cannot silently change during resume.

Checksums are parallelizable with `--jobs 4` and sorted before comparison for
deterministic results. Use `--capacity-margin 20` to change the default 10%
byte and inode headroom.

## Progress output

Interactive copy operations show a single updating progress bar. Redirected or
CI output uses timestamped progress lines instead.

```bash
./scripts/oci-volume-hydrate.sh hydrate \
  --migration-id MIGRATION_ID \
  --progress-style bar \
  --progress-interval 5
```

`--progress-style auto` is the default; `bar` and `log` force either form. The
renderer is best-effort: if it fails, raw copy output is drained and shown, and
the copy command's actual exit status remains authoritative.

## State, locks, and cleanup

State is stored as permission-restricted JSON under `.volume-hydrations/` by
default. Legacy `state.env` files are parsed by a restricted compatibility
reader and are never executed. Explicitly supplied operational settings such as
health timeout, checksum jobs, progress interval, and capacity margin override
saved values with a logged notice; migration invariants remain pinned.

Locks record PID, hostname, process start time, and a random ownership token.
Dead local locks are recovered automatically. Inspect or remove a stale lock:

```bash
./scripts/oci-volume-hydrate.sh unlock --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh unlock --migration-id MIGRATION_ID --force
```

Only force an unlock after confirming that no migration process is active.

Preview garbage collection before executing it:

```bash
./scripts/oci-volume-hydrate.sh prune \
  --runtime docker \
  --retention-days 30 \
  --dry-run

./scripts/oci-volume-hydrate.sh prune \
  --runtime docker \
  --retention-days 30 \
  --execute
```

Prune considers only inactive `planned`, `destination-created`,
`verification-failed`, and `rolled-back` migrations. It refuses mounted or
mislabeled destinations, never removes a source, and skips actively locked
candidates while continuing with the rest.

## Helper image

The managed helper image is tagged with the CLI version and a Dockerfile
fingerprint. Its immutable image ID is then pinned in migration state. The base
image is declared once through `ARG HELPER_BASE_IMAGE` in
`docker/volume-helper/Dockerfile`; pre-pull and build use that declaration.

If `HELPER_IMAGE` is overridden, the custom image must contain rsync, `pv`, GNU
tar, `getfacl`, `getfattr`, and the standard validation utilities checked by
preflight.

## Test safely

The disposable test project exercises a realistic multi-consumer volume with a
2 GiB mixed dataset, continuous writes, links, permissions, ACLs, and extended
attributes:

```bash
./test_setup/action.sh
```

It narrates inventory, dry-run, hydration, cutover, destination-only mutations,
reverse rollback, verification, and guarded pruning. See
[`test_setup/README.md`](test_setup/README.md) for options and manual commands.

## Continuous validation

The independent `Validation` GitHub Actions workflow runs Bash syntax checks,
ShellCheck, CLI/VERSION consistency, and Compose rendering. After those pass,
isolated Docker jobs exercise both incremental and full hydration lifecycles
with 256 MiB disposable fixtures.

The workflow runs for pull requests, pushes to `main`, and manual dispatch. It
has read-only repository permissions and does not create commits, tags, or
releases. Publishing and version changes remain the responsibility of the
project's separate `commit_gh` workflow.

## Scope and database warning

This is a filesystem-level volume migration tool, not an application-consistent
database backup utility. Before migrating stateful services, retain independent
native backups such as Vault Raft snapshots, PostgreSQL dumps/base backups, and
Couchbase backups. Application-specific quiescing and recovery requirements
still apply.

Run `./scripts/oci-volume-hydrate.sh --help` for the complete CLI reference.
