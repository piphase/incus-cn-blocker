#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

REPO_OWNER="${REPO_OWNER:-piphase}"
REPO_NAME="${REPO_NAME:-incus-cn-blocker}"
REPO_REF="${REPO_REF:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}}"
SCRIPT_URL="${SCRIPT_URL:-${RAW_BASE}/manage-incus-cn-block.sh}"

RUN_MODE="menu"
TEMP_SCRIPT=""

log() {
  printf '[install.sh] %s\n' "$*"
}

die() {
  printf '[install.sh] 错误：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${TEMP_SCRIPT:-}" && -f "${TEMP_SCRIPT:-}" ]]; then
    rm -f "$TEMP_SCRIPT"
  fi
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

print_help() {
  cat <<EOF
用法：
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- [options]

说明：
  默认会进入中文交互菜单。
  首次进入菜单前，会先备份当前机器的 nftables 配置。

可选项：
  --menu                   下载后直接进入交互菜单（默认行为）
  --install-only           仅执行安装/初始化，不进入菜单
  --enable                 直接启用双栈拦截，并强制刷新一次数据库
  --bridge NAME            设置 BRIDGE_NAME
  --route-url URL          兼容别名，等同于 --route-v4-url
  --route-v4-url URL       覆盖中国 IPv4 数据源地址
  --route-v6-url URL       覆盖中国 IPv6 数据源地址
  --timer-interval VALUE   覆盖 TIMER_INTERVAL，例如 6h
  --cache-min-prefixes N   兼容别名，等同于 --cache-min-v4-prefixes
  --cache-min-v4-prefixes N 覆盖 CACHE_MIN_V4_PREFIXES
  --cache-min-v6-prefixes N 覆盖 CACHE_MIN_V6_PREFIXES
  --state-dir PATH         覆盖 STATE_DIR
  --bin-target PATH        覆盖 BIN_TARGET
  --unit-dir PATH          覆盖 UNIT_DIR
  --ref REF                从指定 git 分支或 tag 下载
  -h, --help               显示本帮助

示例：
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- --enable
  curl -fsSL ${RAW_BASE}/install.sh | sudo bash -s -- --bridge incusbr1
EOF
}

download_script() {
  local destination="$1"

  if have_command curl; then
    local curl_args=(-fsSL --connect-timeout 15 --retry 3 --retry-delay 2 --max-time 180)
    curl "${curl_args[@]}" "$SCRIPT_URL" -o "$destination"
    return 0
  fi

  if have_command wget; then
    wget --quiet --output-document="$destination" "$SCRIPT_URL"
    return 0
  fi

  die "需要 curl 或 wget 才能下载 $SCRIPT_URL"
}

build_script_args() {
  case "$RUN_MODE" in
    menu)
      return 0
      ;;
    install)
      printf '%s\n' install
      ;;
    enable)
      printf '%s\n' enable --refresh
      ;;
    *)
      die "未知运行模式：$RUN_MODE"
      ;;
  esac
}

ensure_terminal_for_menu() {
  if [[ "$RUN_MODE" == "menu" && ! -r /dev/tty ]]; then
    die "当前启动方式没有可用终端，无法进入交互菜单。请直接在终端里运行，或改用 --install-only / --enable。"
  fi
}

run_downloaded_script() {
  local script_path="$1"
  local -a script_args=()
  mapfile -t script_args < <(build_script_args)

  ensure_terminal_for_menu

  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    if [[ "$RUN_MODE" == "menu" && -r /dev/tty ]]; then
      "$script_path" "${script_args[@]}" </dev/tty >/dev/tty 2>/dev/tty
    elif [[ -r /dev/tty ]]; then
      "$script_path" "${script_args[@]}" </dev/tty
    else
      "$script_path" "${script_args[@]}"
    fi
    return 0
  fi

  have_command sudo || die "当前需要 root 权限，请使用 sudo 运行，或先安装 sudo。"

  if [[ "$RUN_MODE" == "menu" && -r /dev/tty ]]; then
    sudo --preserve-env=BRIDGE_NAME,ROUTE_URL,ROUTE_V4_URL,ROUTE_V6_URL,TIMER_INTERVAL,CACHE_MIN_PREFIXES,CACHE_MIN_V4_PREFIXES,CACHE_MIN_V6_PREFIXES,STATE_DIR,BIN_TARGET,UNIT_DIR \
      "$script_path" "${script_args[@]}" </dev/tty >/dev/tty 2>/dev/tty
  elif [[ -r /dev/tty ]]; then
    sudo --preserve-env=BRIDGE_NAME,ROUTE_URL,ROUTE_V4_URL,ROUTE_V6_URL,TIMER_INTERVAL,CACHE_MIN_PREFIXES,CACHE_MIN_V4_PREFIXES,CACHE_MIN_V6_PREFIXES,STATE_DIR,BIN_TARGET,UNIT_DIR \
      "$script_path" "${script_args[@]}" </dev/tty
  else
    sudo --preserve-env=BRIDGE_NAME,ROUTE_URL,ROUTE_V4_URL,ROUTE_V6_URL,TIMER_INTERVAL,CACHE_MIN_PREFIXES,CACHE_MIN_V4_PREFIXES,CACHE_MIN_V6_PREFIXES,STATE_DIR,BIN_TARGET,UNIT_DIR \
      "$script_path" "${script_args[@]}"
  fi
}

