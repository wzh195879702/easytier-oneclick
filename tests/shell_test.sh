#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/easytier-shell-test.XXXXXX")"
export EASYTIER_ONECLICK_INSTALL_DIR="$TEST_ROOT/install"
export EASYTIER_ONECLICK_STATE_DIR="$TEST_ROOT/state"
export EASYTIER_ONECLICK_CONFIG_FILE="$TEST_ROOT/state/config.toml"
export EASYTIER_ONECLICK_BACKUP_DIR="$TEST_ROOT/state/backups"
export EASYTIER_ONECLICK_COMMAND_PATH="$TEST_ROOT/bin/easytier"
export EASYTIER_ONECLICK_ALLOW_NON_ROOT=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../easytier.sh
. "$SCRIPT_DIR/easytier.sh"

trap 'rm -rf -- "$TEST_ROOT"' EXIT

pass_count=0
fail() { printf "not ok - %s\n" "$*" >&2; exit 1; }
pass() { pass_count=$((pass_count + 1)); printf "ok %d - %s\n" "$pass_count" "$*"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected output to contain: $2" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "expected output not to contain: $2" ;; *) ;; esac; }

test_asset_names() {
  [ "$(asset_name_for macos aarch64 v2.6.4)" = "easytier-macos-aarch64-v2.6.4.zip" ] || fail "macOS asset mapping"
  [ "$(asset_name_for linux x86_64 v2.6.4)" = "easytier-linux-x86_64-v2.6.4.zip" ] || fail "Linux asset mapping"
  pass "release asset names"
}

test_first_node_config() {
  local output required
  output="$(render_config first node-a net-a 's3cret' dhcp '' '' '' '')"
  while IFS= read -r required; do
    [ -n "$required" ] && assert_contains "$output" "$required"
  done <"$SCRIPT_DIR/tests/fixtures/config-required-lines.txt"
  assert_contains "$output" 'dhcp = true'
  assert_contains "$output" 'tcp://0.0.0.0:11010'
  assert_contains "$output" 'udp://0.0.0.0:11010'
  assert_contains "$output" 'network_name = "net-a"'
  assert_not_contains "$output" '[[peer]]'
  assert_not_contains "$output" 'public.easytier'
  pass "first node config has no public or explicit peer"
}

test_join_config() {
  local peers proxies exits output
  peers="tcp://peer.example:11010
udp://10.0.0.2:11010"
  proxies="192.168.1.0/24
10.20.0.0/16"
  exits="10.144.144.9"
  output="$(render_config join 'node-b' 'net-b' 'q"w\e' static '10.144.144.2' "$peers" "$proxies" "$exits")"
  assert_contains "$output" 'dhcp = false'
  assert_contains "$output" 'ipv4 = "10.144.144.2"'
  assert_contains "$output" 'uri = "tcp://peer.example:11010"'
  assert_contains "$output" 'uri = "udp://10.0.0.2:11010"'
  assert_contains "$output" 'cidr = "192.168.1.0/24"'
  assert_contains "$output" 'exit_nodes = ["10.144.144.9"]'
  assert_contains "$output" 'network_secret = "q\"w\\e"'
  pass "join config supports static IP, multiple peers, subnet and exit node"
}

test_join_requires_peer() {
  if (render_config join node net secret dhcp '' '' '' '') >/dev/null 2>&1; then
    fail "join config accepted empty peer list"
  fi
  pass "join config rejects empty peer list"
}

test_atomic_write_and_redaction() {
  local summary backup_count
  write_config first node net first-secret dhcp '' '' '' '' >/dev/null
  [ -f "$CONFIG_FILE" ] || fail "config was not written"
  write_config first node net second-secret dhcp '' '' '' '' >/dev/null
  backup_count="$(find "$BACKUP_DIR" -type f -name 'config-*.toml' | wc -l | tr -d '[:space:]')"
  [ "$backup_count" -eq 1 ] || fail "expected one config backup"
  summary="$(redacted_config)"
  assert_contains "$summary" 'network_secret = "***"'
  assert_not_contains "$summary" 'second-secret'
  grep -F 'first-secret' "$BACKUP_DIR"/config-*.toml >/dev/null || fail "backup does not contain previous config"
  pass "config replacement is backed up and info is redacted"
}

test_invalid_inputs() {
  if (render_config first node net secret static '999.1.1.1' '' '' '') >/dev/null 2>&1; then
    fail "invalid IPv4 accepted"
  fi
  if (render_config join node net secret dhcp '' 'http://peer:11010' '' '') >/dev/null 2>&1; then
    fail "invalid peer scheme accepted"
  fi
  if (render_config first node net secret dhcp '' '' '192.168.1.1' '') >/dev/null 2>&1; then
    fail "proxy network without CIDR accepted"
  fi
  if (render_config first node net secret dhcp '' '' '' '10.144.144.9/24') >/dev/null 2>&1; then
    fail "exit node CIDR accepted"
  fi
  if (render_config first $'bad\nname' net secret dhcp '' '' '' '') >/dev/null 2>&1; then
    fail "control character accepted"
  fi
  pass "invalid IP, CIDR, peer and control characters are rejected"
}

test_help_and_firewall_boundary() {
  local help
  help="$(show_help)"
  assert_contains "$help" 'service install'
  assert_contains "$help" '不修改防火墙'
  if grep -En '(^|[[:space:]])(ufw|iptables|nft|firewall-cmd|pfctl|netsh[[:space:]]+advfirewall|New-NetFirewallRule)([[:space:]]|$)' "$SCRIPT_DIR/easytier.sh" "$SCRIPT_DIR/install.sh"; then
    fail "implementation contains firewall mutation command"
  fi
  pass "help exposes common commands and implementation does not mutate firewall"
}

test_awk_regex_portability() {
  if grep -F 'gsub(/\"/' "$SCRIPT_DIR/easytier.sh" "$SCRIPT_DIR/install.sh" >/dev/null; then
    fail "awk quote regex contains a non-portable escape"
  fi
  pass "awk quote regex is portable across awk implementations"
}

write_mock_cli() {
  local path="$1" behavior="$2"
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_ROOT/cli-calls.log"
case "\$*" in
  *status*) printf 'Service is running\n' ;;
  *start*) [ "$behavior" = "fail-start" ] && exit 1 || exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$path"
}

