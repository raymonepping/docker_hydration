# Test setup for oci-volume-hydrate.sh

A disposable Compose project to exercise the hydration tool end to end
without touching a real stack.

- `docker-compose.yml` — one named volume (`demo_data`) and one live
  consumer (`writer`) that seeds a few files on first boot, then keeps
  appending timestamped lines to `heartbeat.log` every 2 seconds for as
  long as the container runs. This gives every hydrate/cutover/rollback run
  real, continuously-changing data instead of a static fixture, so you can
  check afterwards that no ticks were lost.
- `docker-compose.reader.yml` — an override file adding a second consumer
  (`reader`) that mounts the same volume read-only and tails the heartbeat
  log. Pass both files together (`-f docker-compose.yml -f
  docker-compose.reader.yml`) so the tool has more than one service to
  discover, quiesce, and recreate — the same multi-file pattern used against
  real stacks.

Project name is pinned to `oci_hydrate_test` in the compose file, so the
runtime volume is always `oci_hydrate_test_demo_data` regardless of which
directory you run from.

## Bring the stack up

```bash
cd test_setup
docker compose -f docker-compose.yml -f docker-compose.reader.yml up -d
docker compose -f docker-compose.yml -f docker-compose.reader.yml ps
docker exec oci_hydrate_test_writer tail -n 5 /data/heartbeat.log
```

## Run the tool against it

From the repo root:

```bash
# Discover the runtime volume name and current consumers
./scripts/oci-volume-hydrate.sh inventory \
  --compose-file test_setup/docker-compose.yml \
  --compose-file test_setup/docker-compose.reader.yml \
  --runtime docker

# Validate a migration plan without changing anything
./scripts/oci-volume-hydrate.sh plan \
  --compose-file test_setup/docker-compose.yml \
  --compose-file test_setup/docker-compose.reader.yml \
  --source-volume oci_hydrate_test_demo_data \
  --runtime docker \
  --dry-run

# Hydrate for real (stops/restarts writer+reader, copies, verifies, does not cut over)
./scripts/oci-volume-hydrate.sh plan \
  --compose-file test_setup/docker-compose.yml \
  --compose-file test_setup/docker-compose.reader.yml \
  --source-volume oci_hydrate_test_demo_data \
  --runtime docker
# note the printed MIGRATION_ID, then:
./scripts/oci-volume-hydrate.sh hydrate --migration-id MIGRATION_ID

# Cut services over to the verified destination
./scripts/oci-volume-hydrate.sh cutover --migration-id MIGRATION_ID

# Confirm no heartbeat ticks were lost across the cutover
docker exec oci_hydrate_test_writer tail -n 5 /data/heartbeat.log

# Roll back to the original volume (reverse-syncs destination writes first)
./scripts/oci-volume-hydrate.sh rollback --migration-id MIGRATION_ID
```

## Tear down

```bash
docker compose -f docker-compose.yml -f docker-compose.reader.yml down
docker volume rm oci_hydrate_test_demo_data  # only if you also want the data gone
```

If a cutover was performed, also remove the hydrated destination volume once
you're done, or run `./scripts/oci-volume-hydrate.sh prune --runtime docker
--retention-days 0 --dry-run` (then `--execute`) to clean up eligible
migration state.
