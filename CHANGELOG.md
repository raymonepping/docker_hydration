# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Comprehensive verification of file content, ownership, modes, links,
  timestamps, device metadata, POSIX ACLs, and extended attributes.
- A read-only GitHub Actions validation workflow covering Bash and Compose
  checks plus disposable incremental and full Docker hydration lifecycles.

### Changed

- The managed helper base image is declared once through
  `HELPER_BASE_IMAGE`, and full-copy mode now preserves ACLs, extended
  attributes, numeric ownership, and sparse files.
- New migrations use comprehensive verification by default.

### Deprecated

### Removed

### Fixed

- Progress-bar renderer failures now fall back to raw output without masking
  the copy command's real exit status or causing false recovery.

### Security