test_service_contract() {
  mkdir -p "$INSTALL_DIR"
  : >"$TEST_ROOT/cli-calls.log"
  write_mock_cli "$CLI_BIN" normal
  [ -f "$CONFIG_FILE" ] || write_config first node net secret dhcp '' '' '' '' >/dev/null
  service_action install >/dev/null
  grep -F "service --name easytier-oneclick install --display-name EasyTier --service-work-dir $INSTALL_DIR -- -c $CONFIG_FILE" "$TEST_ROOT/cli-calls.log" >/dev/null || fail "service install arguments drifted"
  grep -F 'service --name easytier-oneclick start' "$TEST_ROOT/cli-calls.log" >/dev/null || fail "service was not started after registration"
  pass "service registration delegates to official CLI and starts the service"
}

test_update_rollback() {
  local result
  mkdir -p "$INSTALL_DIR"
  : >"$TEST_ROOT/cli-calls.log"
  printf '#!/usr/bin/env bash\nprintf "old-core\\n"\n' >"$CORE_BIN"
  chmod +x "$CORE_BIN"
  write_mock_cli "$CLI_BIN" normal
  printf 'v1.0.0\n' >"$VERSION_FILE"

  resolve_version() { printf 'v2.6.4\n'; }
  detect_os() { printf 'macos\n'; }
  download_release() {
    local _version="$1" destination="$2"
    mkdir -p "$destination/bin"
    printf '#!/usr/bin/env bash\nprintf "new-core\\n"\n' >"$destination/bin/easytier-core"
    chmod +x "$destination/bin/easytier-core"
    write_mock_cli "$destination/bin/easytier-cli" fail-start
  }
  export EASYTIER_ONECLICK_ASSUME_YES=1
  if (install_release update latest) >/dev/null 2>&1; then
    fail "update unexpectedly succeeded after simulated start failure"
  fi
  result="$($CORE_BIN)"
  [ "$result" = "old-core" ] || fail "old core was not restored"
  [ "$(tr -d '[:space:]' <"$VERSION_FILE")" = "v1.0.0" ] || fail "old version marker was not restored"
  pass "failed update restores previous binaries and version"
}

test_asset_names
test_first_node_config
test_join_config
test_join_requires_peer
test_atomic_write_and_redaction
test_invalid_inputs
test_help_and_firewall_boundary
test_awk_regex_portability
test_service_contract
test_update_rollback

printf "1..%d\n" "$pass_count"