parse_args() {
  while (($#)); do
    case "$1" in
      --menu)
        RUN_MODE="menu"
        ;;
      --install-only)
        RUN_MODE="install"
        ;;
      --enable)
        RUN_MODE="enable"
        ;;
      --bridge)
        shift
        [[ $# -gt 0 ]] || die "缺少 --bridge 的参数值"
        export BRIDGE_NAME="$1"
        ;;
      --route-url)
        shift
        [[ $# -gt 0 ]] || die "缺少 --route-url 的参数值"
        export ROUTE_URL="$1"
        ;;
      --route-v4-url)
        shift
        [[ $# -gt 0 ]] || die "缺少 --route-v4-url 的参数值"
        export ROUTE_V4_URL="$1"
        ;;
      --route-v6-url)
        shift
        [[ $# -gt 0 ]] || die "缺少 --route-v6-url 的参数值"
        export ROUTE_V6_URL="$1"
        ;;
      --timer-interval)
        shift
        [[ $# -gt 0 ]] || die "缺少 --timer-interval 的参数值"
        export TIMER_INTERVAL="$1"
        ;;
      --cache-min-prefixes)
        shift
        [[ $# -gt 0 ]] || die "缺少 --cache-min-prefixes 的参数值"
        export CACHE_MIN_PREFIXES="$1"
        ;;
      --cache-min-v4-prefixes)
        shift
        [[ $# -gt 0 ]] || die "缺少 --cache-min-v4-prefixes 的参数值"
        export CACHE_MIN_V4_PREFIXES="$1"
        ;;
      --cache-min-v6-prefixes)
        shift
        [[ $# -gt 0 ]] || die "缺少 --cache-min-v6-prefixes 的参数值"
        export CACHE_MIN_V6_PREFIXES="$1"
        ;;
      --state-dir)
        shift
        [[ $# -gt 0 ]] || die "缺少 --state-dir 的参数值"
        export STATE_DIR="$1"
        ;;
      --bin-target)
        shift
        [[ $# -gt 0 ]] || die "缺少 --bin-target 的参数值"
        export BIN_TARGET="$1"
        ;;
      --unit-dir)
        shift
        [[ $# -gt 0 ]] || die "缺少 --unit-dir 的参数值"
        export UNIT_DIR="$1"
        ;;
      --ref)
        shift
        [[ $# -gt 0 ]] || die "缺少 --ref 的参数值"
        REPO_REF="$1"
        RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_REF}"
        SCRIPT_URL="${RAW_BASE}/manage-incus-cn-block.sh"
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      *)
        die "未知选项：$1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  TEMP_SCRIPT="$(mktemp /tmp/incus-cn-blocker.XXXXXX.sh)"
  trap cleanup EXIT

  log "正在下载主脚本：${SCRIPT_URL}"
  download_script "$TEMP_SCRIPT"
  chmod +x "$TEMP_SCRIPT"

  case "$RUN_MODE" in
    menu)
      log "下载完成，准备进入中文交互菜单。"
      ;;
    install)
      log "下载完成，准备执行安装/初始化。"
      ;;
    enable)
      log "下载完成，准备直接启用拦截。"
      ;;
  esac

  run_downloaded_script "$TEMP_SCRIPT"
}

main "$@"
