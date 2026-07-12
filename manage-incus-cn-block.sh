#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.1.0"
PROGRAM_NAME="$(basename "$0")"
SCRIPT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"

ENV_BRIDGE_NAME="${BRIDGE_NAME-}"
ENV_ROUTE_URL="${ROUTE_URL-}"

STATE_DIR="${STATE_DIR:-/var/lib/incus-cn-blocker}"
BIN_TARGET="${BIN_TARGET:-/usr/local/sbin/incus-cn-blocker}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
BRIDGE_NAME="${BRIDGE_NAME:-incusbr0}"
ROUTE_URL="${ROUTE_URL:-https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt}"
FETCH_PROXY="${FETCH_PROXY:-}"
TIMER_INTERVAL="${TIMER_INTERVAL:-12h}"
CACHE_MIN_PREFIXES="${CACHE_MIN_PREFIXES:-1000}"

TABLE_FAMILY="inet"
TABLE_NAME="incus_cn_block"
SET_NAME="cn_v4"
CHAIN_NAME="forward_filter"

ROUTE_FILE="$STATE_DIR/cn_ipv4.txt"
INITIAL_BACKUP="$STATE_DIR/initial-ruleset.nft"
STATE_FILE="$STATE_DIR/state.env"
LOCK_FILE="$STATE_DIR/lock"

