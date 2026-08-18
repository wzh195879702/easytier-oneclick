#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="easytier-oneclick"
SERVICE_DISPLAY_NAME="EasyTier"
UPSTREAM_REPO="${EASYTIER_UPSTREAM_REPO:-EasyTier/EasyTier}"
UPSTREAM_API="${EASYTIER_UPSTREAM_API:-https://api.github.com/repos/$UPSTREAM_REPO}"
UPSTREAM_DOWNLOAD="${EASYTIER_UPSTREAM_DOWNLOAD:-https://github.com/$UPSTREAM_REPO/releases/download}"

INSTALL_DIR="${EASYTIER_ONECLICK_INSTALL_DIR:-/opt/easytier-oneclick}"
STATE_DIR="${EASYTIER_ONECLICK_STATE_DIR:-/etc/easytier-oneclick}"
CONFIG_FILE="${EASYTIER_ONECLICK_CONFIG_FILE:-$STATE_DIR/config.toml}"
BACKUP_DIR="${EASYTIER_ONECLICK_BACKUP_DIR:-$STATE_DIR/backups}"
COMMAND_PATH="${EASYTIER_ONECLICK_COMMAND_PATH:-/usr/local/bin/easytier}"
CORE_BIN="$INSTALL_DIR/easytier-core"
CLI_BIN="$INSTALL_DIR/easytier-cli"
VERSION_FILE="$INSTALL_DIR/VERSION"

if [ -t 1 ] || [ -t 2 ]; then
  red='\033[31m'
  yellow='\033[33m'
  green='\033[32m'
  blue='\033[34m'
  bold='\033[1m'
  dim='\033[2m'
  none='\033[0m'
else
  red=''; yellow=''; green=''; blue=''; bold=''; dim=''; none=''
fi

TEMP_DIRS=()
NEW_TEMP_DIR=""

info() { printf "%b[信息]%b %s\n" "$blue" "$none" "$*"; }
ok() { printf "%b[完成]%b %s\n" "$green" "$none" "$*"; }
warn() { printf "%b[警告]%b %s\n" "$yellow" "$none" "$*" >&2; }
die() { printf "%b[错误]%b %s\n" "$red" "$none" "$*" >&2; exit 1; }

ui_line() { printf "%b%s%b\n" "$dim" "------------------------------------------------------------" "$none"; }
ui_title() { printf "\n%b%b%s%b\n" "$blue" "$bold" "$1" "$none"; ui_line; }
ui_kv() { printf "  %s: %s\n" "$1" "${2:-}"; }
ui_pause() {
  [ -t 0 ] && [ -t 1 ] || return 0
  printf "\n%b按回车继续...%b" "$dim" "$none"
  read -r _ || true
}

cleanup_temp_dirs() {
  local dir
  for dir in "${TEMP_DIRS[@]:-}"; do
    [ -n "$dir" ] && [ -d "$dir" ] && rm -rf -- "$dir"
  done
}

new_temp_dir() {
  NEW_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easytier-oneclick.XXXXXX")"
  TEMP_DIRS[${#TEMP_DIRS[@]}]="$NEW_TEMP_DIR"
}

trap cleanup_temp_dirs EXIT

require_root() {
  if [ "${EASYTIER_ONECLICK_ALLOW_NON_ROOT:-0}" = "1" ]; then
    return 0
  fi
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 或 sudo 执行此操作。"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$STATE_DIR" "$BACKUP_DIR"
  chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null || true
}

assert_safe_tree() {
  local path="$1"
  [ -n "$path" ] || die "拒绝删除空路径。"
  case "$path" in
    /|/opt|/etc|/usr|/usr/local|"$HOME") die "拒绝删除过宽路径：$path" ;;
  esac
  [ "${#path}" -ge 8 ] || die "拒绝删除可疑路径：$path"
}

detect_os() {
  if [ -n "${EASYTIER_TEST_OS:-}" ]; then
    printf "%s\n" "$EASYTIER_TEST_OS"
    return 0
  fi

  case "$(uname -s)" in
    Darwin) printf "macos\n" ;;
    Linux)
      [ -r /etc/os-release ] || die "仅支持 Debian 或 Ubuntu Linux。"
      local distro like
      distro="$(awk -F= '$1 == "ID" { gsub(/\"/, "", $2); print tolower($2) }' /etc/os-release)"
      like="$(awk -F= '$1 == "ID_LIKE" { gsub(/\"/, "", $2); print tolower($2) }' /etc/os-release)"
      case " $distro $like " in
        *" debian "*|*" ubuntu "*) printf "linux\n" ;;
        *) die "仅支持 Debian 或 Ubuntu，当前发行版：${distro:-unknown}" ;;
      esac
      ;;
    *) die "仅支持 macOS、Debian 和 Ubuntu。" ;;
  esac
}

