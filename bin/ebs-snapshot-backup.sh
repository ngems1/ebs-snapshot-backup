#!/usr/bin/env bash
# =============================================================================
# ebs-snapshot-backup.sh
#
# 1. BACKUP: finds every RUNNING EC2 instance tagged Backup=true and takes a
#    crash-consistent snapshot of ALL its EBS volumes (one API call per instance).
# 2. RETENTION: deletes snapshots that THIS script created once they are older
#    than the retention period (default 30 days), always keeping the newest N
#    per volume as a safety net.
#
# It never touches snapshots it did not create: every snapshot it makes carries
# the tag ManagedBy=ebs-snapshot-backup, and retention only looks at those.
#
# Usage:  ebs-snapshot-backup.sh [options]        (run with --help for details)
# Needs:  bash 4+, AWS CLI v2, coreutils `date` (GNU or BSD/macOS)
# =============================================================================

# --- Bash "strict mode" -------------------------------------------------------
# -e  exit as soon as a command fails (unless we explicitly handle the failure)
# -u  using an unset variable is an error (catches typos like $VOLUMEID)
# -o pipefail  a pipeline fails if ANY command in it fails, not just the last
set -euo pipefail
IFS=$'\n\t' # split words only on newlines/tabs, never on spaces in values

readonly SCRIPT_NAME="ebs-snapshot-backup"
readonly VERSION="1.0.0"
readonly MANAGED_TAG_KEY="ManagedBy"
readonly MANAGED_TAG_VALUE="ebs-snapshot-backup"

# --- Defaults (each one can be changed with a flag or an environment variable) --
REGIONS="${EBS_BACKUP_REGIONS:-}"                 # comma-separated; empty = CLI default region
ALL_REGIONS=false
TAG_KEY="${EBS_BACKUP_TAG_KEY:-Backup}"
TAG_VALUE="${EBS_BACKUP_TAG_VALUE:-true}"
RETENTION_DAYS="${EBS_BACKUP_RETENTION_DAYS:-30}"
KEEP_MINIMUM="${EBS_BACKUP_KEEP_MINIMUM:-1}"      # newest N snapshots per volume are never pruned
MIN_INTERVAL_HOURS="${EBS_BACKUP_MIN_INTERVAL_HOURS:-20}" # skip an instance backed up more recently than this
EXCLUDE_BOOT=false
DRY_RUN=false
DO_BACKUP=true
DO_PRUNE=true
WAIT=false
PROFILE="${AWS_PROFILE:-}"
LOG_FORMAT="${EBS_BACKUP_LOG_FORMAT:-text}"       # text | json
LOCK_FILE="${EBS_BACKUP_LOCK_FILE:-/tmp/${SCRIPT_NAME}.lock}"
AWS_BIN="${AWS_BIN:-aws}"                           # overridable for tests

# --- Counters for the final summary -------------------------------------------
CREATED=0
SKIPPED=0
DELETED=0
KEPT=0
ERRORS=0

# =============================================================================
# Logging
# =============================================================================

# All logs go to STDERR so STDOUT stays clean (useful if someone pipes us).
log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$LOG_FORMAT" == "json" ]]; then
    # Escape backslashes and double quotes so the line stays valid JSON.
    msg="${msg//\\/\\\\}"
    msg="${msg//\"/\\\"}"
    printf '{"ts":"%s","level":"%s","script":"%s","dry_run":%s,"msg":"%s"}\n' \
      "$ts" "$level" "$SCRIPT_NAME" "$DRY_RUN" "$msg" >&2
  else
    printf '%s %-5s %s%s\n' "$ts" "$level" "$([[ "$DRY_RUN" == true ]] && echo '[DRY-RUN] ')" "$msg" >&2
  fi
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
error() {
  log ERROR "$@"
  ERRORS=$((ERRORS + 1))
}
DIED=false
die() {
  log FATAL "$@"
  DIED=true
  exit 1
}

# Runs whenever the script exits, for any reason: release the lock and, if
# strict mode stopped us without a message, say so instead of dying silently.
LOCK_DIR=""
# shellcheck disable=SC2317  # invoked by the EXIT trap, not directly
on_exit() {
  local rc=$?
  if [[ -n "$LOCK_DIR" ]]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
  if [[ $rc -ne 0 && $rc -ne 2 && "$DIED" == false ]]; then
    log FATAL "Stopped unexpectedly (exit status $rc). Re-run with 'bash -x' to see the failing command."
  fi
}
trap on_exit EXIT

# =============================================================================
# Help & argument parsing
# =============================================================================

