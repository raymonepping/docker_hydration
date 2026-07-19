# OCI volume hydration

`oci-volume-hydrate.sh` performs a non-destructive, resumable copy of one
Docker or Podman named volume and can recreate the affected Compose services
on the verified destination.

The source volume is always mounted read-only, is never deleted, and remains
the rollback target. Services using it are stopped during copying so the
destination is internally consistent. If copying, verification, or override
generation fails, the script attempts to restart those services on the source.

## Requirements

- Bash 3.2 or newer
- Python 3
- Docker with Docker Compose, or Podman with a compatible Compose provider
- Access to the selected container runtime

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

## Cut over, inspect, and roll back

```bash
./scripts/oci-volume-hydrate.sh status   --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh cutover  --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh rollback --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh list
```

Cutover recreates only affected services using the generated override and
waits for them to become running or healthy. A failed health or mount check
triggers rollback. Both source and destination volumes are retained.

## Important database note

Hydration is a storage-level migration, not a substitute for application-native
backups. Keep separate Vault Raft snapshots and native PostgreSQL/Couchbase
backups before migrating those services.

Run `./scripts/oci-volume-hydrate.sh --help` for all options.