detect_arch() {
  local os="${1:-$(detect_os)}"
  local raw="${EASYTIER_TEST_ARCH:-$(uname -m)}"
  case "$os:$raw" in
    macos:arm64|macos:aarch64) printf "aarch64\n" ;;
    macos:x86_64|macos:amd64) printf "x86_64\n" ;;
    linux:x86_64|linux:amd64) printf "x86_64\n" ;;
    linux:aarch64|linux:arm64) printf "aarch64\n" ;;
    linux:armv7l|linux:armv7) printf "armv7\n" ;;
    linux:armv7hf) printf "armv7hf\n" ;;
    linux:armv6l|linux:arm) printf "arm\n" ;;
    linux:armhf) printf "armhf\n" ;;
    linux:mips) printf "mips\n" ;;
    linux:mipsel) printf "mipsel\n" ;;
    linux:riscv64) printf "riscv64\n" ;;
    linux:loongarch64) printf "loongarch64\n" ;;
    *) die "不支持的架构：$raw ($os)" ;;
  esac
}

asset_name_for() {
  local os="$1" arch="$2" version="$3"
  printf "easytier-%s-%s-%s.zip\n" "$os" "$arch" "$version"
}

resolve_version() {
  local requested="${1:-latest}"
  local version response
  case "$requested" in
    ""|latest|stable)
      require_command curl
      response="$(curl -fsSL --retry 3 "$UPSTREAM_API/releases/latest")" || die "无法查询 EasyTier 最新版本。"
      version="$(printf "%s\n" "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
      [ -n "$version" ] || die "GitHub 响应中缺少 tag_name。"
      ;;
    v*) version="$requested" ;;
    *) version="v$requested" ;;
  esac
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9._-]+)?$ ]] || die "无效版本号：$version"
  printf "%s\n" "$version"
}

download_release() {
  local version="$1" destination="$2"
  local os arch asset archive extract core cli
  os="$(detect_os)"
  arch="$(detect_arch "$os")"
  asset="$(asset_name_for "$os" "$arch" "$version")"
  archive="$destination/$asset"
  extract="$destination/extract"

  require_command curl
  require_command unzip
  mkdir -p "$extract"
  info "下载 EasyTier $version：$asset"
  curl -fL --retry 3 --connect-timeout 15 \
    "$UPSTREAM_DOWNLOAD/$version/$asset" -o "$archive" || die "下载失败：$asset"
  unzip -tq "$archive" >/dev/null || die "下载文件不是有效 ZIP：$asset"
  unzip -q "$archive" -d "$extract"

  core="$(find "$extract" -type f -name easytier-core -print -quit)"
  cli="$(find "$extract" -type f -name easytier-cli -print -quit)"
  if [ -z "$core" ] || [ -z "$cli" ]; then
    die "发布包缺少 easytier-core 或 easytier-cli。"
  fi

  mkdir -p "$destination/bin"
  cp "$core" "$destination/bin/easytier-core"
  cp "$cli" "$destination/bin/easytier-cli"
  chmod 755 "$destination/bin/easytier-core" "$destination/bin/easytier-cli"
  "$destination/bin/easytier-core" --version >/dev/null 2>&1 || die "easytier-core 无法运行。"
  "$destination/bin/easytier-cli" --version >/dev/null 2>&1 || die "easytier-cli 无法运行。"
}

current_version() {
  if [ -r "$VERSION_FILE" ]; then
    tr -d '[:space:]' <"$VERSION_FILE"
  elif [ -x "$CORE_BIN" ]; then
    "$CORE_BIN" --version 2>/dev/null | head -n 1
  else
    printf "未安装\n"
  fi
}

service_status_output() {
  if [ ! -x "$CLI_BIN" ]; then
    printf "Service is not installed\n"
    return 0
  fi
  "$CLI_BIN" service --name "$SERVICE_NAME" status 2>&1 || true
}

service_is_running() {
  case "$(service_status_output)" in
    *"Service is running"*) return 0 ;;
    *) return 1 ;;
  esac
}