usage() {
  cat <<EOF
$SCRIPT_NAME $VERSION - snapshot EBS volumes of tagged instances and prune old snapshots

Usage: $(basename "$0") [options]

Selection
  -r, --regions LIST         Comma-separated regions (default: AWS CLI default region)
      --all-regions          Every region enabled for the account
  -k, --tag-key KEY          Instance tag key to select (default: $TAG_KEY)
  -v, --tag-value VALUE      Instance tag value to select (default: $TAG_VALUE)
      --exclude-boot-volume  Do not snapshot root/boot volumes

Retention
  -d, --retention-days N     Delete managed snapshots older than N days (default: $RETENTION_DAYS)
                             An instance tag BackupRetentionDays=N overrides this per instance.
      --keep-minimum N       Always keep the newest N snapshots per volume (default: $KEEP_MINIMUM)
      --min-interval-hours N Skip instances backed up in the last N hours (default: $MIN_INTERVAL_HOURS)

Mode
  -n, --dry-run              Change nothing; uses EC2 DryRun to prove permissions
      --backup-only          Create snapshots, skip retention
      --prune-only           Apply retention, create nothing
      --wait                 Wait until new snapshots are completed
  -p, --profile NAME         AWS CLI profile
      --log-format FMT       text (default) or json
      --lock-file PATH       Prevent overlapping runs (default: $LOCK_FILE)
  -h, --help                 Show this help
      --version              Show version

Exit codes: 0 success, 1 fatal error, 2 finished with some errors
EOF
}

# Make sure a value is a non-negative integer (protects arithmetic and API calls).
require_int() {
  [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be a non-negative integer, got '$2'"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r | --regions) REGIONS="${2:?--regions needs a value}"; shift 2 ;;
      --all-regions) ALL_REGIONS=true; shift ;;
      -k | --tag-key) TAG_KEY="${2:?--tag-key needs a value}"; shift 2 ;;
      -v | --tag-value) TAG_VALUE="${2:?--tag-value needs a value}"; shift 2 ;;
      --exclude-boot-volume) EXCLUDE_BOOT=true; shift ;;
      -d | --retention-days) RETENTION_DAYS="${2:?--retention-days needs a value}"; shift 2 ;;
      --keep-minimum) KEEP_MINIMUM="${2:?--keep-minimum needs a value}"; shift 2 ;;
      --min-interval-hours) MIN_INTERVAL_HOURS="${2:?--min-interval-hours needs a value}"; shift 2 ;;
      -n | --dry-run) DRY_RUN=true; shift ;;
      --backup-only) DO_PRUNE=false; shift ;;
      --prune-only) DO_BACKUP=false; shift ;;
      --wait) WAIT=true; shift ;;
      -p | --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
      --log-format) LOG_FORMAT="${2:?--log-format needs a value}"; shift 2 ;;
      --lock-file) LOCK_FILE="${2:?--lock-file needs a value}"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      --version) echo "$SCRIPT_NAME $VERSION"; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
  done

  require_int "--retention-days" "$RETENTION_DAYS"
  require_int "--keep-minimum" "$KEEP_MINIMUM"
  require_int "--min-interval-hours" "$MIN_INTERVAL_HOURS"
  [[ "$RETENTION_DAYS" -ge 1 ]] || die "--retention-days must be at least 1"
  [[ "$LOG_FORMAT" == text || "$LOG_FORMAT" == json ]] || die "--log-format must be text or json"
  [[ "$DO_BACKUP" == true || "$DO_PRUNE" == true ]] || die "--backup-only and --prune-only cannot be combined"
}

# =============================================================================
# AWS helpers
# =============================================================================

# Every AWS call goes through here so --profile and --region are applied the
# same way everywhere (and tests can swap AWS_BIN for a fake).
awscli() {
  local region="$1"
  shift
  local args=(--region "$region")
  [[ -n "$PROFILE" ]] && args+=(--profile "$PROFILE")
  "$AWS_BIN" "${args[@]}" "$@"
}

