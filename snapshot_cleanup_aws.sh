#!/usr/bin/env bash
# snapshot_cleanup_aws.sh
# Deletes ONLY snapshots having BOTH:
#   AutomatedBackup=true  AND  (age_in_days >= RetentionDays tag)
# Supports:
#   --dry-run  (default)  → only prints table
#   --run      → really deletes
#   --region REGION       → AWS region to operate in (required unless AWS_REGION is set)
#   --log logfile         → custom logfile path

set -euo pipefail

MODE="dry-run"
REGION="${AWS_REGION:-}"
LOGFILE=""

usage() {
  echo "Usage: $0 [--run] --region REGION [--log logfile]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) MODE="run"; shift ;;
    --region) REGION="$2"; shift 2 ;;
    --log) LOGFILE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ -z "$REGION" ]]; then
  echo "ERROR: --region is required (or set AWS_REGION env)."
  usage
fi

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found."; exit 3; }

# ─────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────
mkdir -p snapshot_logs
if [[ -z "${LOGFILE:-}" ]]; then
  LOGFILE="snapshot_logs/cleanup-aws-$(date +%Y%m%d-%H%M%S).log"
fi

echo "Starting AWS snapshot cleanup: $(date -u)" | tee -a "$LOGFILE"
echo "Mode: $MODE  Region: $REGION" | tee -a "$LOGFILE"

# ─────────────────────────────────────────────────────
# Get snapshots (owned by this account in REGION)
# ─────────────────────────────────────────────────────
echo "Fetching snapshots in region: $REGION" | tee -a "$LOGFILE"
aws ec2 describe-snapshots \
  --owner-ids self \
  --region "$REGION" \
  --output json > /tmp/aws-snaps.json

# ─────────────────────────────────────────────────────
# Python analysis + deletion (only in --run)
# ─────────────────────────────────────────────────────
python3 - "$LOGFILE" "$MODE" "$REGION" << 'EOF'
import json, datetime, sys, subprocess

logfile = sys.argv[1]
mode    = sys.argv[2]
region  = sys.argv[3]

def log(msg):
    print(msg)
    with open(logfile, "a") as f:
        f.write(msg + "\n")

# Load JSON
try:
    with open("/tmp/aws-snaps.json") as f:
        snaps = json.load(f).get("Snapshots", [])
except Exception as e:
    log(f"ERROR loading JSON: {e}")
    sys.exit(1)

now = datetime.datetime.now(datetime.timezone.utc)
delete_count = 0

# Print table for dry-run
if mode == "dry-run":
    log("\n📌 DRY-RUN — SNAPSHOT CHECK (AWS)")
    header = "%-22s %-30s %-12s %-6s %-6s" % ("SNAPSHOT ID", "NAME TAG", "RETENTION", "AGE", "DELETE?")
    log(header)
    log("-" * len(header))

for s in snaps:
    tags_list = s.get("Tags", [])
    if not tags_list:
        continue

    tags = {t.get("Key"): t.get("Value") for t in tags_list if "Key" in t and "Value" in t}

    # Must have AutomatedBackup=true
    auto_val = str(tags.get("AutomatedBackup", "")).lower()
    auto = auto_val in ("true", "1", "yes")
    if not auto:
        continue

    # RetentionDays tag
    try:
        retention = int(tags.get("RetentionDays", "14"))
    except Exception:
        retention = 14

    # Age calculation
    start_time = s.get("StartTime")
    if not start_time:
        continue

    # StartTime is ISO-like, e.g., 2025-01-01T12:34:56.000Z
    created = datetime.datetime.fromisoformat(start_time.replace("Z", "+00:00"))
    age = (now - created).days

    eligible = age >= retention
    snap_id = s.get("SnapshotId")
    name_tag = tags.get("Name", "")

    if mode == "dry-run":
        mark = "YES" if eligible else "NO"
        log("%-22s %-30s %-12s %-6s %-6s" % (snap_id, name_tag, retention, age, mark))

    if eligible and mode == "run":
        log(f"DELETE: {snap_id} (age {age} >= {retention})")
        subprocess.run(
            ["aws", "ec2", "delete-snapshot", "--snapshot-id", snap_id, "--region", region],
            check=False
        )
        delete_count += 1

if mode == "run":
    log(f"\n✔ Deleted {delete_count} snapshots.")
else:
    log("\n✔ DRY RUN ONLY — NO DELETIONS PERFORMED")

log("AWS snapshot cleanup complete.")
EOF

echo "Logfile: $LOGFILE"
