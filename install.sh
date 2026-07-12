#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_OWNER="${REPO_OWNER:-piphase}"
REPO_NAME="${REPO_NAME:-incus-cn-blocker}"
REPO_REF="${REPO_REF:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}}"
SCRIPT_URL="${SCRIPT_URL:-${RAW_BASE}/manage-incus-cn-block.sh}"

ENABLE_AFTER_INSTALL=0
ENABLE_ARGS=()

log() {
  printf '[install.sh] %s\n' "$*"
}

die() {
  printf '[install.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

print_help() {
  cat <<EOF
Usage:
  bash <(curl -fsSL ${RAW_BASE}/install.sh) [options]
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- [options]

Options:
  --enable                 Run 'enable --refresh' right after install
  --bridge NAME            Set BRIDGE_NAME for install and later commands
  --proxy URL              Set FETCH_PROXY
  --route-url URL          Override the CN CIDR source URL
  --timer-interval VALUE   Override TIMER_INTERVAL, for example 6h
  --cache-min-prefixes N   Override CACHE_MIN_PREFIXES
  --state-dir PATH         Override STATE_DIR
  --bin-target PATH        Override BIN_TARGET
  --unit-dir PATH          Override UNIT_DIR
  --ref REF                Download from a different git ref
  -h, --help               Show this help

Examples:
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- --enable
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- --enable --proxy http://127.0.0.1:10808
EOF
}

download_script() {
  local destination="$1"

  if have_command curl; then
    local curl_args=(-fsSL --connect-timeout 15 --retry 3 --retry-delay 2 --max-time 180)
    [[ -n "${FETCH_PROXY:-}" ]] && curl_args+=(--proxy "$FETCH_PROXY")
    curl "${curl_args[@]}" "$SCRIPT_URL" -o "$destination"
    return 0
  fi

  if have_command wget; then
    if [[ -n "${FETCH_PROXY:-}" ]]; then
      http_proxy="$FETCH_PROXY" https_proxy="$FETCH_PROXY" \
        wget --quiet --output-document="$destination" "$SCRIPT_URL"
    else
      wget --quiet --output-document="$destination" "$SCRIPT_URL"
    fi
    return 0
  fi

  die "Need curl or wget to download $SCRIPT_URL"
}

run_as_root() {
  local script_path="$1"

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    "$script_path" install
    if (( ENABLE_AFTER_INSTALL == 1 )); then
      "$script_path" enable --refresh "${ENABLE_ARGS[@]}"
    else
      log "Installed successfully. Run '$BIN_TARGET enable' when you are ready."
    fi
    return 0
  fi

  have_command sudo || die "This installer needs root privileges. Re-run with sudo or install sudo first."

  sudo --preserve-env=BRIDGE_NAME,ROUTE_URL,FETCH_PROXY,TIMER_INTERVAL,CACHE_MIN_PREFIXES,STATE_DIR,BIN_TARGET,UNIT_DIR \
    "$script_path" install

  if (( ENABLE_AFTER_INSTALL == 1 )); then
    sudo --preserve-env=BRIDGE_NAME,ROUTE_URL,FETCH_PROXY,TIMER_INTERVAL,CACHE_MIN_PREFIXES,STATE_DIR,BIN_TARGET,UNIT_DIR \
      "$script_path" enable --refresh "${ENABLE_ARGS[@]}"
  else
    log "Installed successfully. Run 'sudo ${BIN_TARGET} enable' when you are ready."
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --enable)
        ENABLE_AFTER_INSTALL=1
        ;;
      --bridge)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --bridge"
        export BRIDGE_NAME="$1"
        ;;
      --proxy)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --proxy"
        export FETCH_PROXY="$1"
        ;;
      --route-url)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --route-url"
        export ROUTE_URL="$1"
        ;;
      --timer-interval)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --timer-interval"
        export TIMER_INTERVAL="$1"
        ;;
      --cache-min-prefixes)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --cache-min-prefixes"
        export CACHE_MIN_PREFIXES="$1"
        ;;
      --state-dir)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --state-dir"
        export STATE_DIR="$1"
        ;;
      --bin-target)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --bin-target"
        export BIN_TARGET="$1"
        ;;
      --unit-dir)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --unit-dir"
        export UNIT_DIR="$1"
        ;;
      --ref)
        shift
        [[ $# -gt 0 ]] || die "Missing value for --ref"
        REPO_REF="$1"
        RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"
        SCRIPT_URL="${RAW_BASE}/manage-incus-cn-block.sh"
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done

  ENABLE_ARGS=()
}

main() {
  local temp_script

  parse_args "$@"
  : "${BIN_TARGET:=/usr/local/sbin/incus-cn-blocker}"

  temp_script="$(mktemp /tmp/incus-cn-blocker.XXXXXX.sh)"
  trap 'rm -f "$temp_script"' EXIT

  log "Downloading ${SCRIPT_URL}"
  download_script "$temp_script"
  chmod +x "$temp_script"
  run_as_root "$temp_script"
}

main "$@"