# Run a CHANGING call (create/delete). In dry-run mode we pass --dry-run to
# EC2: AWS answers "DryRunOperation" if we WOULD have been allowed, or
# "UnauthorizedOperation" if not, so a dry run also tests IAM permissions.
# Returns 0 on success, 1 on failure; the AWS output is printed on stdout.
mutate() {
  local region="$1"
  shift
  local out rc=0
  if [[ "$DRY_RUN" == true ]]; then
    out="$(awscli "$region" "$@" --dry-run 2>&1)" || rc=$?
    if [[ "$out" == *DryRunOperation* ]]; then
      return 0
    fi
    printf '%s\n' "$out"
    return 1
  fi
  out="$(awscli "$region" "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# Collapse multi-line text (e.g. an AWS error) onto one log line.
oneline() { tr '\n' ' ' <<<"$1" | sed 's/ *$//'; }

# Escape a string for use inside a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# =============================================================================
# Date helpers (GNU date on Linux, BSD date on macOS)
# =============================================================================

if date -u -d "@0" +%s >/dev/null 2>&1; then
  DATE_FLAVOUR=gnu
else
  DATE_FLAVOUR=bsd
fi

now_epoch() { date -u +%s; }

# ISO-8601 timestamp (as printed by the AWS CLI) -> seconds since 1970.
# We only use the first 19 characters (YYYY-MM-DDTHH:MM:SS), always UTC.
to_epoch() {
  local ts="${1:0:19}"
  if [[ "$DATE_FLAVOUR" == gnu ]]; then
    date -u -d "${ts/T/ } UTC" +%s
  else
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s
  fi
}

# Seconds since 1970 -> calendar date (for the delete-after tag).
epoch_to_date() {
  if [[ "$DATE_FLAVOUR" == gnu ]]; then
    date -u -d "@$1" +%Y-%m-%d
  else
    date -u -r "$1" +%Y-%m-%d
  fi
}

# =============================================================================
# Locking: two overlapping runs could double-snapshot or race on deletes
# =============================================================================

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another run holds $LOCK_FILE; exiting"
  else
    # macOS has no flock: mkdir is atomic, so it works as a lock too.
    mkdir "${LOCK_FILE}.d" 2>/dev/null || die "Another run holds ${LOCK_FILE}.d; exiting"
    LOCK_DIR="${LOCK_FILE}.d" # removed by on_exit
  fi
}

# =============================================================================
# Discovery
# =============================================================================

resolve_regions() {
  if [[ "$ALL_REGIONS" == true ]]; then
    awscli "${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}" ec2 describe-regions \
      --query 'Regions[].RegionName' --output text | tr '\t' '\n'
  elif [[ -n "$REGIONS" ]]; then
    tr ',' '\n' <<<"$REGIONS" | sed 's/[[:space:]]//g' | grep -v '^$'
  else
    local default
    default="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [[ -z "$default" ]]; then
      local cfg=(configure get region)
      [[ -n "$PROFILE" ]] && cfg+=(--profile "$PROFILE")
      default="$("$AWS_BIN" "${cfg[@]}" 2>/dev/null || true)"
    fi
    [[ -n "$default" ]] || die "No region: pass --regions, --all-regions or set AWS_REGION"
    printf '%s\n' "$default"
  fi
}

# One line per instance:  <instance-id> <TAB> <Name tag or -> <TAB> <BackupRetentionDays tag or None>
# The JMESPath --query runs inside the AWS CLI, so we need no jq.
list_backup_instances() {
  local region="$1"
  awscli "$region" ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
    --query 'Reservations[].Instances[].[InstanceId, (Tags[?Key==`Name`].Value)[0], (Tags[?Key==`BackupRetentionDays`].Value)[0]]' \
    --output text
}

# Volume IDs attached to an instance that opted OUT with tag Backup=false.
list_excluded_volumes() {
  local region="$1" instance_id="$2"
  awscli "$region" ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=${instance_id}" "Name=tag:${TAG_KEY},Values=false" \
    --query 'Volumes[].VolumeId' --output text
}

# One line per managed snapshot:
#   <snapshot-id> <volume-id> <start-time> <state> <retention-days|None> <keep|None> <instance-id|None>
list_managed_snapshots() {
  local region="$1"
  awscli "$region" ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:${MANAGED_TAG_KEY},Values=${MANAGED_TAG_VALUE}" \
    --query 'Snapshots[].[SnapshotId, VolumeId, StartTime, State, (Tags[?Key==`ebs-backup:retention-days`].Value)[0], (Tags[?Key==`ebs-backup:keep`].Value)[0], (Tags[?Key==`ebs-backup:instance-id`].Value)[0]]' \
    --output text
}

# =============================================================================
# Backup
# =============================================================================

# Has this instance been backed up by us within MIN_INTERVAL_HOURS?
# (Makes the script safe to re-run: a retry or a second cron run won't
#  create duplicate snapshots.)
recently_backed_up() {
  local instance_id="$1" snapshots="$2"
  local now threshold
  now="$(now_epoch)"
  threshold=$((now - MIN_INTERVAL_HOURS * 3600))
  local snap_id start state inst
  # `_` discards columns we do not need here.
  while IFS=$'\t' read -r snap_id _ start state _ _ inst; do
    [[ -z "${snap_id:-}" || "$inst" != "$instance_id" ]] && continue
    [[ "$state" == "error" ]] && continue
    if [[ "$(to_epoch "$start")" -ge "$threshold" ]]; then
      return 0
    fi
  done <<<"$snapshots"
  return 1
}

