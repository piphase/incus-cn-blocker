#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.2.0"
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
  printf '[%s] 警告：%s\n' "$PROGRAM_NAME" "$*" >&2
}

die() {
  printf '[%s] 错误：%s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 身份运行此脚本。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"
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
  flock -n 9 || die "另一个 incus-cn-blocker 进程正在运行，请稍后再试。"
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
    die "需要 curl 或 wget 才能下载路由数据。"
  fi
}

systemd_available() {
  have_command systemctl
}

write_initial_backup() {
  if [[ -f "$INITIAL_BACKUP" ]]; then
    return 0
  fi

  log "首次运行，正在备份当前 nftables 配置到：$INITIAL_BACKUP"
  nft list ruleset >"$INITIAL_BACKUP"

  if [[ ! -f "$STATE_FILE" ]]; then
    save_state "${ENABLED:-0}"
  fi

  log "初始备份已完成。"
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
    log "已安装脚本到：$BIN_TARGET"
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
  [[ -n "$line_count" ]] || die "无法统计下载到的前缀数量。"

  if (( line_count < CACHE_MIN_PREFIXES )); then
    rm -f "$tmp_file"
    die "下载到的路由数据看起来不完整（仅 $line_count 条前缀），已保留旧缓存。"
  fi

  mv "$tmp_file" "$ROUTE_FILE"
  LAST_UPDATED_AT="$(date -u +%FT%TZ)"
  LAST_SOURCE_URL="$ROUTE_URL"
  save_state "${ENABLED:-0}" "$LAST_UPDATED_AT" "$LAST_SOURCE_URL"
  log "已缓存 $line_count 条 IPv4 前缀，来源：$ROUTE_URL"
}

generate_payload() {
  local route_file="$1"
  local payload_file="$2"

  [[ -s "$route_file" ]] || die "路由缓存为空，请先执行“安装/初始化”或“更新数据库”。"

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
    log "已删除自定义表：$TABLE_FAMILY $TABLE_NAME"
  else
    log "自定义表当前不存在。"
  fi
}

enable_units() {
  systemd_available || return 0

  if ! systemctl enable incus-cn-blocker-apply.service >/dev/null 2>&1; then
    warn "无法启用开机自动应用服务 incus-cn-blocker-apply.service"
  fi

  if ! systemctl enable --now incus-cn-blocker-update.timer >/dev/null 2>&1; then
    warn "无法启用定时更新任务 incus-cn-blocker-update.timer"
  fi
}

prepare_interactive_session() {
  require_root
  check_dependencies
  ensure_dirs
  load_state
  write_initial_backup
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
  log "安装/初始化完成。后续可在菜单中继续启用拦截，或手动运行：$BIN_TARGET enable"
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
        die "未知的 enable 选项：$1"
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
      die "当前没有可用缓存，无法使用 --use-cache-only。"
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

  log "已启用拦截：来自 $BRIDGE_NAME 的新建 IPv4 连接将按中国 IPv4 列表进行阻断。"
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
        die "未知的 apply-cached 选项：$1"
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
    log "状态文件显示当前未启用拦截，已跳过缓存应用。"
    return 0
  fi

  [[ -s "$ROUTE_FILE" ]] || die "当前没有可用的路由缓存。"

  payload_file="$(mktemp "$STATE_DIR/payload.XXXXXX.nft")"
  generate_payload "$ROUTE_FILE" "$payload_file"
  apply_payload "$payload_file"
  rm -f "$payload_file"
  log "已将缓存中的路由规则应用到 nftables。"
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
        die "未知的 update 选项：$1"
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
    log "数据库已更新，并已将最新规则应用到 nftables。"
  else
    log "数据库已更新。当前未启用拦截，因此没有重新应用规则。"
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
  log "已关闭拦截，并停止相关定时任务。"
}

command_status() {
  local table_state="不存在"
  local cache_state="不存在"
  local timer_enabled="不可用"
  local timer_active="不可用"
  local apply_enabled="不可用"
  local prefix_count="0"
  local saved_route_url=""

  load_state
  saved_route_url="${ROUTE_URL:-}"

  if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
    table_state="已存在"
  fi

  if [[ -s "$ROUTE_FILE" ]]; then
    cache_state="已存在"
    prefix_count="$(wc -l <"$ROUTE_FILE" | tr -d '[:space:]')"
  fi

  if systemd_available; then
    timer_enabled="$(systemctl is-enabled incus-cn-blocker-update.timer 2>/dev/null || true)"
    timer_active="$(systemctl is-active incus-cn-blocker-update.timer 2>/dev/null || true)"
    apply_enabled="$(systemctl is-enabled incus-cn-blocker-apply.service 2>/dev/null || true)"
  fi

  cat <<EOF
程序名称：$PROGRAM_NAME $VERSION
网桥名称：$BRIDGE_NAME
数据源地址：${saved_route_url}
状态文件中的启用标记：${ENABLED:-0}
自定义表状态：$table_state
初始备份状态：$( [[ -f "$INITIAL_BACKUP" ]] && echo "已存在" || echo "不存在" )
路由缓存状态：$cache_state（$prefix_count 条前缀）
上次数据库更新时间：${LAST_UPDATED_AT:-未知}
定时更新是否启用：$timer_enabled
定时更新当前状态：$timer_active
开机自动应用服务：$apply_enabled
EOF
}