service_action() {
  local action="${1:-status}"
  [ -x "$CLI_BIN" ] || die "EasyTier 尚未安装。"

  case "$action" in
    status)
      "$CLI_BIN" service --name "$SERVICE_NAME" status
      ;;
    install)
      require_root
      [ -r "$CONFIG_FILE" ] || die "请先执行 easytier configure 生成配置。"
      "$CLI_BIN" service --name "$SERVICE_NAME" install \
        --display-name "$SERVICE_DISPLAY_NAME" \
        --service-work-dir "$INSTALL_DIR" \
        -- -c "$CONFIG_FILE"
      "$CLI_BIN" service --name "$SERVICE_NAME" start
      ok "服务已注册、启动并设置为开机自启。"
      ;;
    start|stop|uninstall)
      require_root
      "$CLI_BIN" service --name "$SERVICE_NAME" "$action"
      ;;
    restart)
      require_root
      if service_is_running; then
        "$CLI_BIN" service --name "$SERVICE_NAME" stop
      fi
      "$CLI_BIN" service --name "$SERVICE_NAME" start
      ;;
    *) die "未知服务操作：$action" ;;
  esac
}

confirm() {
  local prompt="$1" default="${2:-no}" answer
  if [ ! -t 0 ]; then
    [ "$default" = "yes" ]
    return
  fi
  if [ "$default" = "yes" ]; then
    printf "%s [Y/n]: " "$prompt" >&2
  else
    printf "%s [y/N]: " "$prompt" >&2
  fi
  read -r answer
  case "$answer" in
    y|Y|yes|YES|是) return 0 ;;
    n|N|no|NO|否) return 1 ;;
    "") [ "$default" = "yes" ] ;;
    *) return 1 ;;
  esac
}

install_release() {
  local mode="${1:-install}" requested="${2:-latest}"
  local target previous stage backup was_running="no" had_old="no"
  require_root
  detect_os >/dev/null
  ensure_dirs
  target="$(resolve_version "$requested")"
  previous="$(current_version)"

  ui_title "EasyTier 安装与更新"
  ui_kv "当前版本" "$previous"
  ui_kv "目标版本" "$target"
  if [ "$mode" = "update" ] && [ "$previous" != "未安装" ]; then
    if [ ! -t 0 ] && [ "${EASYTIER_ONECLICK_ASSUME_YES:-0}" != "1" ]; then
      die "非交互更新需要设置 EASYTIER_ONECLICK_ASSUME_YES=1。"
    fi
    if [ "${EASYTIER_ONECLICK_ASSUME_YES:-0}" != "1" ] && ! confirm "确认更新？" no; then
      info "已取消更新。"
      return 0
    fi
  fi

  new_temp_dir
  stage="$NEW_TEMP_DIR"
  download_release "$target" "$stage"

  service_is_running && was_running="yes"
  backup="$stage/previous"
  mkdir -p "$backup"
  if [ -x "$CORE_BIN" ] && [ -x "$CLI_BIN" ]; then
    had_old="yes"
    cp "$CORE_BIN" "$CLI_BIN" "$backup/"
    [ -r "$VERSION_FILE" ] && cp "$VERSION_FILE" "$backup/VERSION"
  fi

  if [ "$was_running" = "yes" ]; then
    "$CLI_BIN" service --name "$SERVICE_NAME" stop || die "无法停止当前 EasyTier 服务。"
  fi

  if ! cp "$stage/bin/easytier-core" "$CORE_BIN" || \
     ! cp "$stage/bin/easytier-cli" "$CLI_BIN"; then
    [ "$had_old" = "yes" ] && cp "$backup/easytier-core" "$CORE_BIN" && cp "$backup/easytier-cli" "$CLI_BIN"
    die "替换 EasyTier 二进制失败。"
  fi
  chmod 755 "$CORE_BIN" "$CLI_BIN"
  printf "%s\n" "$target" >"$VERSION_FILE"

  if [ "$was_running" = "yes" ] && ! "$CLI_BIN" service --name "$SERVICE_NAME" start; then
    warn "新版本启动失败，正在恢复旧版本。"
    if [ "$had_old" = "yes" ]; then
      cp "$backup/easytier-core" "$CORE_BIN"
      cp "$backup/easytier-cli" "$CLI_BIN"
      if [ -r "$backup/VERSION" ]; then cp "$backup/VERSION" "$VERSION_FILE"; else rm -f "$VERSION_FILE"; fi
      "$CLI_BIN" service --name "$SERVICE_NAME" start || warn "旧服务恢复启动失败，请手动检查。"
    fi
    die "更新已回滚。"
  fi
  ok "EasyTier $target 已安装。配置未被覆盖。"
}

