#!/usr/bin/env bats
# Tests for bin/ebs-snapshot-backup.sh. Run with:  bats tests/
#
# No AWS account is needed: tests/helpers/fake-aws stands in for the AWS CLI
# (the script calls "$AWS_BIN", which we point at the fake). Each test writes
# what "AWS" should return into $FAKE_AWS_DIR, runs the script, then checks
# what it did by reading $FAKE_AWS_DIR/calls.log.

SCRIPT="${BATS_TEST_DIRNAME}/../bin/ebs-snapshot-backup.sh"

setup() {
  FAKE_AWS_DIR="$(mktemp -d)"
  export FAKE_AWS_DIR
  export AWS_BIN="${BATS_TEST_DIRNAME}/helpers/fake-aws"
  export EBS_BACKUP_LOCK_FILE="${FAKE_AWS_DIR}/lock"
  export AWS_REGION=us-east-1
  unset AWS_PROFILE EBS_BACKUP_REGIONS
  : >"$FAKE_AWS_DIR/calls.log"
}

teardown() {
  rm -rf "$FAKE_AWS_DIR"
}

# ISO timestamp N days ago, in the format the AWS CLI prints.
days_ago() { date -u -d "-$1 days" +%Y-%m-%dT%H:%M:%S.000Z; }
hours_ago() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%S.000Z; }

# Helper: add one managed snapshot row.
# snapshot <id> <volume> <timestamp> [state] [retention-days] [keep] [instance]
snapshot() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-completed}" "${5:-None}" "${6:-None}" "${7:-None}" \
    >>"$FAKE_AWS_DIR/snapshots.txt"
}

instance() { # instance <id> [name] [retention]
  printf '%s\t%s\t%s\n' "$1" "${2:-None}" "${3:-None}" >>"$FAKE_AWS_DIR/instances.txt"
}

calls() { cat "$FAKE_AWS_DIR/calls.log"; }

# ----------------------------------------------------------------- arguments

@test "--help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown option fails with exit 1" {
  run "$SCRIPT" --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option: --nope"* ]]
}

@test "non-numeric retention is rejected" {
  run "$SCRIPT" --retention-days thirty
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a non-negative integer"* ]]
}

@test "--backup-only and --prune-only together are rejected" {
  run "$SCRIPT" --backup-only --prune-only
  [ "$status" -eq 1 ]
}

# ----------------------------------------------------------------- backup

@test "snapshots every running instance tagged Backup=true" {
  instance i-aaa web-1
  instance i-bbb db-1
  printf 'vol-root\nvol-data\n' >"$FAKE_AWS_DIR/volumes-i-bbb"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"created=3"* ]]
  # The discovery filter asks only for RUNNING instances with the right tag.
  grep -q 'Name=instance-state-name,Values=running Name=tag:Backup,Values=true' "$FAKE_AWS_DIR/calls.log"
  [ "$(grep -c 'create-snapshots' "$FAKE_AWS_DIR/calls.log")" -eq 2 ]
}

@test "snapshots are tagged so retention can find them later" {
  instance i-aaa web-1
  run "$SCRIPT" --backup-only
  [ "$status" -eq 0 ]
  call="$(grep create-snapshots "$FAKE_AWS_DIR/calls.log")"
  [[ "$call" == *'"Key":"ManagedBy","Value":"ebs-snapshot-backup"'* ]]
  [[ "$call" == *'"Key":"ebs-backup:instance-id","Value":"i-aaa"'* ]]
  [[ "$call" == *'"Key":"ebs-backup:retention-days","Value":"30"'* ]]
  [[ "$call" == *'"Key":"Name","Value":"web-1 backup '* ]]
}

@test "custom tag key/value is used for selection" {
  run "$SCRIPT" --tag-key Snapshot --tag-value daily --backup-only
  [ "$status" -eq 0 ]
  grep -q 'Name=tag:Snapshot,Values=daily' "$FAKE_AWS_DIR/calls.log"
}

@test "instance tag BackupRetentionDays overrides the default" {
  instance i-aaa web-1 90
  run "$SCRIPT" --backup-only
  [ "$status" -eq 0 ]
  grep create-snapshots "$FAKE_AWS_DIR/calls.log" | grep -q '"Key":"ebs-backup:retention-days","Value":"90"'
}