confirm_restore() {
  local answer

  cat <<EOF
即将使用下面这份初始备份，完整覆盖当前 nftables 规则集：
  $INITIAL_BACKUP

这意味着：第一次备份之后你手工改过的其他防火墙规则，也会一起丢失。
如果确认继续，请输入：恢复
EOF
  read -r answer
  [[ "$answer" == "恢复" ]] || die "已取消恢复操作。"
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
        die "未知的 restore-initial 选项：$1"
        ;;
    esac
    shift
  done

  require_root
  acquire_lock
  check_dependencies
  ensure_dirs
  [[ -f "$INITIAL_BACKUP" ]] || die "找不到初始备份文件：$INITIAL_BACKUP"

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
  log "已恢复初始 nftables 配置。恢复前的当前规则已备份到：$restore_snapshot"
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
        die "未知的 uninstall 选项：$1"
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
这将删除已安装的脚本和 systemd 定时任务。
除非你额外使用 --purge-state，否则初始 nftables 备份会被保留。
如果确认继续，请输入：卸载
EOF
    local answer
    read -r answer
    [[ "$answer" == "卸载" ]] || die "已取消卸载操作。"
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
    [[ -n "$STATE_DIR" && "$STATE_DIR" != "/" ]] || die "检测到不安全的状态目录路径，已拒绝清理。"
    rm -rf -- "$STATE_DIR"
    log "已删除状态目录：$STATE_DIR"
  else
    load_state
    save_state "0" "${LAST_UPDATED_AT:-}" "${LAST_SOURCE_URL:-$ROUTE_URL}"
    log "已保留状态目录：$STATE_DIR"
  fi

  log "卸载完成。"
}

print_help() {
  cat <<EOF
用法：
  $PROGRAM_NAME [command] [options]

命令：
  install                  安装脚本本体、写入 systemd 单元，并保留初始备份
  enable [options]         使用缓存或最新下载的中国 IPv4 列表启用拦截
  disable                  关闭拦截，只删除自定义 nftables 表
  update [options]         更新中国 IPv4 数据库，并在需要时重新应用规则
  apply-cached [options]   直接使用本地缓存应用规则，不重新下载
  status                   查看当前状态
  restore-initial          恢复第一次备份时的完整 nftables 配置
  uninstall [options]      卸载脚本与 systemd 单元
  help                     显示本帮助

enable 可选项：
  --refresh                启用前强制重新下载数据库
  --use-cache-only         只允许使用本地缓存，不进行下载
  --no-unit-management     不启用开机恢复服务和定时更新任务

update 可选项：
  --apply-if-enabled       仅在当前状态为已启用时重新应用规则
  --apply-always           下载完成后总是重新应用规则

apply-cached 可选项：
  --if-enabled             若状态文件显示未启用，则直接退出不做变更

restore-initial 可选项：
  --yes                    跳过“恢复”确认提示

uninstall 可选项：
  --yes                    跳过“卸载”确认提示
  --purge-state            删除 $STATE_DIR，其中包含初始备份与缓存

环境变量覆盖：
  BRIDGE_NAME              默认值：$BRIDGE_NAME
  ROUTE_URL                默认值：$ROUTE_URL
  FETCH_PROXY              示例：http://127.0.0.1:10808
  BIN_TARGET               默认值：$BIN_TARGET
  UNIT_DIR                 默认值：$UNIT_DIR
  STATE_DIR                默认值：$STATE_DIR

说明：
  不带参数直接运行时，会先自动备份当前 nftables 配置，然后进入中文交互菜单。
EOF
}

pause_return() {
  local dummy=""
  read -r -p "按回车键返回菜单..." dummy
}

show_menu() {
  while true; do
    cat <<EOF

Incus CN Blocker 交互菜单
1) 安装/更新本地脚本与定时任务
2) 启用拦截
3) 关闭拦截
4) 更新中国 IPv4 数据库
5) 查看状态
6) 恢复初始 nftables 配置
99) 卸载
0) 退出
EOF

    read -r -p "请选择操作序号： " choice
    case "$choice" in
      1) command_install; pause_return ;;
      2) command_enable; pause_return ;;
      3) command_disable; pause_return ;;
      4) command_update; pause_return ;;
      5) command_status; pause_return ;;
      6) command_restore_initial; pause_return ;;
      99) command_uninstall; pause_return ;;
      0) exit 0 ;;
      *) warn "无效的菜单序号：$choice" ;;
    esac
  done
}

main() {
  local command="${1:-}"

  case "$command" in
    "")
      prepare_interactive_session
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
      die "未知命令：$command。请运行 '$PROGRAM_NAME help' 查看帮助。"
      ;;
  esac
}

main "$@"
