# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-05

### Added
- `bin/ebs-snapshot-backup.sh`: crash-consistent multi-volume snapshots (`create-snapshots`) of running instances tagged `Backup=true`, with per-volume opt-out, an optional boot-volume exclusion, per-instance retention override and tagging for traceability.
- Retention that deletes only snapshots the tool created, honours per-snapshot retention, always keeps the newest N per volume, and skips `ebs-backup:keep`, pending and AMI-backed snapshots.
- Dry run through EC2 `DryRun` (proves IAM permissions), idempotent re-runs (minimum interval), locking, multi-region / all-regions, text or JSON logs, and exit codes 0/1/2.
- Least-privilege IAM policy, systemd service + timer, cron entry, scheduled GitHub Actions example.
- 30 bats tests with a fake AWS CLI, ShellCheck and CI.
- Beginner guide in `docs/LEARN.md`.