@test "volumes tagged Backup=false are excluded and boot volume can be skipped" {
  instance i-aaa
  echo "vol-scratch" >"$FAKE_AWS_DIR/excluded-i-aaa"
  run "$SCRIPT" --backup-only --exclude-boot-volume
  [ "$status" -eq 0 ]
  call="$(grep create-snapshots "$FAKE_AWS_DIR/calls.log")"
  [[ "$call" == *'"ExcludeBootVolume":true'* ]]
  [[ "$call" == *'"ExcludeDataVolumeIds":["vol-scratch"]'* ]]
}

@test "idempotent: an instance backed up recently is skipped" {
  instance i-aaa
  snapshot snap-recent vol-1 "$(hours_ago 2)" completed 30 None i-aaa
  run "$SCRIPT" --backup-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"already backed up"* ]]
  [[ "$output" == *"created=0 skipped=1"* ]]
  [ "$(grep -c create-snapshots "$FAKE_AWS_DIR/calls.log")" -eq 0 ]
}

@test "a backup older than the minimum interval does not block a new one" {
  instance i-aaa
  snapshot snap-old vol-1 "$(hours_ago 30)" completed 30 None i-aaa
  run "$SCRIPT" --backup-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"created=1"* ]]
}

@test "no tagged instances is not an error" {
  run "$SCRIPT" --backup-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"no running instances tagged Backup=true"* ]]
}

@test "a failed snapshot is reported and the run exits 2" {
  instance i-aaa
  touch "$FAKE_AWS_DIR/fail-create-snapshots"
  run "$SCRIPT" --backup-only
  [ "$status" -eq 2 ]
  [[ "$output" == *"snapshot failed"* ]]
  [[ "$output" == *"errors=1"* ]]
}

@test "--wait waits for the new snapshots" {
  instance i-aaa
  run "$SCRIPT" --backup-only --wait
  [ "$status" -eq 0 ]
  grep -q 'wait snapshot-completed --snapshot-ids snap-i-aaa-1' "$FAKE_AWS_DIR/calls.log"
}

# ----------------------------------------------------------------- retention

@test "deletes managed snapshots older than the retention period" {
  snapshot snap-new  vol-1 "$(days_ago 1)"
  snapshot snap-old  vol-1 "$(days_ago 45)"
  snapshot snap-old2 vol-1 "$(days_ago 60)"
  run "$SCRIPT" --prune-only
  [ "$status" -eq 0 ]
  [ "$(sort "$FAKE_AWS_DIR/deleted" | tr '\n' ' ')" = "snap-old snap-old2 " ]
  [[ "$output" == *"deleted=2"* ]]
}

@test "retention only lists snapshots tagged ManagedBy=ebs-snapshot-backup" {
  run "$SCRIPT" --prune-only
  [ "$status" -eq 0 ]
  grep -q 'describe-snapshots --owner-ids self --filters Name=tag:ManagedBy,Values=ebs-snapshot-backup' "$FAKE_AWS_DIR/calls.log"
}

@test "keep-minimum protects the newest snapshot even when it is old" {
  snapshot snap-a vol-1 "$(days_ago 40)"
  snapshot snap-b vol-1 "$(days_ago 50)"
  snapshot snap-c vol-2 "$(days_ago 90)"   # only snapshot of vol-2 (e.g. volume deleted)
  run "$SCRIPT" --prune-only --keep-minimum 1
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_AWS_DIR/deleted")" = "snap-b" ]
  [[ "$output" == *"kept=2"* ]]
}

@test "per-snapshot retention tag is honoured" {
  snapshot snap-long vol-1 "$(days_ago 1)"
  snapshot snap-90   vol-1 "$(days_ago 45)" completed 90
  snapshot snap-7    vol-1 "$(days_ago 10)" completed 7
  run "$SCRIPT" --prune-only
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_AWS_DIR/deleted")" = "snap-7" ]
}

