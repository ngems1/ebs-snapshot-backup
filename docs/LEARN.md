# Learn: EBS snapshots and a production-grade Bash script (junior-friendly guide)

This guide explains **what the script does, why, and the Bash / AWS techniques it uses**. Read it once with `bin/ebs-snapshot-backup.sh` open next to it.

---

## 1. Background: volumes, snapshots and retention

| Term | Plain-English meaning |
|---|---|
| **EC2 instance** | A virtual server in AWS. |
| **EBS volume** | The server's virtual hard disk. One instance can have several (root/boot disk + data disks). |
| **Snapshot** | A point-in-time **backup** of a volume, stored in S3 by AWS. You can create a new volume from it to restore. |
| **Incremental** | After the first snapshot, AWS only stores the blocks that **changed**. Daily snapshots are much cheaper than daily full copies. |
| **Crash-consistent** | The backup looks like the disk did at the moment the power was pulled. Fine for most apps; databases recover the way they would after a power cut. |
| **Retention** | How long backups are kept. Keeping them forever is expensive; keeping them too short means you can't restore last month's data. 30 days is a common default. |
| **Tag** | A `Key=Value` label on an AWS resource. We use tags to **select** what to back up (`Backup=true`) and to **recognise** what we created (`ManagedBy=ebs-snapshot-backup`). |

### What the script does, step by step

```
for each region:
    list snapshots WE created (tag ManagedBy=ebs-snapshot-backup)      <- one API call
    BACKUP
      find RUNNING instances tagged Backup=true
      for each instance:
          skip it if we already backed it up in the last 20 hours     <- idempotency
          create-snapshots for ALL its volumes at the same moment      <- crash-consistent set
          tag every snapshot (who, when, how long to keep it)
    RETENTION
      for each snapshot WE created, newest first per volume:
          too young?                      keep
          one of the newest N for volume? keep   (safety net)
          tagged ebs-backup:keep?         keep   (legal hold, investigation...)
          not completed yet?              keep
          otherwise                       delete (an AMI still using it -> keep + warn)
print a summary and exit 0 (ok) / 1 (fatal) / 2 (some errors)
```

---

## 2. The golden safety rule: only delete what you created

The most dangerous line in any backup script is the one that **deletes**. This script:

1. tags every snapshot it creates with `ManagedBy=ebs-snapshot-backup`;
2. asks AWS **only** for snapshots with that tag (`--filters Name=tag:ManagedBy,...`), so it never even *sees* other teams' snapshots;
3. is backed by an **IAM policy** that only allows `ec2:DeleteSnapshot` on snapshots carrying that tag (`iam/ebs-snapshot-backup-policy.json`). Even if the script had a bug, AWS itself would refuse to delete anything else.

This is **defence in depth**: the code is careful, and the permissions make carelessness impossible.

---

## 3. Bash techniques used (and why)

### 3.1 Strict mode

```bash
set -euo pipefail
IFS=$'\n\t'
```

| Setting | Without it | With it |
|---|---|---|
| `-e` | A failed command is ignored and the script keeps going with bad data | The script stops at the first unexpected failure |
| `-u` | `$VOLUMEID` (typo) silently becomes an empty string | Using an unset variable is an error |
| `-o pipefail` | `aws ... \| sort` "succeeds" even if `aws` failed | The pipeline fails if **any** part fails |
| `IFS=$'\n\t'` | Unquoted values split on spaces (`My Server` → two words) | Values only split on newlines/tabs |

> **Gotcha:** `set -e` is *switched off* inside anything used as a condition (`if cmd`, `cmd || other`, `cmd && other`). That's why the script checks AWS calls explicitly, like `if ! out="$(aws ...)"; then error ...`, instead of trusting `-e` alone.

### 3.2 Quoting

Always write `"$var"`, not `$var`. Unquoted variables are split into words and expanded as wildcards (`*`), which is a top source of bugs. ShellCheck (run in CI) flags every unquoted variable.

### 3.3 Arrays for command arguments

```bash
local args=(--region "$region")
[[ -n "$PROFILE" ]] && args+=(--profile "$PROFILE")
"$AWS_BIN" "${args[@]}" "$@"
```

Building a command in an **array** keeps each argument intact, even ones containing spaces. Building it in a string (`cmd="aws --region $r"`) breaks as soon as a value contains a space.

### 3.4 `--query` instead of `jq`

```bash
aws ec2 describe-instances ... \
  --query 'Reservations[].Instances[].[InstanceId, (Tags[?Key==`Name`].Value)[0]]' \
  --output text
```

`--query` is **JMESPath**, built into the AWS CLI, so the script has no extra dependency. `--output text` prints one row per item, columns separated by **tabs**, which Bash reads easily:

```bash
while IFS=$'\t' read -r instance_id name retention; do ... done <<<"$instances"
```

Missing values print as `None`, so the script checks for the string `None`.

### 3.5 Logging to stderr, data to stdout

`log()` writes to **stderr** (`>&2`). This keeps stdout free for data and lets `--log-format json` produce one JSON object per line, ready for CloudWatch Logs Insights, Splunk and similar tools.

### 3.6 Locking

```bash
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another run holds $LOCK_FILE"
```

If cron starts a new run while yesterday's is still going (say AWS was slow), two runs could double-snapshot or race on deletes. `flock` lets only one run hold the lock. macOS has no `flock`, so the script falls back to `mkdir`, which is also atomic: only one process can create a directory.

### 3.7 `trap ... EXIT`

`on_exit` runs whenever the script ends, for any reason. It releases the lock and prints a message if strict mode stopped the script without one. Scripts that "die silently" are very hard to debug from cron.

### 3.8 Sourcing for tests

```bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

When you **run** the file, `main` runs. When a test **sources** it (`source bin/ebs-snapshot-backup.sh`), only the functions are loaded, so the tests can call `to_epoch` or `json_escape` directly.

### 3.9 Portable dates

GNU `date` (Linux) and BSD `date` (macOS) take different flags. The script detects which one it has once (`DATE_FLAVOUR`), and every date calculation goes through two small functions (`to_epoch`, `epoch_to_date`). Times are always handled in **UTC** (`date -u`), so daylight-saving changes can't shift retention by an hour.

---

## 4. Idempotency: safe to run twice

> *Idempotent* means running something twice has the same effect as running it once.

- **Backups:** before snapshotting an instance, the script checks whether one of *its* snapshots for that instance is newer than `--min-interval-hours` (20 h by default). A retry after a failure, or an accidental second cron run, creates no duplicates.
- **Retention:** deleting an already-deleted snapshot is reported as "already gone", not as an error.
- **Locking** prevents two overlapping runs.

---

## 5. Dry run that actually tests something

Many scripts implement `--dry-run` as "print what I would do". This one goes further. It calls the real API with EC2's `--dry-run` flag, and AWS answers:

- `DryRunOperation`: "you *would* have been allowed"; or
- `UnauthorizedOperation`: "your IAM permissions are missing".

So a dry run also **tests the IAM policy**, without creating or deleting anything.

> **Limitation:** AWS's dry-run only checks permissions. It can't tell that a snapshot is used by an AMI, so the dry run may say "would delete" for a snapshot that the real run will keep, with a warning.

---

## 6. How the tests work without AWS

`tests/helpers/fake-aws` is a tiny Bash program that **pretends to be the AWS CLI**:

- The script runs `"$AWS_BIN"`, and the tests set `AWS_BIN=tests/helpers/fake-aws`.
- Each test writes what "AWS" should answer into files: `instances.txt`, `snapshots.txt`, `in-use`, `fail-create-snapshots` and so on.
- The fake logs every call to `calls.log`, so tests can check *what the script asked AWS to do*, e.g. that delete was called with `--dry-run`, or never called at all.

This technique (replacing an external dependency with a fake) is called a **test double**. It makes the 30 tests fast, free and safe to run anywhere.

Run them:

```bash
sudo apt-get install bats jq     # macOS: brew install bats-core jq
bats tests/
```

---

## 7. Exercises

1. Run `bats tests/ --filter keep-minimum` and read the test. Change `--keep-minimum` to 2 in the test: which snapshot survives now, and why?
2. Add a `--tag-snapshots-with KEY=VALUE` option that adds an extra tag to every snapshot (hint: look at how `tags+=` builds the JSON, and use `json_escape`). Write a bats test for it.
3. Make the script copy snapshots to a second region for disaster recovery (`aws ec2 copy-snapshot --source-region ...`). What new IAM permissions are needed?
4. AWS **Data Lifecycle Manager (DLM)** can do scheduled snapshots and retention without a script. Read about it and write down two reasons to choose DLM and two reasons to keep this script.

---

## 8. Further reading

- [Amazon EBS snapshots](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-snapshots.html)
- [CreateSnapshots (multi-volume, crash-consistent)](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateSnapshots.html)
- [AWS CLI `--query` (JMESPath) filtering](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-filter.html)
- [ShellCheck wiki](https://www.shellcheck.net/wiki/)
- [bats-core documentation](https://bats-core.readthedocs.io/)
- [Amazon Data Lifecycle Manager](https://docs.aws.amazon.com/ebs/latest/userguide/snapshot-lifecycle.html)
