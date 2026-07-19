# OCI volume hydration

`oci-volume-hydrate.sh` performs a non-destructive, resumable copy of one
Docker or Podman named volume and can recreate the affected Compose services
on the verified destination.

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
- A local or pullable `alpine:3.20` helper image (override with `HELPER_IMAGE`)

The Compose provider must support `--profile '*'` and
`config --format json`; preflight reports a clear error if it does not.

The preflight verifies helper capabilities, records the immutable helper image
ID, measures the source, requires source size plus a 10% free-space margin, and
fingerprints every Compose input. A later cutover or rollback stops before
downtime if a Compose file or helper image has changed.

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

Validate a migration and save its state without changing containers or
volumes:

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file ../vault_reference/docker-compose.yml \
  --source-volume malware_scan_vault_1_data \
  --runtime docker
```

For a validation-only preview that writes no state, add `--dry-run`.

Run hydration with the same inputs, or resume using the migration ID printed by
`plan`:

```bash
./scripts/oci-volume-hydrate.sh hydrate --migration-id MIGRATION_ID
```

Hydration creates a uniquely named destination, stops only services consuming
the source, copies the data, verifies checksums and metadata, generates a
Compose override, and restarts the original services. It does not cut over
unless `--auto-cutover` is explicitly supplied.

Long copies and manifest builds emit periodic elapsed-time messages. Use
`--progress-interval 30` to adjust the interval and `--jobs 4` to checksum files
in parallel; checksum output is sorted before comparison so verification stays
deterministic.

## Cut over, inspect, and roll back

```bash
./scripts/oci-volume-hydrate.sh status   --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh cutover  --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh rollback --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh list
```

Cutover recreates only affected services using the generated override and
waits for them to become running or healthy. Immediately before cutover it
quiesces consumers, performs and verifies a final source-to-destination sync,
then validates both container health and the live volume mounts. A failed check
reverse-syncs to the source and rolls back. A later explicit rollback also
quiesces consumers and reverse-syncs destination changes before switching.
Both source and destination volumes are retained.

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

## Important database note

Hydration is a storage-level migration, not a substitute for application-native
backups. Keep separate Vault Raft snapshots and native PostgreSQL/Couchbase
backups before migrating those services.

Run `./scripts/oci-volume-hydrate.sh --help` for all options.
