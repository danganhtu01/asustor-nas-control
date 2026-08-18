#!/usr/bin/env bash
set -u

# Perpetual sync of every Dang & Associates OneDrive and SharePoint document
# library onto NAS_03, in the same tmux + user-service shape as the
# OneDrive-Personal and GoogleDrive-Personal loops.
#
# The difference from those loops is discovery. A personal remote is one fixed
# tree, so its loop syncs one path forever. A tenant is a moving set: people join,
# Teams create sites, libraries appear. This loop therefore re-enumerates the
# tenant from Microsoft Graph at the top of every cycle, so a new joiner is picked
# up on the next pass with nobody editing a list.
#
# Nothing here writes to NAS_02. The existing NAS_03 -> NAS_02 job snapshots all
# of NAS_03, so OneDrive-DA is carried into those snapshots for free -- which is
# also why this loop keeps no archive of its own.

export TERM="${TERM:-screen-256color}"

SESSION_NAME="${SESSION_NAME:-rclone-sync}"
WINDOW_NAME="${WINDOW_NAME:-onedrive-da}"

NAS03_LABEL="${NAS03_LABEL:-NAS_03}"
NAS03_MOUNT="${NAS03_MOUNT:-/srv/NAS_03}"
DA_SUBDIR="${DA_SUBDIR:-OneDrive-DA}"
DEST_ROOT="${DEST_ROOT:-${NAS03_MOUNT}/${DA_SUBDIR}}"

# Config and state live under the service user, not /etc: this runs as a user
# unit, and a 0400 root-owned secret would simply be unreadable.
M365_CONF="${M365_CONF:-${HOME}/.config/m365-backup/m365-backup.conf}"
M365_STATE="${M365_STATE:-${HOME}/.local/state/m365-backup}"
M365_LIB="${M365_LIB:-/usr/local/bin/m365-backup-lib}"
M365_INVENTORY="${M365_INVENTORY:-/usr/local/bin/m365-backup-inventory}"
export M365_CONF M365_STATE

LOG_DIR="${LOG_DIR:-${HOME}/rclone-logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/onedrive-da-sync.log}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-3600}"
SERVICE_CHECK_SECONDS="${SERVICE_CHECK_SECONDS:-300}"
STATS_INTERVAL="${STATS_INTERVAL:-30s}"
LOCK_FILE="${LOCK_FILE:-${M365_STATE}/da-sync.lock}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# Requests per second against Graph, tenant-wide. SharePoint meters resource
# units per application per tenant, so this is a real ceiling and not a
# per-connection one; 8/s is roughly 77% of the documented limit for a tenant
# under 1,000 licences. Raising it does not go faster, it produces 429s.
TPSLIMIT="${TPSLIMIT:-8}"
TRANSFERS="${TRANSFERS:-4}"
CHECKERS="${CHECKERS:-8}"

mkdir -p "$LOG_DIR" "$M365_STATE"

log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG_FILE"
}

mountpoint_is_ready() {
  findmnt -rn "$1" >/dev/null 2>&1
}

tmux_window_exists() {
  tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -Fx -- "$WINDOW_NAME" >/dev/null
}

start_tmux_window() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    if tmux_window_exists; then
      printf 'tmux window already running: %s:%s\n' "$SESSION_NAME" "$WINDOW_NAME"
      printf 'Attach with: tmux attach -t %s\n' "$SESSION_NAME"
      return 0
    fi

    tmux new-window -d -t "$SESSION_NAME:" -n "$WINDOW_NAME" "$SCRIPT_PATH --worker"
    printf 'started tmux window: %s:%s\n' "$SESSION_NAME" "$WINDOW_NAME"
    printf 'Attach with: tmux attach -t %s\n' "$SESSION_NAME"
    return 0
  fi

  tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" "$SCRIPT_PATH --worker"
  printf 'started tmux session/window: %s:%s\n' "$SESSION_NAME" "$WINDOW_NAME"
  printf 'Attach with: tmux attach -t %s\n' "$SESSION_NAME"
}

service_monitor() {
  while true; do
    start_tmux_window
    sleep "$SERVICE_CHECK_SECONDS"
  done
}

