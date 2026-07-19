# Safe end-to-end test setup

This disposable Compose project exercises `oci-volume-hydrate.sh` without
touching an application stack. It uses one named volume and two consumers:

- `writer` seeds a mixed dataset and continuously appends timestamped heartbeat
  and JSONL records.
- `reader` mounts the same volume read-only and periodically displays the data
  it can observe.

The Compose project name is fixed to `oci_hydrate_test`, so the source volume
is always `oci_hydrate_test_demo_data` regardless of the current directory.

## What the fixture contains

The default dataset is an idempotent 2 GiB fixture with:

- 128 MiB large chunks and 4 MiB medium objects;
- thousands of 64 KiB records;
- nested and empty directories;
- a hard link and a symbolic link;
- varied file permissions;
- an explicit numeric POSIX ACL;
- an extended attribute;
- 16 continuously updated JSONL shards and a heartbeat log.

Seeding uses a staging directory, so an interrupted build is replaced safely.
A matching completed dataset is reused on later runs. Use `--payload-mb` to set
the fixture size from 64 MiB through 8 GiB.

## Run the narrated lifecycle

From the repository root—or any other directory—run:

```bash
./test_setup/action.sh
```

The story prints every command and validation while it:

1. Builds or reuses the versioned, fingerprinted helper image.
2. Starts the writer and read-only reader.
3. Validates the fixture, ACL, xattr, and continuous writes.
4. Inventories the source volume and both consumers.
5. Previews the migration with `--dry-run`.
6. Hydrates and comprehensively verifies a unique destination.
7. Final-syncs and cuts both consumers over.
8. Creates destination-only content, an ACL, and an xattr.
9. Reverse-syncs and rolls back to the source.
10. Proves all destination-only changes reached the original source.
11. Previews and executes guarded pruning for only that migration.
12. Confirms both services are running on the retained source volume.

Each invocation uses an isolated temporary state root. A fixture-level lock
prevents concurrent story runs from manipulating the shared test containers.
On failure, the fixture and migration state are retained for inspection.

Useful variants:

```bash
./test_setup/action.sh --sync-mode full
./test_setup/action.sh --payload-mb 4096
./test_setup/action.sh --progress-style bar
./test_setup/action.sh --progress-style log --progress-interval 2
./test_setup/action.sh --jobs 4
./test_setup/action.sh --keep-migration
./test_setup/action.sh --help
```

Incremental synchronization and comprehensive verification are the defaults.
The writer and reader intentionally remain running on the source after a
successful story so the result can be inspected or another run can reuse the
fixture.

GitHub's independent `Validation` workflow runs this story in isolated Docker
jobs for both synchronization modes with a 256 MiB fixture. CI cleanup removes
only resources using the test project's fixed naming convention; local runs
retain the source fixture as described above.

## Manual setup

Start both Compose files together:

```bash
docker compose \
  -f test_setup/docker-compose.yml \
  -f test_setup/docker-compose.reader.yml \
  up -d

docker compose \
  -f test_setup/docker-compose.yml \
  -f test_setup/docker-compose.reader.yml \
  ps

docker exec oci_hydrate_test_writer tail -n 5 /data/heartbeat.log
docker logs oci_hydrate_test_reader --tail 6
```

Inventory and preview from the repository root:

```bash
./scripts/oci-volume-hydrate.sh inventory \
  --compose-file test_setup/docker-compose.yml \
  --compose-file test_setup/docker-compose.reader.yml \
  --runtime docker

./scripts/oci-volume-hydrate.sh plan \
  --compose-file test_setup/docker-compose.yml \
  --compose-file test_setup/docker-compose.reader.yml \
  --source-volume oci_hydrate_test_demo_data \
  --runtime docker \
  --dry-run
```

Create a resumable migration, hydrate, and cut over:

```bash
./scripts/oci-volume-hydrate.sh plan \
  --compose-file test_setup/docker-compose.yml \
  --compose-file test_setup/docker-compose.reader.yml \
  --source-volume oci_hydrate_test_demo_data \
  --runtime docker

./scripts/oci-volume-hydrate.sh hydrate --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh status   --migration-id MIGRATION_ID
./scripts/oci-volume-hydrate.sh cutover  --migration-id MIGRATION_ID
```

After writing test data on the destination, reverse-sync and return both
services to the original source:

```bash
./scripts/oci-volume-hydrate.sh rollback --migration-id MIGRATION_ID
```

## Cleanup

The story prunes only its own rolled-back destination and state unless
`--keep-migration` is supplied. To stop the fixture afterward:

```bash
docker compose \
  -f test_setup/docker-compose.yml \
  -f test_setup/docker-compose.reader.yml \
  down
```

The named source volume remains. Remove it only when its test data is no longer
needed:

```bash
docker volume rm oci_hydrate_test_demo_data
```

For retained migration state, always preview pruning before execution:

```bash
./scripts/oci-volume-hydrate.sh prune --runtime docker --retention-days 0 --dry-run
./scripts/oci-volume-hydrate.sh prune --runtime docker --retention-days 0 --execute
```