validate_scalar() {
  local name="$1" value="$2"
  [ -n "$value" ] || die "$name 不能为空。"
  case "$value" in
    *[[:cntrl:]]*) die "$name 不能包含控制字符。" ;;
  esac
}

toml_escape() {
  local value="$1"
  case "$value" in
    *[[:cntrl:]]*) die "配置值不能包含控制字符。" ;;
  esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf "%s" "$value"
}

validate_ipv4() {
  local value="$1" ip prefix octet
  local -a octets
  ip="${value%%/*}"
  if [ "$ip" != "$value" ]; then
    prefix="${value#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
  fi
  IFS='.' read -r -a octets <<< "$ip"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] && [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

validate_ipv4_address() {
  case "$1" in */*) return 1 ;; esac
  validate_ipv4 "$1"
}

validate_ipv4_cidr() {
  case "$1" in */*) validate_ipv4 "$1" ;; *) return 1 ;; esac
}

validate_peer_uri() {
  [[ "$1" =~ ^(tcp|udp|ws|wss|wg|quic|ring|faketcp)://[^[:space:]]+$ ]]
}

emit_string_array() {
  local key="$1" values="$2" line first="yes"
  [ -n "$values" ] || return 0
  printf "%s = [" "$key"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$first" = "yes" ] || printf ", "
    printf '"%s"' "$(toml_escape "$line")"
    first="no"
  done <<EOF
$values
EOF
  printf "]\n"
}

render_config() {
  local role="$1" host="$2" network="$3" secret="$4" address_mode="$5" ipv4="$6"
  local peers="$7" proxies="$8" exits="$9" line
  validate_scalar "设备名称" "$host"
  validate_scalar "网络名称" "$network"
  validate_scalar "网络密钥" "$secret"
  case "$role" in first|join) ;; *) die "角色必须是 first 或 join。" ;; esac
  if [ "$role" = "join" ] && [ -z "$peers" ]; then die "加入已有网络至少需要一个 peer。"; fi
  case "$address_mode" in
    dhcp) ;;
    static) validate_ipv4 "$ipv4" || die "无效静态虚拟 IPv4：$ipv4" ;;
    *) die "地址模式必须是 dhcp 或 static。" ;;
  esac
  while IFS= read -r line; do [ -z "$line" ] || validate_peer_uri "$line" || die "无效 peer URI：$line"; done <<EOF
$peers
EOF
  while IFS= read -r line; do [ -z "$line" ] || validate_ipv4_cidr "$line" || die "无效子网 CIDR：$line"; done <<EOF
$proxies
EOF
  while IFS= read -r line; do [ -z "$line" ] || validate_ipv4_address "$line" || die "无效出口节点 IPv4：$line"; done <<EOF
$exits
EOF

  printf 'instance_name = "default"\n'
  printf 'hostname = "%s"\n' "$(toml_escape "$host")"
  if [ "$address_mode" = "dhcp" ]; then
    printf 'dhcp = true\n'
  else
    printf 'dhcp = false\n'
    printf 'ipv4 = "%s"\n' "$(toml_escape "$ipv4")"
  fi
  printf 'listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]\n'
  emit_string_array "exit_nodes" "$exits"
  printf '\n[network_identity]\n'
  printf 'network_name = "%s"\n' "$(toml_escape "$network")"
  printf 'network_secret = "%s"\n' "$(toml_escape "$secret")"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '\n[[peer]]\nuri = "%s"\n' "$(toml_escape "$line")"
  done <<EOF
$peers
EOF
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '\n[[proxy_network]]\ncidr = "%s"\n' "$(toml_escape "$line")"
  done <<EOF
$proxies
EOF
}

write_config() {
  local temp backup_stamp
  require_root
  ensure_dirs
  umask 077
  temp="$(mktemp "$STATE_DIR/config.toml.tmp.XXXXXX")"
  if ! render_config "$@" >"$temp"; then
    rm -f "$temp"
    return 1
  fi
  grep -F '[network_identity]' "$temp" >/dev/null || { rm -f "$temp"; die "配置缺少 network_identity。"; }
  grep -F 'listeners = ["tcp://0.0.0.0:11010", "udp://0.0.0.0:11010"]' "$temp" >/dev/null || { rm -f "$temp"; die "配置缺少默认监听器。"; }
  if [ -f "$CONFIG_FILE" ]; then
    backup_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
    cp -p "$CONFIG_FILE" "$BACKUP_DIR/config-$backup_stamp.toml"
  fi
  chmod 600 "$temp"
  mv "$temp" "$CONFIG_FILE"
  ok "配置已写入：$CONFIG_FILE"
}

