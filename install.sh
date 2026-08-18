#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${EASYTIER_ONECLICK_REPO:-wzh195879702/easytier-oneclick}"
BRANCH="${EASYTIER_ONECLICK_BRANCH:-main}"

resolve_raw_base() {
  local direct="https://raw.githubusercontent.com/$REPO/$BRANCH"
  local proxy
  if [ -n "${EASYTIER_ONECLICK_RAW_BASE:-}" ]; then
    printf "%s\n" "${EASYTIER_ONECLICK_RAW_BASE%/}"
    return 0
  fi
  if [ "${EASYTIER_NO_GH_PROXY:-0}" = "1" ]; then
    printf "%s\n" "$direct"
    return 0
  fi
  proxy="${EASYTIER_GH_PROXY:-https://ghfast.top/}"
  printf "%s/%s\n" "${proxy%/}" "$direct"
}

RAW_BASE="$(resolve_raw_base)"
INSTALL_DIR="${EASYTIER_ONECLICK_INSTALL_DIR:-/opt/easytier-oneclick}"
COMMAND_PATH="${EASYTIER_ONECLICK_COMMAND_PATH:-/usr/local/bin/easytier}"
VERSION="latest"
LOCAL_SOURCE=""

die() { printf "[错误] %s\n" "$*" >&2; exit 1; }
info() { printf "[信息] %s\n" "$*"; }

usage() {
  cat <<'EOF'
用法：
  sudo bash install.sh [--version v2.6.4]
  sudo bash install.sh --local [--version v2.6.4]

选项：
  --local             从当前仓库安装管理脚本
  --version <version> 安装指定 EasyTier 版本，默认 latest
  --print-download-source
                      显示管理脚本下载源后退出
  -h, --help          显示帮助
EOF
}

require_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "请使用 root 或 sudo 执行。"
}

check_platform() {
  case "$(uname -s)" in
    Darwin) ;;
    Linux)
      [ -r /etc/os-release ] || die "仅支持 Debian 或 Ubuntu Linux。"
      local distro like
      distro="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print tolower($2) }' /etc/os-release)"
      like="$(awk -F= '$1 == "ID_LIKE" { gsub(/"/, "", $2); print tolower($2) }' /etc/os-release)"
      case " $distro $like " in
        *" debian "*|*" ubuntu "*) ;;
        *) die "仅支持 Debian 或 Ubuntu，当前发行版：${distro:-unknown}" ;;
      esac
      ;;
    *) die "此安装器仅支持 macOS、Debian 和 Ubuntu。Windows 请运行 install.ps1。" ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --local) LOCAL_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" ;;
      --version)
        [ "$#" -ge 2 ] || die "--version 缺少参数。"
        VERSION="$2"; shift
        ;;
      --print-download-source) printf "%s\n" "$RAW_BASE"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知选项：$1" ;;
    esac
    shift
  done
}

install_manager() {
  local temp_manager
  mkdir -p "$INSTALL_DIR" "$(dirname "$COMMAND_PATH")"
  if [ -n "$LOCAL_SOURCE" ]; then
    [ -f "$LOCAL_SOURCE/easytier.sh" ] || die "本地仓库缺少 easytier.sh。"
    cp "$LOCAL_SOURCE/easytier.sh" "$INSTALL_DIR/easytier.sh"
  else
    command -v curl >/dev/null 2>&1 || die "缺少必要命令：curl"
    temp_manager="$(mktemp "${TMPDIR:-/tmp}/easytier-manager.XXXXXX")"
    curl -fsSL --retry 3 "$RAW_BASE/easytier.sh" -o "$temp_manager" || die "下载管理脚本失败。"
    cp "$temp_manager" "$INSTALL_DIR/easytier.sh"
    rm -f "$temp_manager"
  fi
  chmod 755 "$INSTALL_DIR/easytier.sh"

  cat >"$COMMAND_PATH" <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/easytier.sh" "\$@"
EOF
  chmod 755 "$COMMAND_PATH"
}

main() {
  parse_args "$@"
  require_root
  check_platform
  command -v unzip >/dev/null 2>&1 || die "缺少必要命令：unzip"
  install_manager
  info "管理命令已安装：$COMMAND_PATH"
  "$INSTALL_DIR/easytier.sh" install "$VERSION"
  printf "\n下一步：\n"
  printf "  sudo easytier configure\n"
  printf "  sudo easytier service install\n"
}

main "$@"