log() {
  printf '[%s] %s\n' "$PROGRAM_NAME" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$PROGRAM_NAME" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run this command as root."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

ensure_dirs() {
  install -d -m 0755 "$STATE_DIR"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  if [[ -n "$ENV_BRIDGE_NAME" ]]; then
    BRIDGE_NAME="$ENV_BRIDGE_NAME"
  fi

  if [[ -n "$ENV_ROUTE_URL" ]]; then
    ROUTE_URL="$ENV_ROUTE_URL"
  fi
}

save_state() {
  local enabled="$1"
  local last_updated="${2:-${LAST_UPDATED_AT:-}}"
  local last_source="${3:-${LAST_SOURCE_URL:-$ROUTE_URL}}"
  local installed_at="${INSTALLED_AT:-$(date -u +%FT%TZ)}"

  {
    printf 'ENABLED=%q\n' "$enabled"
    printf 'BRIDGE_NAME=%q\n' "$BRIDGE_NAME"
    printf 'ROUTE_URL=%q\n' "$last_source"
    printf 'LAST_UPDATED_AT=%q\n' "$last_updated"
    printf 'INSTALLED_AT=%q\n' "$installed_at"
  } >"$STATE_FILE"
}

is_enabled() {
  load_state
  [[ "${ENABLED:-0}" == "1" ]]
}

acquire_lock() {
  ensure_dirs
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another incus-cn-blocker invocation is already running."
}

check_dependencies() {
  require_command nft
  require_command grep
  require_command sed
  require_command sort
  require_command mktemp
  require_command install
  require_command flock

  if ! have_command curl && ! have_command wget; then
    die "Need curl or wget to download route data."
  fi
}

systemd_available() {
  have_command systemctl
}

write_initial_backup() {
  if [[ -f "$INITIAL_BACKUP" ]]; then
    return 0
  fi

  log "Saving the initial nftables ruleset to $INITIAL_BACKUP"
  nft list ruleset >"$INITIAL_BACKUP"
}

write_unit_files() {
  local apply_unit="$UNIT_DIR/incus-cn-blocker-apply.service"
  local update_unit="$UNIT_DIR/incus-cn-blocker-update.service"
  local timer_unit="$UNIT_DIR/incus-cn-blocker-update.timer"

  cat >"$apply_unit" <<EOF
[Unit]
Description=Apply Incus China destination block rules from cache
After=network-online.target nftables.service
Wants=network-online.target
ConditionPathExists=$STATE_FILE
ConditionPathExists=$ROUTE_FILE

[Service]
Type=oneshot
ExecStart=$BIN_TARGET apply-cached --if-enabled

[Install]
WantedBy=multi-user.target
EOF

  cat >"$update_unit" <<EOF
[Unit]
Description=Refresh China CIDR cache for Incus destination blocking
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_TARGET update --apply-if-enabled
EOF

  cat >"$timer_unit" <<EOF
[Unit]
Description=Periodic China CIDR refresh for Incus destination blocking

[Timer]
OnBootSec=10min
OnUnitActiveSec=$TIMER_INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

  if systemd_available; then
    systemctl daemon-reload
  fi
}

install_self() {
  if [[ "$SCRIPT_SOURCE" != "$BIN_TARGET" ]]; then
    install -m 0755 "$SCRIPT_SOURCE" "$BIN_TARGET"
    log "Installed script to $BIN_TARGET"
  fi
}

fetch_routes() {
  local tmp_file
  local raw_file
  local line_count

  tmp_file="$(mktemp "$STATE_DIR/cn-routes.XXXXXX")"
  raw_file="${tmp_file}.raw"

  if have_command curl; then
    local curl_args=(-fsSL --connect-timeout 15 --retry 3 --retry-delay 2 --max-time 180)
    [[ -n "$FETCH_PROXY" ]] && curl_args+=(--proxy "$FETCH_PROXY")
    curl "${curl_args[@]}" "$ROUTE_URL" >"$raw_file"
  else
    local wget_args=(--quiet --output-document="$raw_file")
    if [[ -n "$FETCH_PROXY" ]]; then
      http_proxy="$FETCH_PROXY" https_proxy="$FETCH_PROXY" wget "${wget_args[@]}" "$ROUTE_URL"
    else
      wget "${wget_args[@]}" "$ROUTE_URL"
    fi
  fi

  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$raw_file" | sort -u >"$tmp_file"
  rm -f "$raw_file"

  line_count="$(wc -l <"$tmp_file" | tr -d '[:space:]')"
  [[ -n "$line_count" ]] || die "Failed to count downloaded prefixes."

  if (( line_count < CACHE_MIN_PREFIXES )); then
    rm -f "$tmp_file"
    die "Downloaded route data looks incomplete ($line_count prefixes). Keeping the previous cache."
  fi

  mv "$tmp_file" "$ROUTE_FILE"
  LAST_UPDATED_AT="$(date -u +%FT%TZ)"
  LAST_SOURCE_URL="$ROUTE_URL"
  save_state "${ENABLED:-0}" "$LAST_UPDATED_AT" "$LAST_SOURCE_URL"
  log "Cached $line_count IPv4 prefixes from $ROUTE_URL"
}

generate_payload() {
  local route_file="$1"
  local payload_file="$2"

  [[ -s "$route_file" ]] || die "Route cache is empty. Run 'install' or 'update' first."

  {
    echo "table $TABLE_FAMILY $TABLE_NAME {"
    echo "    set $SET_NAME {"
    echo "        type ipv4_addr"
    echo "        flags interval"
    echo "        elements = {"
    sed '$!s/$/,/' "$route_file" | sed 's/^/            /'
    echo "        }"
    echo "    }"
    echo
    echo "    chain $CHAIN_NAME {"
    echo "        type filter hook forward priority 0; policy accept;"
    echo "        ct state established,related accept"
    echo "        iifname \"$BRIDGE_NAME\" ip daddr @$SET_NAME ct state new counter drop"
    echo "    }"
    echo "}"
  } >"$payload_file"
}

apply_payload() {
  local payload_file="$1"
  local txn_file

  txn_file="$(mktemp "$STATE_DIR/apply.XXXXXX.nft")"

  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    echo "delete table $TABLE_FAMILY $TABLE_NAME" >"$txn_file"
  fi

  cat "$payload_file" >>"$txn_file"
  nft -c -f "$txn_file"
  nft -f "$txn_file"
  rm -f "$txn_file"
}

remove_custom_table() {
  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    nft delete table "$TABLE_FAMILY" "$TABLE_NAME"
    log "Removed custom table $TABLE_FAMILY $TABLE_NAME"
  else
    log "Custom table is already absent"
  fi
}

enable_units() {
  systemd_available || return 0

  if ! systemctl enable incus-cn-blocker-apply.service >/dev/null 2>&1; then
    warn "Could not enable incus-cn-blocker-apply.service"
  fi

  if ! systemctl enable --now incus-cn-blocker-update.timer >/dev/null 2>&1; then
    warn "Could not enable incus-cn-blocker-update.timer"
  fi
}

disable_units() {
  systemd_available || return 0

  systemctl disable --now incus-cn-blocker-update.timer >/dev/null 2>&1 || true
  systemctl disable incus-cn-blocker-apply.service >/dev/null 2>&1 || true
}

command_install() {
  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  load_state
  write_initial_backup
  install_self
  write_unit_files
  save_state "${ENABLED:-0}"
  log "Install complete. Run '$BIN_TARGET enable' when you are ready."
}

command_enable() {
  local refresh=0
  local use_cache_only=0
  local manage_units=1
  local payload_file

  while (($#)); do
    case "$1" in
      --refresh)
        refresh=1
        ;;
      --use-cache-only)
        use_cache_only=1
        ;;
      --no-unit-management)
        manage_units=0
        ;;
      *)
        die "Unknown enable option: $1"
        ;;
    esac
    shift
  done

  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  load_state
  write_initial_backup

  if (( refresh == 1 )) || [[ ! -s "$ROUTE_FILE" ]]; then
    if (( use_cache_only == 1 )); then
      die "No cached route file is available for --use-cache-only."
    fi
    fetch_routes
  fi

  payload_file="$(mktemp "$STATE_DIR/payload.XXXXXX.nft")"
  generate_payload "$ROUTE_FILE" "$payload_file"
  apply_payload "$payload_file"
  rm -f "$payload_file"

  ENABLED=1
  save_state "1" "${LAST_UPDATED_AT:-}" "${LAST_SOURCE_URL:-$ROUTE_URL}"

  if (( manage_units == 1 )); then
    install_self
    write_unit_files
    enable_units
  fi

  log "Blocking is enabled for new IPv4 connections entering via $BRIDGE_NAME"
}