prompt_default() {
  local prompt="$1" default="$2" value
  printf "%s [%s]: " "$prompt" "$default" >&2
  read -r value
  printf "%s\n" "${value:-$default}"
}

append_line() {
  local var_name="$1" value="$2" current
  eval "current=\${$var_name:-}"
  if [ -n "$current" ]; then
    printf -v "$var_name" '%s\n%s' "$current" "$value"
  else
    printf -v "$var_name" '%s' "$value"
  fi
}

configure_network() {
  local role_choice role host network secret address_choice address_mode="dhcp" ipv4=""
  local peers="" proxies="" exits="" value
  require_root
  [ -t 0 ] || die "configure 需要交互终端。"
  ui_title "EasyTier 快速配置"
  printf "  1. 创建首个节点（不填写 peer）\n"
  printf "  2. 加入已有自建网络\n"
  printf "请选择 [1-2]: "
  read -r role_choice
  case "$role_choice" in 1) role="first" ;; 2) role="join" ;; *) die "无效角色。" ;; esac

  host="$(prompt_default "设备名称" "$(hostname -s 2>/dev/null || hostname)")"
  network="$(prompt_default "网络名称" "my-network")"
  printf "网络密钥（输入不回显）: " >&2
  read -rs secret
  printf "\n" >&2
  validate_scalar "网络密钥" "$secret"

  printf "地址方式：1) DHCP  2) 静态虚拟 IP [1]: "
  read -r address_choice
  if [ "$address_choice" = "2" ]; then
    address_mode="static"
    ipv4="$(prompt_default "静态虚拟 IPv4" "10.144.144.1")"
  fi

  if [ "$role" = "join" ]; then
    while true; do
      value="$(prompt_default "自建 peer URI（留空结束）" "")"
      [ -n "$value" ] || break
      append_line peers "$value"
    done
    [ -n "$peers" ] || die "加入已有网络至少需要一个 peer。"
  fi
  while true; do
    value="$(prompt_default "子网代理 CIDR（可选，留空结束）" "")"
    [ -n "$value" ] || break
    append_line proxies "$value"
  done
  while true; do
    value="$(prompt_default "出口节点虚拟 IPv4（可选，留空结束）" "")"
    [ -n "$value" ] || break
    append_line exits "$value"
  done

  write_config "$role" "$host" "$network" "$secret" "$address_mode" "$ipv4" "$peers" "$proxies" "$exits"
  info "脚本不会修改防火墙。请自行放行 TCP/UDP 11010 和云安全组。"
  info "下一步：easytier service install"
}

redacted_config() {
  sed -E 's/^([[:space:]]*network_secret[[:space:]]*=).*/\1 "***"/' "$CONFIG_FILE"
}

show_info() {
  ui_title "EasyTier 信息"
  ui_kv "安装版本" "$(current_version)"
  ui_kv "安装目录" "$INSTALL_DIR"
  ui_kv "配置文件" "$CONFIG_FILE"
  ui_kv "服务状态" "$(service_status_output | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [ -r "$CONFIG_FILE" ]; then
    printf "\n%b配置摘要%b\n" "$bold" "$none"
    redacted_config | grep -E '^(hostname|dhcp|ipv4|listeners|exit_nodes|network_name|network_secret|uri|cidr)[[:space:]]*=' || true
  else
    warn "尚未生成配置，请执行 easytier configure。"
  fi
  printf "\n%b防火墙%b\n" "$bold" "$none"
  printf "  本脚本不会修改本机防火墙或云安全组。请按实际监听配置手动放行。\n"
}

run_cli_view() {
  local command="$1"
  [ -x "$CLI_BIN" ] || die "EasyTier 尚未安装。"
  "$CLI_BIN" "$command"
}

edit_config() {
  local editor backup_stamp
  require_root
  [ -f "$CONFIG_FILE" ] || die "配置不存在，请先执行 easytier configure。"
  ensure_dirs
  backup_stamp="$(date '+%Y%m%d-%H%M%S')-$$"
  cp -p "$CONFIG_FILE" "$BACKUP_DIR/config-$backup_stamp.toml"
  editor="${EDITOR:-}"
  if [ -n "$editor" ] && command -v "$editor" >/dev/null 2>&1; then
    "$editor" "$CONFIG_FILE"
  elif command -v nano >/dev/null 2>&1; then
    nano "$CONFIG_FILE"
  elif command -v vi >/dev/null 2>&1; then
    vi "$CONFIG_FILE"
  else
    die "未找到编辑器，请设置 EDITOR。"
  fi
  info "已保留编辑前备份。请执行 easytier service restart 和 easytier status 验证。"
}