@test "snapshots tagged ebs-backup:keep or still pending are never deleted" {
  snapshot snap-new   vol-1 "$(days_ago 1)"
  snapshot snap-keep  vol-1 "$(days_ago 40)" completed None true
  snapshot snap-pend  vol-1 "$(days_ago 41)" pending
  run "$SCRIPT" --prune-only
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_AWS_DIR/deleted" ]
  [[ "$output" == *"kept=2"* ]]
}

@test "snapshot in use by an AMI is kept with a warning, not an error" {
  snapshot snap-new vol-1 "$(days_ago 1)"
  snapshot snap-ami vol-1 "$(days_ago 40)"
  echo snap-ami >"$FAKE_AWS_DIR/in-use"
  run "$SCRIPT" --prune-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"in use by an AMI"* ]]
  [[ "$output" == *"errors=0"* ]]
}

# ----------------------------------------------------------------- dry run

@test "dry run changes nothing and proves permissions with EC2 DryRun" {
  instance i-aaa
  snapshot snap-new vol-1 "$(days_ago 1)"
  snapshot snap-old vol-1 "$(days_ago 45)"
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$FAKE_AWS_DIR/deleted" ]
  grep -q 'create-snapshots.*--dry-run' "$FAKE_AWS_DIR/calls.log"
  grep -q 'delete-snapshot --snapshot-id snap-old --dry-run' "$FAKE_AWS_DIR/calls.log"
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"would delete"* ]]
}

@test "dry run reports missing IAM permissions" {
  instance i-aaa
  touch "$FAKE_AWS_DIR/unauthorized"
  run "$SCRIPT" --dry-run --backup-only
  [ "$status" -eq 2 ]
  [[ "$output" == *"UnauthorizedOperation"* ]]
}

# ----------------------------------------------------------------- regions, logging, locking

@test "multiple regions are processed in order" {
  run "$SCRIPT" --regions "us-east-1, eu-west-1" --backup-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"== Region us-east-1 =="*"== Region eu-west-1 =="* ]]
}

@test "--all-regions asks EC2 for the enabled regions" {
  run "$SCRIPT" --all-regions --backup-only
  [ "$status" -eq 0 ]
  grep -q 'describe-regions' "$FAKE_AWS_DIR/calls.log"
  [[ "$output" == *"== Region eu-west-1 =="* ]]
}

@test "a region whose snapshots cannot be listed is reported, others continue" {
  touch "$FAKE_AWS_DIR/fail-describe-snapshots"
  run "$SCRIPT" --regions us-east-1,eu-west-1
  [ "$status" -eq 2 ]
  [[ "$output" == *"errors=2"* ]]
}

@test "JSON log format emits one valid JSON object per line" {
  instance i-aaa 'web "quoted" name'
  run "$SCRIPT" --backup-only --log-format json
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    echo "$line" | jq -e . >/dev/null
  done <<<"$output"
}

@test "--profile is passed to every AWS call" {
  run "$SCRIPT" --profile prod --backup-only
  [ "$status" -eq 0 ]
  # every call except `aws --version` must carry the profile
  [ -z "$(grep -v -e '--profile prod' -e '^--version' "$FAKE_AWS_DIR/calls.log")" ]
}

@test "a second concurrent run is refused by the lock" {
  exec 8>"$EBS_BACKUP_LOCK_FILE"
  flock -n 8
  run "$SCRIPT" --backup-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Another run holds"* ]]
  exec 8>&-
}

# ----------------------------------------------------------------- unit tests (sourced functions)

# Sourcing the script (instead of running it) gives access to its functions;
# we do it in a child bash so its strict mode does not leak into bats.
@test "to_epoch understands both AWS CLI timestamp styles" {
  run bash -c "source '$SCRIPT'; to_epoch 2026-01-01T00:00:00.000Z; to_epoch 2026-01-01T00:00:00.123000+00:00"
  [ "$status" -eq 0 ]
  [ "$output" = $'1767225600\n1767225600' ]
}

@test "json_escape escapes quotes and backslashes" {
  run bash -c "source '$SCRIPT'; json_escape 'a\"b\\c'"
  [ "$status" -eq 0 ]
  [ "$output" = 'a\"b\\c' ]
}