command_apply_cached() {
  local if_enabled=0
  local payload_file

  while (($#)); do
    case "$1" in
      --if-enabled)
        if_enabled=1
        ;;
      *)
        die "Unknown apply-cached option: $1"
        ;;
    esac
    shift
  done

  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  load_state

  if (( if_enabled == 1 )) && ! is_enabled; then
    log "Blocking is disabled in state; skipping cached apply"
    return 0
  fi

  [[ -s "$ROUTE_FILE" ]] || die "No cached route file is available."

  payload_file="$(mktemp "$STATE_DIR/payload.XXXXXX.nft")"
  generate_payload "$ROUTE_FILE" "$payload_file"
  apply_payload "$payload_file"
  rm -f "$payload_file"
  log "Applied cached routes to nftables"
}

command_update() {
  local apply_if_enabled=0
  local apply_always=0
  local payload_file

  while (($#)); do
    case "$1" in
      --apply-if-enabled)
        apply_if_enabled=1
        ;;
      --apply-always)
        apply_always=1
        ;;
      *)
        die "Unknown update option: $1"
        ;;
    esac
    shift
  done

  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  load_state
  fetch_routes

  if (( apply_always == 1 )) || (( apply_if_enabled == 1 && ${ENABLED:-0} == 1 )) || (( apply_if_enabled == 0 && ${ENABLED:-0} == 1 )); then
    payload_file="$(mktemp "$STATE_DIR/payload.XXXXXX.nft")"
    generate_payload "$ROUTE_FILE" "$payload_file"
    apply_payload "$payload_file"
    rm -f "$payload_file"
    log "Updated the nftables set from the refreshed cache"
  fi
}

command_disable() {
  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  load_state
  remove_custom_table
  disable_units
  ENABLED=0
  save_state "0" "${LAST_UPDATED_AT:-}" "${LAST_SOURCE_URL:-$ROUTE_URL}"
  log "Blocking is disabled"
}

