#!/usr/bin/env bash
# snapshot_automated_aws.sh
# AWS version of snapshot_automated_v3.sh
# Reads serverlist_v2.txt, supports:
# - Target as EC2 instance (by ID or Name tag)
# - Target as EBS volume (by volume-id)
# - Scope: OS / Data / Both
# - Type: Incremental / Full (stored as tag only; AWS snapshots are incremental by design)
# - Dry-run mode (--dry-run): prints table only, no snapshot created
# - Run mode (--run): actually creates snapshots
#
# Field mapping (serverlist_v2.txt):
#   F1 = Target (instance-id | Name tag | volume-id)
#   F2 = AWS Region (e.g., ap-south-1)
#   F3 = Snapshot Type
#   F4 = Retention Days
#   F5 = Scope (OS|Data|Both)
#   F6 = Reason

set -euo pipefail

########################################
# MODE HANDLING
########################################
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <serverlist-file> [--dry-run | --run]"
  exit 1
fi

SERVERLIST="$1"
MODE="$2"   # --run or --dry-run

if [[ "$MODE" != "--run" && "$MODE" != "--dry-run" ]]; then
  echo "ERROR: You must use --dry-run OR --run"
  exit 1
fi

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 2; }

########################################
# BASICS & LOGGING
########################################
DATE_TAG="$(date +%d-%m-%Y)"
TIME_TAG="$(date +%H:%M:%S)"       # For tags
TIME_SAFE="$(date +%H-%M-%S)"      # For naming/logs

LOGDIR="./snapshot_logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/create-aws-${DATE_TAG}-${TIME_SAFE}.log"

echo "Starting AWS snapshot script: $(date -u)" | tee -a "$LOGFILE"
echo "Mode: $MODE" | tee -a "$LOGFILE"

trim() { printf "%s" "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

normalize_type() {
  local t
  t="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$t" in
    inc|incr|incremental|i) echo "inc" ;;
    full|f) echo "full" ;;
    *) echo "inc" ;;  # default incremental
  esac
}

# DRY-RUN table header
if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "📌 DRY-RUN PREVIEW (NO AWS SNAPSHOTS WILL BE CREATED):"
  printf "\n%-18s %-12s %-6s %-8s %-10s %-8s %-40s %-30s\n" \
        "TARGET" "REGION" "SCOPE" "TYPE" "RETENTION" "KIND" "SNAPSHOT NAME" "REASON"
  printf "%s\n" "-----------------------------------------------------------------------------------------------------------------------------------------------------"
fi