backup_instance() {
  local region="$1" instance_id="$2" name="$3" retention="$4"

  # Instance tag BackupRetentionDays overrides the default (if it is a number).
  [[ "$retention" =~ ^[0-9]+$ && "$retention" -ge 1 ]] || retention="$RETENTION_DAYS"
  [[ "$name" == "None" ]] && name="$instance_id"

  local now delete_after
  now="$(now_epoch)"
  delete_after="$(epoch_to_date "$((now + retention * 86400))")"

  # Data volumes that opted out (tag Backup=false on the VOLUME).
  local excluded
  excluded="$(list_excluded_volumes "$region" "$instance_id" | tr '\t' '\n' | grep -v '^$' || true)"
  local exclude_json="[]"
  if [[ -n "$excluded" ]]; then
    local ex_ids=()
    mapfile -t ex_ids <<<"$excluded"
    exclude_json="[$(printf '"%s",' "${ex_ids[@]}" | sed 's/,$//')]"
    info "$instance_id: excluding opted-out volume(s): $(oneline "$excluded")"
  fi

  # Instance specification: which instance, and which volumes to leave out.
  local spec
  spec="{\"InstanceId\":\"${instance_id}\",\"ExcludeBootVolume\":${EXCLUDE_BOOT},\"ExcludeDataVolumeIds\":${exclude_json}}"

  # Tags written on every snapshot. ManagedBy is what retention relies on.
  local tags
  tags="[{\"ResourceType\":\"snapshot\",\"Tags\":["
  tags+="{\"Key\":\"Name\",\"Value\":\"$(json_escape "$name") backup $(date -u +%Y-%m-%d)\"},"
  tags+="{\"Key\":\"${MANAGED_TAG_KEY}\",\"Value\":\"${MANAGED_TAG_VALUE}\"},"
  tags+="{\"Key\":\"ebs-backup:instance-id\",\"Value\":\"${instance_id}\"},"
  tags+="{\"Key\":\"ebs-backup:retention-days\",\"Value\":\"${retention}\"},"
  tags+="{\"Key\":\"ebs-backup:delete-after\",\"Value\":\"${delete_after}\"}"
  tags+="]}]"

  # create-snapshots (plural) snapshots ALL attached volumes of the instance at
  # the same moment: a crash-consistent set, like pulling the power cord.
  local out
  if out="$(mutate "$region" ec2 create-snapshots \
    --instance-specification "$spec" \
    --description "${SCRIPT_NAME}: ${name} (${instance_id})" \
    --tag-specifications "$tags" \
    --query 'Snapshots[].[VolumeId, SnapshotId]' --output text)"; then
    if [[ "$DRY_RUN" == true ]]; then
      info "$instance_id ($name): would snapshot all volumes, retention ${retention}d"
      CREATED=$((CREATED + 1))
      return 0
    fi
    local vol snap ids=()
    while IFS=$'\t' read -r vol snap; do
      [[ -z "${snap:-}" ]] && continue
      info "$instance_id ($name): $vol -> $snap (keep ${retention}d, until $delete_after)"
      CREATED=$((CREATED + 1))
      ids+=("$snap")
    done <<<"$out"
    if [[ "$WAIT" == true && ${#ids[@]} -gt 0 ]]; then
      info "$instance_id: waiting for ${#ids[@]} snapshot(s) to complete"
      awscli "$region" ec2 wait snapshot-completed --snapshot-ids "${ids[@]}" ||
        error "$instance_id: timed out waiting for snapshots ${ids[*]}"
    fi
  else
    error "$instance_id ($name): snapshot failed: $(oneline "$out")"
  fi
}

run_backup() {
  local region="$1" snapshots="$2"
  local instances
  if ! instances="$(list_backup_instances "$region" 2>&1)"; then
    error "$region: describe-instances failed: $(oneline "$instances")"
    return 1
  fi
  if [[ -z "$instances" ]]; then
    info "$region: no running instances tagged ${TAG_KEY}=${TAG_VALUE}"
    return 0
  fi

  local instance_id name retention
  while IFS=$'\t' read -r instance_id name retention; do
    [[ -z "${instance_id:-}" ]] && continue
    if recently_backed_up "$instance_id" "$snapshots"; then
      info "$instance_id: already backed up in the last ${MIN_INTERVAL_HOURS}h, skipping"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
    backup_instance "$region" "$instance_id" "${name:-None}" "${retention:-None}"
  done <<<"$instances"
}

# =============================================================================
# Retention
# =============================================================================

run_prune() {
  local region="$1" snapshots="$2"
  [[ -z "$snapshots" ]] && { info "$region: no managed snapshots to evaluate"; return 0; }

  local now
  now="$(now_epoch)"

  # Sort by volume, then newest first, so we can count "the newest N" per volume.
  local sorted
  sorted="$(sort -t $'\t' -k2,2 -k3,3r <<<"$snapshots")"

  local snap_id vol start state ret keep prev_vol="" rank=0 created age_days
  while IFS=$'\t' read -r snap_id vol start state ret keep _; do
    [[ -z "${snap_id:-}" ]] && continue

    if [[ "$vol" != "$prev_vol" ]]; then
      prev_vol="$vol"
      rank=0
    fi
    rank=$((rank + 1))

    # Retention for THIS snapshot: its own tag (set at creation) wins.
    [[ "$ret" =~ ^[0-9]+$ && "$ret" -ge 1 ]] || ret="$RETENTION_DAYS"
    created="$(to_epoch "$start")"
    age_days=$(((now - created) / 86400))

    if [[ "$age_days" -lt "$ret" ]]; then
      continue # still inside its retention window
    fi
    if [[ "$rank" -le "$KEEP_MINIMUM" ]]; then
      info "$snap_id ($vol): ${age_days}d old but one of the newest ${KEEP_MINIMUM} for this volume, keeping"
      KEPT=$((KEPT + 1))
      continue
    fi
    if [[ "$keep" != "None" && "${keep,,}" != "false" ]]; then
      info "$snap_id ($vol): ${age_days}d old but tagged ebs-backup:keep, keeping"
      KEPT=$((KEPT + 1))
      continue
    fi
    if [[ "$state" != "completed" ]]; then
      info "$snap_id ($vol): state is $state, not deleting"
      KEPT=$((KEPT + 1))
      continue
    fi

    local out
    if out="$(mutate "$region" ec2 delete-snapshot --snapshot-id "$snap_id")"; then
      info "$snap_id ($vol): ${age_days}d old > ${ret}d retention, $([[ "$DRY_RUN" == true ]] && echo 'would delete' || echo 'deleted')"
      DELETED=$((DELETED + 1))
    elif [[ "$out" == *InvalidSnapshot.InUse* ]]; then
      warn "$snap_id ($vol): in use by an AMI, keeping (deregister the AMI to release it)"
      KEPT=$((KEPT + 1))
    elif [[ "$out" == *InvalidSnapshot.NotFound* ]]; then
      info "$snap_id ($vol): already gone"
    else
      error "$snap_id ($vol): delete failed: $(oneline "$out")"
    fi
  done <<<"$sorted"
}

# =============================================================================
# Main
# =============================================================================

preflight() {
  command -v "$AWS_BIN" >/dev/null 2>&1 || die "AWS CLI not found (install AWS CLI v2)"
  local version
  version="$("$AWS_BIN" --version 2>&1 || true)"
  [[ "$version" == aws-cli/2* ]] || warn "AWS CLI v2 recommended (found: ${version:-unknown})"
}

main() {
  parse_args "$@"
  preflight
  acquire_lock

  info "Starting $SCRIPT_NAME $VERSION (tag ${TAG_KEY}=${TAG_VALUE}, retention ${RETENTION_DAYS}d, keep-minimum ${KEEP_MINIMUM})"

  local region regions
  regions="$(resolve_regions)"
  while IFS= read -r region; do
    [[ -z "$region" ]] && continue
    info "== Region $region =="

    # One describe-snapshots call per region, reused by backup and retention.
    local snapshots
    if ! snapshots="$(list_managed_snapshots "$region" 2>&1)"; then
      error "$region: could not list snapshots, skipping region: $(oneline "$snapshots")"
      continue
    fi

    if [[ "$DO_BACKUP" == true ]]; then
      run_backup "$region" "$snapshots" || error "$region: backup step failed"
    fi
    if [[ "$DO_PRUNE" == true ]]; then
      run_prune "$region" "$snapshots" || error "$region: retention step failed"
    fi
  done <<<"$regions"

  info "Summary: created=${CREATED} skipped=${SKIPPED} deleted=${DELETED} kept=${KEPT} errors=${ERRORS}"
  [[ "$ERRORS" -eq 0 ]] || exit 2
}

# Run main only when executed, not when sourced (tests source this file to
# call individual functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