command_status() {
  local table_state="absent"
  local cache_state="missing"
  local timer_enabled="n/a"
  local timer_active="n/a"
  local apply_enabled="n/a"
  local prefix_count="0"
  local saved_route_url=""

  load_state
  saved_route_url="${ROUTE_URL:-}"

  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    table_state="present"
  fi

  if [[ -s "$ROUTE_FILE" ]]; then
    cache_state="present"
    prefix_count="$(wc -l <"$ROUTE_FILE" | tr -d '[:space:]')"
  fi

  if systemd_available; then
    timer_enabled="$(systemctl is-enabled incus-cn-blocker-update.timer 2>/dev/null || true)"
    timer_active="$(systemctl is-active incus-cn-blocker-update.timer 2>/dev/null || true)"
    apply_enabled="$(systemctl is-enabled incus-cn-blocker-apply.service 2>/dev/null || true)"
  fi

  cat <<EOF
Program: $PROGRAM_NAME $VERSION
Bridge: $BRIDGE_NAME
Source URL: ${saved_route_url}
Enabled in state: ${ENABLED:-0}
Custom table: $table_state
Initial backup: $( [[ -f "$INITIAL_BACKUP" ]] && echo "present" || echo "missing" )
Route cache: $cache_state ($prefix_count prefixes)
Last cache update: ${LAST_UPDATED_AT:-unknown}
Timer enabled: $timer_enabled
Timer active: $timer_active
Boot apply enabled: $apply_enabled
EOF
}

confirm_restore() {
  local answer

  cat <<EOF
This will replace the entire current nftables ruleset with:
  $INITIAL_BACKUP

That means any firewall changes made after the first install backup will be lost.
Type RESTORE to continue:
EOF
  read -r answer
  [[ "$answer" == "RESTORE" ]] || die "Restore cancelled."
}

command_restore_initial() {
  local assume_yes=0
  local restore_snapshot
  local restore_txn

  while (($#)); do
    case "$1" in
      --yes)
        assume_yes=1
        ;;
      *)
        die "Unknown restore-initial option: $1"
        ;;
    esac
    shift
  done

  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  [[ -f "$INITIAL_BACKUP" ]] || die "Initial backup not found: $INITIAL_BACKUP"

  if (( assume_yes == 0 )); then
    confirm_restore
  fi

  restore_snapshot="$STATE_DIR/pre-restore-$(date -u +%Y%m%dT%H%M%SZ).nft"
  restore_txn="$(mktemp "$STATE_DIR/restore.XXXXXX.nft")"
  nft list ruleset >"$restore_snapshot"
  {
    echo "flush ruleset"
    cat "$INITIAL_BACKUP"
  } >"$restore_txn"
  nft -c -f "$restore_txn"
  nft -f "$restore_txn"
  rm -f "$restore_txn"
  disable_units
  ENABLED=0
  load_state
  save_state "0" "${LAST_UPDATED_AT:-}" "${LAST_SOURCE_URL:-$ROUTE_URL}"
  log "Restored the initial ruleset. Current rules were backed up to $restore_snapshot"
}

command_uninstall() {
  local purge_state=0
  local assume_yes=0

  while (($#)); do
    case "$1" in
      --purge-state)
        purge_state=1
        ;;
      --yes)
        assume_yes=1
        ;;
      *)
        die "Unknown uninstall option: $1"
        ;;
    esac
    shift
  done

  require_root
  acquire_lock
  check_dependencies
  ensure_dirs

  if (( assume_yes == 0 )); then
    cat <<EOF