uninstall_all() {
  local purge="${1:-}" status
  require_root
  if [ -t 0 ] && ! confirm "确认卸载 EasyTier OneClick？" no; then
    info "已取消卸载。"
    return 0
  fi
  if [ -x "$CLI_BIN" ]; then
    status="$(service_status_output)"
    case "$status" in
      *"Service is not installed"*) ;;
      *) "$CLI_BIN" service --name "$SERVICE_NAME" uninstall || warn "服务卸载失败，请手动检查。" ;;
    esac
  fi
  rm -f -- "$COMMAND_PATH"
  assert_safe_tree "$INSTALL_DIR"
  rm -rf -- "$INSTALL_DIR"
  if [ "$purge" = "--purge" ]; then
    assert_safe_tree "$STATE_DIR"
    rm -rf -- "$STATE_DIR"
    ok "程序、配置和备份已删除。"
  else
    ok "程序已删除，配置与备份保留在 $STATE_DIR。"
  fi
}

show_help() {
  ui_title "EasyTier OneClick"
  cat <<'EOF'
用法：easytier <command>

常用命令：
  menu                         打开中文交互菜单
  install [version]            安装最新稳定版或指定版本
  update [version]             确认后更新，保留配置并支持失败回滚
  configure                    快速配置首节点或加入自建网络
  service install              注册、启动并设置开机自启
  service start|stop|restart   管理服务
  service status|uninstall     查看或卸载系统服务
  info                         查看安装、服务与脱敏配置摘要
  peer | route | node          转发 EasyTier 官方状态命令
  edit-config                  备份后编辑原始 TOML
  uninstall [--purge]          卸载；默认保留配置
  help                         显示帮助

默认仅监听 TCP/UDP 11010，不使用公共共享节点，也不修改防火墙。
EOF
}

show_menu() {
  local choice
  while true; do
    ui_title "EasyTier OneClick 管理菜单"
    printf "  安装更新\n"
    printf "    1. 安装 EasyTier\n"
    printf "    2. 更新 EasyTier\n"
    printf "  快速配置\n"
    printf "    3. 创建或修改常用配置\n"
    printf "  服务管理\n"
    printf "    4. 一键注册并启动开机自启服务\n"
    printf "    5. 启动服务\n"
    printf "    6. 停止服务\n"
    printf "    7. 重启服务\n"
    printf "    8. 查看服务状态\n"
    printf "  网络状态\n"
    printf "    9. 综合信息\n"
    printf "   10. 节点列表  11. 路由  12. 本机节点\n"
    printf "  高级维护\n"
    printf "   13. 编辑原始配置  14. 卸载\n"
    printf "    0. 退出\n"
    ui_line
    printf "请选择 [0-14]: "
    read -r choice || exit 0
    case "$choice" in
      1) install_release install latest; ui_pause ;;
      2) install_release update latest; ui_pause ;;
      3) configure_network; ui_pause ;;
      4) service_action install; ui_pause ;;
      5) service_action start; ui_pause ;;
      6) service_action stop; ui_pause ;;
      7) service_action restart; ui_pause ;;
      8) service_action status; ui_pause ;;
      9) show_info; ui_pause ;;
      10) run_cli_view peer; ui_pause ;;
      11) run_cli_view route; ui_pause ;;
      12) run_cli_view node; ui_pause ;;
      13) edit_config; ui_pause ;;
      14) uninstall_all; exit 0 ;;
      0) exit 0 ;;
      *) warn "无效选择。"; ui_pause ;;
    esac
  done
}

main() {
  local command="${1:-menu}"
  shift || true
  case "$command" in
    menu) show_menu ;;
    help|-h|--help) show_help ;;
    install) install_release install "${1:-latest}" ;;
    update) install_release update "${1:-latest}" ;;
    configure|config) configure_network ;;
    service) service_action "${1:-status}" ;;
    status) service_action status ;;
    info) show_info ;;
    peer|route|node) run_cli_view "$command" ;;
    edit-config) edit_config ;;
    uninstall) uninstall_all "${1:-}" ;;
    *) die "未知命令：$command。执行 easytier help 查看帮助。" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