########################################
# MAIN LOOP
########################################
while IFS= read -r RAWLINE || [[ -n "$RAWLINE" ]]; do
  LINE="$(trim "$RAWLINE")"
  [[ -z "$LINE" || "${LINE:0:1}" == "#" ]] && continue

  # F1;F2;F3;F4;F5;REST
  IFS=';' read -r F1 F2 F3 F4 F5 REST <<< "$LINE"

  TARGET_RAW="$(trim "${F1:-}")"
  REGION="$(trim "${F2:-}")"
  TYPE_RAW="$(trim "${F3:-}")"
  RETENTION_RAW="$(trim "${F4:-}")"
  SCOPE_RAW="$(trim "${F5:-}")"
  REASON="$(trim "${REST:-}")"

  if [[ -z "$TARGET_RAW" || -z "$REGION" || -z "$TYPE_RAW" || -z "$RETENTION_RAW" || -z "$SCOPE_RAW" ]]; then
    echo "Skipping invalid/partial line: $RAWLINE" | tee -a "$LOGFILE"
    continue
  fi

  if ! [[ "$RETENTION_RAW" =~ ^[0-9]+$ ]]; then
    echo "Invalid RetentionDays '$RETENTION_RAW' for $TARGET_RAW. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  TYPE="$(normalize_type "$TYPE_RAW")"       # inc/full
  RETENTION="$RETENTION_RAW"
  SCOPE_UP="$(echo "$SCOPE_RAW" | tr '[:lower:]' '[:upper:]')"   # OS/DATA/BOTH

  if [[ "$SCOPE_UP" != "OS" && "$SCOPE_UP" != "DATA" && "$SCOPE_UP" != "BOTH" ]]; then
    echo "Invalid SnapshotScope '$SCOPE_RAW' for $TARGET_RAW. Use OS|Data|Both. Skipping." | tee -a "$LOGFILE"
    continue
  fi

  TARGET="$TARGET_RAW"

  echo "------------------------------------------------------------" | tee -a "$LOGFILE"
  echo "Entry -> Target: $TARGET  Region: $REGION  Type: $TYPE  Retention: $RETENTION  Scope: $SCOPE_UP  Reason: $REASON" | tee -a "$LOGFILE"

  ########################################
  # Resolve TARGET as Instance or Volume
  ########################################
  IS_INSTANCE=false
  IS_VOLUME=false

  INSTANCE_ID=""
  VOLUME_ID=""

  # 1) Try target as instance-id directly
  if aws ec2 describe-instances --instance-ids "$TARGET" --region "$REGION" --output text >/dev/null 2>&1; then
    IS_INSTANCE=true
    INSTANCE_ID="$TARGET"
  else
    # 2) Try target as Name tag of an instance
    INSTANCE_ID=$(aws ec2 describe-instances \
      --region "$REGION" \
      --filters "Name=tag:Name,Values=$TARGET" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text 2>/dev/null || true)

    if [[ -n "$INSTANCE_ID" ]]; then
      # If multiple IDs returned, skip (ambiguous)
      if [[ "$(echo "$INSTANCE_ID" | wc -w)" -gt 1 ]]; then
        echo "ERROR: Name '$TARGET' matches multiple instances in $REGION. Use instance-id. Skipping." | tee -a "$LOGFILE"
        continue
      fi
      IS_INSTANCE=true
      echo "Resolved instance name '$TARGET' -> $INSTANCE_ID" | tee -a "$LOGFILE"
    fi
  fi

  # 3) If not instance, try volume-id
  if [[ "$IS_INSTANCE" == "false" ]]; then
    if aws ec2 describe-volumes --volume-ids "$TARGET" --region "$REGION" --output text >/dev/null 2>&1; then
      IS_VOLUME=true
      VOLUME_ID="$TARGET"
      echo "Interpreting target as VOLUME: $TARGET" | tee -a "$LOGFILE"
    else
      echo "ERROR: Target '$TARGET' not found as instance or volume in region $REGION. Skipping." | tee -a "$LOGFILE"
      continue
    fi
  fi

  ########################################
  # Helper: create snapshot or print dry-run row
  ########################################
  do_volume_snapshot() {
    local volume_id="$1"
    local snap_name="$2"
    local kind="$3"    # OS/DATA/DISK
    local region="$4"
    local desc="$5"

    if [[ "$MODE" == "--dry-run" ]]; then
      printf "%-18s %-12s %-6s %-8s %-10s %-8s %-40s %-30s\n" \
        "$TARGET" "$region" "$SCOPE_UP" "$TYPE" "$RETENTION" "$kind" "$snap_name" "$REASON"
      return
    fi

    echo "Creating $kind snapshot: $snap_name from volume: $volume_id in $region" | tee -a "$LOGFILE"

    # Create snapshot and capture ID
    SNAP_ID="$(aws ec2 create-snapshot \
      --volume-id "$volume_id" \
      --description "$desc" \
      --region "$region" \
      --query 'SnapshotId' \
      --output text)"

    echo "Snapshot created: $SNAP_ID" | tee -a "$LOGFILE"

    # Tag snapshot
    aws ec2 create-tags \
      --region "$region" \
      --resources "$SNAP_ID" \
      --tags \
        Key=Name,Value="$snap_name" \
        Key=Target,Value="$TARGET" \
        Key=Reason,Value="$REASON" \
        Key=BackupType,Value="$TYPE" \
        Key=Scope,Value="$SCOPE_UP" \
        Key=Kind,Value="$kind" \
        Key=Date,Value="$DATE_TAG" \
        Key=Time,Value="$TIME_TAG" \
        Key=AutomatedBackup,Value=true \
        Key=RetentionDays,Value="$RETENTION" \
        Key=Cloud,Value=AWS | tee -a "$LOGFILE" >/dev/null
  }

  ########################################
  # INSTANCE path: split OS vs DATA volumes
  ########################################
  if [[ "$IS_INSTANCE" == "true" ]]; then
    # Get root device name
    ROOT_DEVICE_NAME=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION" \
      --query "Reservations[0].Instances[0].RootDeviceName" \
      --output text 2>/dev/null || true)

    if [[ -z "$ROOT_DEVICE_NAME" ]]; then
      echo "ERROR: Could not determine root device for instance $INSTANCE_ID. Skipping." | tee -a "$LOGFILE"
      continue
    fi

    # Get all EBS mappings: <deviceName> <volumeId>
    MAP_LINES=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION" \
      --query "Reservations[0].Instances[0].BlockDeviceMappings[?Ebs!=null].[DeviceName,Ebs.VolumeId]" \
      --output text 2>/dev/null || true)

    if [[ -z "$MAP_LINES" ]]; then
      echo "WARNING: No EBS volumes found for instance $INSTANCE_ID. Skipping." | tee -a "$LOGFILE"
      continue
    fi

    OS_VOL_ID=""
    DATA_VOL_IDS=()

    while read -r dev vol; do
      [[ -z "$dev" || -z "$vol" ]] && continue
      if [[ "$dev" == "$ROOT_DEVICE_NAME" ]]; then
        OS_VOL_ID="$vol"
      else
        DATA_VOL_IDS+=("$vol")
      fi
    done <<< "$MAP_LINES"

    if [[ "$SCOPE_UP" == "DATA" && ${#DATA_VOL_IDS[@]} -eq 0 ]]; then
      echo "No data volumes for instance $INSTANCE_ID and scope=DATA. Skipping." | tee -a "$LOGFILE"
      continue
    fi

    # OS snapshot
    if [[ "$SCOPE_UP" == "OS" || "$SCOPE_UP" == "BOTH" ]]; then
      if [[ -z "$OS_VOL_ID" ]]; then
        echo "ERROR: Root volume not found for instance $INSTANCE_ID. Skipping OS snapshot." | tee -a "$LOGFILE"
      else
        SNAP_OS="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
        DESC_OS="Snapshot of root volume ${OS_VOL_ID} from instance ${INSTANCE_ID}"
        do_volume_snapshot "$OS_VOL_ID" "$SNAP_OS" "OS" "$REGION" "$DESC_OS"
      fi
    fi

    # DATA snapshots
    if [[ "$SCOPE_UP" == "DATA" || "$SCOPE_UP" == "BOTH" ]]; then
      idx=1
      for vol in "${DATA_VOL_IDS[@]}"; do
        SNAP_DATA="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup-data-${idx}"
        DESC_DATA="Snapshot of data volume ${vol} from instance ${INSTANCE_ID}"
        do_volume_snapshot "$vol" "$SNAP_DATA" "DATA" "$REGION" "$DESC_DATA"
        idx=$((idx+1))
      done
    fi

  ########################################
  # VOLUME path: direct EBS snapshot
  ########################################
  else
    # Target is a volume-id
    SNAP_DISK="${TARGET}-${DATE_TAG}-${TIME_SAFE}-automated-backup"
    DESC_DISK="Snapshot of standalone volume ${TARGET}"
    do_volume_snapshot "$VOLUME_ID" "$SNAP_DISK" "DISK" "$REGION" "$DESC_DISK"
  fi

done < "$SERVERLIST"

echo -e "\n✔ AWS SNAPSHOT SCRIPT DONE — Mode: $MODE" | tee -a "$LOGFILE"