This will remove the installed helper files and disable the timer.
The initial nftables backup will be kept unless --purge-state is used.
Type UNINSTALL to continue:
EOF
    local answer
    read -r answer
    [[ "$answer" == "UNINSTALL" ]] || die "Uninstall cancelled."
  fi

  remove_custom_table
  disable_units

  rm -f "$UNIT_DIR/incus-cn-blocker-apply.service"
  rm -f "$UNIT_DIR/incus-cn-blocker-update.service"
  rm -f "$UNIT_DIR/incus-cn-blocker-update.timer"
  systemd_available && systemctl daemon-reload || true

  if [[ -f "$BIN_TARGET" ]]; then
    rm -f "$BIN_TARGET"
  fi

  if (( purge_state == 1 )); then
    [[ -n "$STATE_DIR" && "$STATE_DIR" != "/" ]] || die "Refusing to purge an unsafe state path."
    rm -rf -- "$STATE_DIR"
    log "Removed state directory $STATE_DIR"
  else
    load_state
    save_state "0" "${LAST_UPDATED_AT:-}" "${LAST_SOURCE_URL:-$ROUTE_URL}"
    log "State directory preserved at $STATE_DIR"
  fi

  log "Uninstall complete"
}

print_help() {
  cat <<EOF
Usage:
  $PROGRAM_NAME [command] [options]

Commands:
  install                  Install the helper, save the initial nftables backup, and write systemd units
  enable [options]         Enable blocking using the cached or freshly downloaded CN IPv4 routes
  disable                  Disable blocking by removing only the custom nftables table
  update [options]         Refresh the cached CN IPv4 routes and re-apply if blocking is enabled
  apply-cached [options]   Apply the cached routes without downloading new data
  status                   Show the current state
  restore-initial          Restore the full nftables ruleset captured during the first install
  uninstall [options]      Remove installed units and the helper
  help                     Show this help

Enable options:
  --refresh                Force a route download before enabling
  --use-cache-only         Refuse to download routes; use only the existing cache
  --no-unit-management     Do not enable the boot service or update timer

Update options:
  --apply-if-enabled       Re-apply routes only when the saved state is enabled
  --apply-always           Always re-apply after downloading

Apply-cached options:
  --if-enabled             Exit without changes when saved state is disabled

Restore options:
  --yes                    Skip the RESTORE confirmation prompt

Uninstall options:
  --yes                    Skip the UNINSTALL confirmation prompt
  --purge-state            Remove $STATE_DIR, including the initial ruleset backup

Environment overrides:
  BRIDGE_NAME              Default: $BRIDGE_NAME
  ROUTE_URL                Default: $ROUTE_URL
  FETCH_PROXY              Example: http://127.0.0.1:10808
  BIN_TARGET               Default: $BIN_TARGET
  UNIT_DIR                 Default: $UNIT_DIR
  STATE_DIR                Default: $STATE_DIR
EOF
}

show_menu() {
  while true; do
    cat <<EOF

Incus CN Blocker
1) Install or upgrade local files
2) Enable blocking
3) Disable blocking
4) Refresh route cache and re-apply if enabled
5) Show status
6) Restore the initial nftables ruleset
7) Uninstall local files
0) Exit
EOF

    read -r -p "Choose an action: " choice
    case "$choice" in
      1) command_install ;;
      2) command_enable ;;
      3) command_disable ;;
      4) command_update ;;
      5) command_status ;;
      6) command_restore_initial ;;
      7) command_uninstall ;;
      0) exit 0 ;;
      *) warn "Unknown selection: $choice" ;;
    esac
  done
}

main() {
  local command="${1:-}"

  case "$command" in
    "")
      show_menu
      ;;
    install)
      shift
      command_install "$@"
      ;;
    enable)
      shift
      command_enable "$@"
      ;;
    disable)
      shift
      command_disable "$@"
      ;;
    update)
      shift
      command_update "$@"
      ;;
    apply-cached)
      shift
      command_apply_cached "$@"
      ;;
    status)
      shift
      command_status "$@"
      ;;
    restore-initial)
      shift
      command_restore_initial "$@"
      ;;
    uninstall)
      shift
      command_uninstall "$@"
      ;;
    help|-h|--help)
      print_help
      ;;
    *)
      die "Unknown command: $command. Run '$PROGRAM_NAME help' for usage."
      ;;
  esac
}

main "$@"
