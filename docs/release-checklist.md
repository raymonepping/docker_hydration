# Release checklist

Use this checklist for every release. A stable or major release should complete
the full integration matrix rather than relying only on static checks.

## 1. Confirm release scope

- [ ] Working tree changes are intentional and reviewed.
- [ ] The release type follows Semantic Versioning.
- [ ] User-facing behavior and compatibility changes are documented.
- [ ] No unrelated application data, migration state, or generated overrides
      are included.
- [ ] The root README and test guide match the current CLI.

For the first stable release, `0.1.1 → 1.0.0` is a major bump:

```bash
commit_gh --release major
```

## 2. Prepare the changelog

- [ ] Move shipped entries out of `[Unreleased]` into
      `## [X.Y.Z] - YYYY-MM-DD`.
- [ ] Add a fresh, empty `[Unreleased]` section above the release.
- [ ] Describe observable changes, migration considerations, and security
      fixes; avoid commit-log wording.
- [ ] Confirm the changelog version matches the intended tag.

Do this before running `commit_gh`, because the release command creates the
version commit and tag.

## 3. Static validation

Run from the repository root:

```bash
bash -n scripts/oci-volume-hydrate.sh test_setup/action.sh
shellcheck scripts/oci-volume-hydrate.sh test_setup/action.sh
git diff --check

./scripts/oci-volume-hydrate.sh --help
./scripts/oci-volume-hydrate.sh --version

docker compose \
  -f test_setup/docker-compose.yml \
  -f test_setup/docker-compose.reader.yml \
  config --quiet
```

- [ ] Bash syntax passes.
- [ ] ShellCheck passes without new suppressions that hide real defects.
- [ ] No whitespace errors are reported.
- [ ] Help documents every command and option.
- [ ] CLI version matches `VERSION`.
- [ ] The test Compose model renders successfully.

## 4. Safety and integration validation

Run the narrated default lifecycle:

```bash
./test_setup/action.sh
```

- [ ] Inventory discovers both configured and live consumers.
- [ ] Dry-run creates no volume, state, or container changes.
- [ ] Source byte and inode preflight succeeds.
- [ ] Hydration uses the expected helper fingerprint.
- [ ] Comprehensive hydration verification succeeds.
- [ ] Consumer-drift and destination-capacity checks run before cutover.
- [ ] Final incremental sync transfers only changed data.
- [ ] Both consumers start healthy on the destination mount.
- [ ] Destination-only content, ACL, and xattr survive reverse rollback.
- [ ] Both consumers return healthy on the source mount.
- [ ] Prune preview is non-destructive.
- [ ] Executed prune removes only the test destination and migration state.

Exercise full-copy mode with a smaller fixture:

```bash
./test_setup/action.sh --sync-mode full --payload-mb 256
```

- [ ] GNU tar preserves ownership, modes, links, ACLs, xattrs, and sparse
      files.
- [ ] Comprehensive verification passes after hydrate, cutover, and rollback.

For each runtime claimed as supported by the release:

- [ ] Run the applicable lifecycle on Docker and/or Podman.
- [ ] Record runtime and Compose provider versions in the release notes.
- [ ] Document any platform not tested instead of implying validation.

## 5. Failure-path spot checks

- [ ] Interrupt a disposable hydration after consumers stop and confirm source
      services recover.
- [ ] Confirm a Compose-file change blocks resume or cutover.
- [ ] Confirm consumer drift blocks cutover.
- [ ] Confirm insufficient byte or inode capacity blocks before copying.
- [ ] Confirm a stale local lock is recovered and an active lock is refused.
- [ ] Confirm a renderer failure falls back to raw output without masking the
      copy command's exit status.
- [ ] Confirm prune skips mounted, mislabeled, active, and locked candidates.

These checks must use the disposable fixture or explicitly created scratch
volumes—never an application volume.

## 6. Repository and security checks

```bash
git status --short --branch
git diff --cached --check
gitleaks git --redact
```

- [ ] No secrets, tokens, credentials, migration state, or generated volume
      contents are tracked.
- [ ] `.volume-hydrations/`, local test artifacts, and backup output remain
      ignored where applicable.
- [ ] Dependency and base-image changes have been reviewed.
- [ ] GitHub Actions configuration is valid and pinned actions remain current.

## 7. Tag and release

- [ ] Confirm the branch is `main` and synchronized with `origin/main`.
- [ ] Run `commit_gh --release <patch|minor|major>` or an explicit version.
- [ ] Confirm `VERSION`, the release commit, and tag all contain the same
      version.
- [ ] Confirm `main` and the tag were pushed.
- [ ] Confirm the GitHub release exists and generated notes are sensible.
- [ ] Confirm the Validation, Release, and Gitleaks workflows pass.

Useful verification commands:

```bash
git show --stat --oneline HEAD
git tag --points-at HEAD
gh release view "v$(cat VERSION)"
gh run list --limit 10
```

## 8. After release

- [ ] Re-read installation and quick-start commands from a clean checkout.
- [ ] Confirm `./scripts/oci-volume-hydrate.sh --version` reports the released
      version.
- [ ] Confirm a fresh `[Unreleased]` changelog section exists.
- [ ] Open follow-up issues for deferred work rather than changing the tagged
      release.
- [ ] Announce the release where appropriate.