preflight() {
  if [[ ! -r "$M365_CONF" ]]; then
    log "ERROR: no config at ${M365_CONF}"
    return 1
  fi
  if [[ ! -r "$M365_LIB" || ! -x "$M365_INVENTORY" ]]; then
    log "ERROR: m365-backup helpers missing (${M365_LIB}, ${M365_INVENTORY}); run scripts/install.sh"
    return 1
  fi
  if ! command -v rclone >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "ERROR: rclone and jq are both required"
    return 1
  fi
  # App-only OneDrive auth (client_credentials) arrived in rclone v1.69.0.
  local rv major rest minor
  rv=$(rclone version | awk 'NR==1{print $2}' | sed 's/^v//')
  major=${rv%%.*}; rest=${rv#*.}; minor=${rest%%.*}; minor=${minor%%-*}
  if [[ ! $major =~ ^[0-9]+$ ]] || [[ ! $minor =~ ^[0-9]+$ ]] \
     || ((major < 1)) || ((major == 1 && minor < 69)); then
    log "ERROR: rclone ${rv} is too old; app-only auth needs v1.69.0+"
    return 1
  fi
  return 0
}

# One rclone config per cycle, in a private directory, so the client secret never
# lands in a durable rclone.conf and never appears in argv where ps would show it.
write_rclone_conf() {
  local dir=$1 secret
  secret=$(<"$M365_SECRET_FILE")
  ( umask 077
    cat >"$dir/rclone.conf" <<EOF
[m365da]
type = onedrive
client_id = ${M365_CLIENT_ID}
client_secret = ${secret}
tenant = ${M365_TENANT}
client_credentials = true
EOF
  )
}

sync_once() {
  local tmpdir manifest total ok failed line
  local kind dest drive_id drive_type owner label weburl target

  if ! mountpoint_is_ready "$NAS03_MOUNT"; then
    log "ERROR: ${NAS03_LABEL} is not mounted at ${NAS03_MOUNT}; refusing to sync (would write to the root filesystem)."
    return 1
  fi

  # shellcheck source=/dev/null
  . "$M365_CONF"
  : "${M365_TENANT:?M365_TENANT not set in $M365_CONF}"
  : "${M365_CLIENT_ID:?M365_CLIENT_ID not set in $M365_CONF}"
  M365_SECRET_FILE="${M365_SECRET_FILE:-${HOME}/.config/m365-backup/client_secret}"
  if [[ ! -r "$M365_SECRET_FILE" ]]; then
    log "ERROR: cannot read client secret at ${M365_SECRET_FILE}"
    return 1
  fi

  mkdir -p "$DEST_ROOT"

  # Discovery, every cycle. This is what makes a new joiner appear without anyone
  # editing a list, and what retires a leaver's drive from the sweep.
  log "Enumerating tenant drives"
  manifest="${M365_STATE}/drives.tsv"
  if ! M365_CONF="$M365_CONF" M365_STATE="$M365_STATE" "$M365_INVENTORY" --quiet --out "$manifest" >>"$LOG_FILE" 2>&1; then
    log "ERROR: drive enumeration failed; keeping the previous manifest if any"
    [[ -r "$manifest" ]] || return 1
  fi

  total=$(grep -cv '^#' "$manifest" 2>/dev/null || printf 0)
  log "Manifest lists ${total} drives"

  tmpdir=$(mktemp -d -t onedrive-da.XXXXXXXX) || return 1
  chmod 700 "$tmpdir"
  write_rclone_conf "$tmpdir"

  ok=0; failed=0
  # owner and weburl are named only to consume their manifest columns positionally.
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r kind dest drive_id drive_type owner label weburl; do
    [[ -z "$kind" || "$kind" == \#* ]] && continue
    target="${DEST_ROOT}/${dest}"
    mkdir -p "$target"

    log "sync ${kind} ${dest} (${label})"
    if RCLONE_ONEDRIVE_DRIVE_ID="$drive_id" \
       RCLONE_ONEDRIVE_DRIVE_TYPE="$drive_type" \
       rclone sync "m365da:" "$target" \
         --config "$tmpdir/rclone.conf" \
         --user-agent "${M365_USER_AGENT:-NONISV|DangAssociates|NasBackup/1.0}" \
         --tpslimit "$TPSLIMIT" --tpslimit-burst "$TPSLIMIT" \
         --transfers "$TRANSFERS" --checkers "$CHECKERS" \
         --retries 3 --low-level-retries 10 \
         --timeout 5m --contimeout 1m \
         --onedrive-delta \
         --onedrive-av-override \
         --create-empty-src-dirs \
         --stats "$STATS_INTERVAL" \
         --stats-log-level NOTICE \
         --log-file "$LOG_FILE" \
         --log-level INFO
    then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
      log "FAILED: ${dest} (rclone exit $?)"
    fi
  done < "$manifest"

  rm -rf -- "$tmpdir"
  log "Cycle finished: ${ok} ok, ${failed} failed, ${total} total"
  ((failed == 0))
}

run_sync_loop() {
  log "Starting Dang & Associates tenant sync loop in tmux session/window: ${SESSION_NAME}:${WINDOW_NAME}"
  log "Destination: ${DEST_ROOT}"
  log "Repeat interval: ${INTERVAL_SECONDS}s"
  log "Log file: ${LOG_FILE}"

  if ! preflight; then
    log "Preflight failed; retrying in ${INTERVAL_SECONDS}s"
    sleep "$INTERVAL_SECONDS"
  fi

  while true; do
    exec 9>"$LOCK_FILE"
    if flock -n 9; then
      sync_once || log "Cycle reported failures; see ${LOG_FILE}"
      flock -u 9
    else
      log "Another Dang & Associates sync holds the lock; skipping this cycle."
    fi
    log "Next cycle in ${INTERVAL_SECONDS}s"
    sleep "$INTERVAL_SECONDS"
  done
}

case "${1:-}" in
  --worker)
    run_sync_loop
    ;;
  --service)
    service_monitor
    ;;
  --once)
    preflight && sync_once
    ;;
  --attach)
    exec tmux attach -t "$SESSION_NAME"
    ;;
  --help|-h)
    printf 'Usage: %s [--worker|--service|--once|--attach]\n' "$0"
    printf 'Default: start/reuse detached tmux session/window "%s:%s".\n' "$SESSION_NAME" "$WINDOW_NAME"
    printf '\nSyncs every OneDrive and SharePoint library in the tenant to %s\n' "$DEST_ROOT"
    printf 'Re-enumerates the tenant each cycle, so new users are picked up automatically.\n'
    ;;
  "")
    start_tmux_window
    ;;
  *)
    printf 'Unknown argument: %s\n' "$1" >&2
    printf 'Usage: %s [--worker|--service|--once|--attach]\n' "$0" >&2
    exit 2
    ;;
esac
