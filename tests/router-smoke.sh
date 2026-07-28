#!/bin/sh

set -eu

SOURCE_ROOT=${1:-.}
XRAY_BIN=$(readlink -f /tmp/etc/passwall2/bin/xray 2>/dev/null || true)
[ -x "$XRAY_BIN" ] || XRAY_BIN=$(command -v xray || true)
[ -x "$XRAY_BIN" ] || { echo "xray not found" >&2; exit 1; }

check_lua() {
	TEST_FILE="$1" lua -e 'assert(loadfile(os.getenv("TEST_FILE")))'
}

check_lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/api.lua"
check_lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/util_xray.lua"
check_lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/global.lua"
check_lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/acl_config.lua"
check_lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/node_config.lua"
check_lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/type/ray.lua"
check_lua "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/helper_dnsmasq.lua"

ash -n "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
ash -n "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/priority_failover.sh"

grep -q 'max-tcp-connections=' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/helper_dnsmasq.lua"
grep -q 'max-tcp-connections=${tcp_max_connections:-20}' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'protocol == "_failover"' "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/util_xray.lua"
grep -q 'minimum_failure_duration = tonumber' "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/util_xray.lua"
grep -q 'failover_failure_threshold".*"range(2,5)"' "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/type/ray.lua"
grep -q 'reason=probe-endpoint-failed.*url=$sanitized_url.*curl_exit=.*http_code=.*time_connect=.*time_tls=.*time_total=' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/priority_failover.sh"
! grep -q 'WAN_DETAIL="gateway-unreachable"' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/priority_failover.sh"
grep -q '#requested_nodes < 10' "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/util_xray.lua"
grep -q 'failover_backup_node' "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/type/ray.lua"
grep -q 'status.reason or translate("Unknown")' "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/type/ray.lua"
grep -q 'candidate.type == "Xray" and self_contained' "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/type/ray.lua"
grep -q 'backup_limit = 9' "$SOURCE_ROOT/luci-app-passwall2/luasrc/model/cbi/passwall2/client/type/ray.lua"
[ "$(grep -c 'start_priority_failover' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh")" -eq 3 ]
! grep -q 'start_priority_failove$' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'json_add_string "failover_runtime_dir" "${TMP_PATH}/failover"' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'json_add_string "xray_config_file" "${config_file}"' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'priority_failover_profile_exists "$failover_runtime_prefix"' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'start_priority_failover "$failover_runtime_prefix" 0' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'ready_timeout=30' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'stop_socks_runtime "$flag"' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/app.sh"
grep -q 'failover/SOCKS_test_node_${node_id}_' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/socks_auto_switch.sh"
grep -q 'failover/SOCKS_url_test_${node_id}_' "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/test.sh"

FAILOVER_SCRIPT="$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/priority_failover.sh"
FAILOVER_HELPERS="$(sed -n '/^normalize_failure_threshold()/,/^}/p; /^sanitize_probe_url()/,/^}/p; /^route_carrier_down()/,/^}/p; /^gateway_ping()/,/^}/p; /^wan_candidate_available()/,/^}/p; /^wan_available()/,/^}/p' "$FAILOVER_SCRIPT")"
eval "$FAILOVER_HELPERS"
[ "$(normalize_failure_threshold 1)" = "2" ]
[ "$(normalize_failure_threshold 2)" = "2" ]
[ "$(normalize_failure_threshold 5)" = "5" ]
[ "$(normalize_failure_threshold 6)" = "2" ]
[ "$(normalize_failure_threshold invalid)" = "2" ]
[ "$(sanitize_probe_url 'https://user:password@example.com:8443/health?token=secret#fragment')" = "https://example.com:8443/health" ]
[ "$(sanitize_probe_url '//user:password@example.com/health?token=secret')" = "//example.com/health" ]
[ "$(sanitize_probe_url 'https://example.com/health?token=secret')" = "https://example.com/health" ]
[ "$(sanitize_probe_url 'https://example.com/health#fragment')" = "https://example.com/health" ]
[ "$(sanitize_probe_url 'https://example.com/health')" = "https://example.com/health" ]
[ "$(sanitize_probe_url "$(printf 'https://example.com/health\nforged')")" = "https://example.com/health_forged" ]
ping() {
	case "$1:$2:$3" in
		-4:-I:wan4|-6:-I:wan6) return 0 ;;
		*) return 1 ;;
	esac
}
gateway_ping 4 wan4 192.0.2.1
gateway_ping 6 wan6 fe80::1
ip() {
	case "${WAN_TEST_SCENARIO}:$1" in
		ipv4:-4) echo 'default via 192.0.2.1 dev wan4' ;;
		ipv6:-6) echo 'default via fe80::1 dev wan6 metric 1024' ;;
		multi:-4) printf '%s\n' 'default via 192.0.2.1 dev wan4down metric 10' 'default via 192.0.2.2 dev wan4backup metric 20' ;;
		ecmp_first:-4) echo 'default proto static metric 10 nexthop via 192.0.2.1 dev wan4backup weight 1 nexthop via 192.0.2.2 dev wan4down weight 1' ;;
		ecmp_later:-4) echo 'default proto static metric 10 nexthop via 192.0.2.1 dev wan4down weight 1 nexthop via 192.0.2.2 dev wan4backup weight 1' ;;
		dual:-4) echo 'default via 192.0.2.1 dev wan4down' ;;
		dual:-6) echo 'default via fe80::1 dev wan6 metric 1024' ;;
		no_device:-4) echo 'default via 192.0.2.1' ;;
		all_down:-4) echo 'default via 192.0.2.1 dev wan4down' ;;
		all_down:-6) echo 'default via fe80::1 dev wan6down metric 1024' ;;
	esac
}
route_carrier_down() {
	case "$1" in
		wan4down|wan6down) return 0 ;;
		*) return 1 ;;
	esac
}
gateway_ping() { return 1; }

WAN_TEST_SCENARIO=ipv4
wan_available
[ "$WAN_FAMILY" = "4" ] && [ "$WAN_DEVICE" = "wan4" ] && [ "$WAN_DETAIL" = "gateway-ping-unanswered" ]
WAN_TEST_SCENARIO=ipv6
wan_available
[ "$WAN_FAMILY" = "6" ] && [ "$WAN_DEVICE" = "wan6" ] && [ "$WAN_DETAIL" = "gateway-ping-unanswered" ]
WAN_TEST_SCENARIO=multi
wan_available
[ "$WAN_FAMILY" = "4" ] && [ "$WAN_DEVICE" = "wan4backup" ]
WAN_TEST_SCENARIO=ecmp_first
wan_available
[ "$WAN_FAMILY" = "4" ] && [ "$WAN_DEVICE" = "wan4backup" ] && [ "$WAN_GATEWAY" = "192.0.2.1" ]
WAN_TEST_SCENARIO=ecmp_later
wan_available
[ "$WAN_FAMILY" = "4" ] && [ "$WAN_DEVICE" = "wan4backup" ] && [ "$WAN_GATEWAY" = "192.0.2.2" ]
WAN_TEST_SCENARIO=dual
wan_available
[ "$WAN_FAMILY" = "6" ] && [ "$WAN_DEVICE" = "wan6" ]
WAN_TEST_SCENARIO=none
if wan_available; then false; fi
[ "$WAN_DETAIL" = "no-default-route" ]
WAN_TEST_SCENARIO=no_device
if wan_available; then false; fi
[ "$WAN_DETAIL" = "no-default-device" ]
WAN_TEST_SCENARIO=all_down
if wan_available; then false; fi
[ "$WAN_DETAIL" = "carrier-down" ]

TCP_LIMIT=$(lua "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/helper_dnsmasq.lua" get_tcp_connection_limit)
case "$TCP_LIMIT" in
	''|*[!0-9]*) echo "invalid DNSMasq TCP limit: $TCP_LIMIT" >&2; exit 1 ;;
esac
[ "$TCP_LIMIT" -ge 1 ] && [ "$TCP_LIMIT" -le 100 ]

[ "${PW2_STATIC_ONLY:-0}" = "1" ] && {
	echo "priority failover static checks passed"
	exit 0
}

. /usr/share/passwall2/utils.sh
WORK_DIR=$(mktemp -d /tmp/passwall2-failover-smoke.XXXXXX)
XRAY_PID=""
SUPERVISOR_PID=""
HTTP_PID=""
UCI_TEST_SECTION=""
cleanup() {
	[ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" >/dev/null 2>&1 || true
	[ -n "$XRAY_PID" ] && kill "$XRAY_PID" >/dev/null 2>&1 || true
	[ -n "$HTTP_PID" ] && kill "$HTTP_PID" >/dev/null 2>&1 || true
	[ -n "$UCI_TEST_SECTION" ] && uci -q revert "passwall2.$UCI_TEST_SECTION" || true
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

DNS_COPY_CONF="$WORK_DIR/dnsmasq-copy.conf"
DNS_COPY_ARGS=$(printf '{"LISTEN_PORT":"32178","DNSMASQ_CONF":"%s"}' "$DNS_COPY_CONF")
lua "$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/helper_dnsmasq.lua" copy_instance "$DNS_COPY_ARGS"
[ -s "$DNS_COPY_CONF" ]
LOCAL_TCP_LIMITS=$(grep -c '^max-tcp-connections=' "$DNS_COPY_CONF" || true)
INHERITED_TCP_LIMIT=0
for included_config in $(sed -n 's/^[[:space:]]*conf-file[[:space:]]*=[[:space:]]*//p' "$DNS_COPY_CONF"); do
	grep -q '^[[:space:]]*max-tcp-connections[[:space:]]*=' "$included_config" 2>/dev/null && INHERITED_TCP_LIMIT=1
done
if [ "$INHERITED_TCP_LIMIT" = "1" ]; then
	[ "$LOCAL_TCP_LIMITS" -eq 0 ]
else
	[ "$LOCAL_TCP_LIMITS" -eq 1 ]
fi
dnsmasq --test -C "$DNS_COPY_CONF" >/dev/null

candidate_ids=""
for section in $(uci show passwall2 | sed -n "s/^passwall2\.\([^=]*\)=nodes$/\1/p"); do
	type=$(uci -q get "passwall2.$section.type" || true)
	protocol=$(uci -q get "passwall2.$section.protocol" || true)
	case "$protocol" in _*) continue ;; esac
	[ "$type" = "Xray" ] && candidate_ids="$candidate_ids $section"
done
set -- $candidate_ids
[ "$#" -ge 2 ]

UCI_TEST_SECTION="smokefo$$"
uci -q set "passwall2.$UCI_TEST_SECTION=nodes"
uci -q set "passwall2.$UCI_TEST_SECTION.type=Xray"
uci -q set "passwall2.$UCI_TEST_SECTION.protocol=_failover"
uci -q set "passwall2.$UCI_TEST_SECTION.remarks=Smoke Test Failover"
uci -q set "passwall2.$UCI_TEST_SECTION.failover_primary_node=$1"
uci -q add_list "passwall2.$UCI_TEST_SECTION.failover_backup_node=$2"

GEN_CONFIG="$WORK_DIR/generated-xray.json"
GEN_RUNTIME_DIR="$WORK_DIR/generated-runtime"
GEN_ARGS=$(printf '{"flag":"config-smoke","node":"%s","local_socks_address":"127.0.0.1","local_socks_port":"32179","direct_dns_udp_server":"127.0.0.1","direct_dns_udp_port":"53","no_run":"1","failover_runtime_dir":"%s"}' "$UCI_TEST_SECTION" "$GEN_RUNTIME_DIR")
lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/util_xray.lua" gen_config "$GEN_ARGS" > "$GEN_CONFIG"
GEN_RUNTIME=$(find "$GEN_RUNTIME_DIR" -type f -name '*.json' | head -n 1)
[ -s "$GEN_RUNTIME" ]
[ "$(jsonfilter -i "$GEN_RUNTIME" -e '@.primary_id')" = "$1" ]

uci -q set "passwall2.$UCI_TEST_SECTION.failover_primary_node=missing-smoke-node"
uci -q delete "passwall2.$UCI_TEST_SECTION.failover_backup_node"
uci -q add_list "passwall2.$UCI_TEST_SECTION.failover_backup_node=$1"
uci -q add_list "passwall2.$UCI_TEST_SECTION.failover_backup_node=$1"
uci -q add_list "passwall2.$UCI_TEST_SECTION.failover_backup_node=$2"
MISSING_RUNTIME_DIR="$WORK_DIR/missing-runtime"
MISSING_CONFIG="$WORK_DIR/missing-xray.json"
MISSING_ARGS=$(printf '{"flag":"missing-smoke","node":"%s","local_socks_address":"127.0.0.1","local_socks_port":"32179","direct_dns_udp_server":"127.0.0.1","direct_dns_udp_port":"53","no_run":"1","failover_runtime_dir":"%s"}' "$UCI_TEST_SECTION" "$MISSING_RUNTIME_DIR")
lua "$SOURCE_ROOT/luci-app-passwall2/luasrc/passwall2/util_xray.lua" gen_config "$MISSING_ARGS" > "$MISSING_CONFIG"
MISSING_RUNTIME=$(find "$MISSING_RUNTIME_DIR" -type f -name '*.json' | head -n 1)
[ -s "$MISSING_RUNTIME" ]
[ "$(jsonfilter -i "$MISSING_RUNTIME" -e '@.primary_id')" = "$1" ]
[ "$(jsonfilter -i "$MISSING_RUNTIME" -e '@.candidates[*].id' | wc -w)" -eq 2 ]

uci -q revert "passwall2.$UCI_TEST_SECTION"
UCI_TEST_SECTION=""

[ "${PW2_CONFIG_ONLY:-0}" = "1" ] && {
	echo "priority failover config generation passed"
	exit 0
}

"$XRAY_BIN" run -test -c "$GEN_CONFIG" >"$WORK_DIR/generated-config-test.log" 2>&1 || {
	cat "$WORK_DIR/generated-config-test.log" >&2
	exit 1
}

API_PORT=$(get_new_port 32180 tcp)
PROBE_PORT=$(get_new_port $((API_PORT + 1)) tcp)
MAIN_PORT=$(get_new_port $((PROBE_PORT + 1)) tcp)
HTTP_PORT=$(get_new_port $((MAIN_PORT + 1)) tcp)
XRAY_CONFIG="$WORK_DIR/xray.json"
RUNTIME_CONFIG="$WORK_DIR/smoke.json"

mkdir -p "$WORK_DIR/www/cgi-bin"
cat > "$WORK_DIR/www/cgi-bin/health" <<'EOF'
#!/bin/sh
printf 'Status: 200 OK\r\nContent-Length: 0\r\n\r\n'
EOF
chmod 755 "$WORK_DIR" "$WORK_DIR/www" "$WORK_DIR/www/cgi-bin" "$WORK_DIR/www/cgi-bin/health"
/usr/sbin/uhttpd -f -p "127.0.0.1:$HTTP_PORT" -h "$WORK_DIR/www" -x /cgi-bin >"$WORK_DIR/uhttpd.log" 2>&1 &
HTTP_PID=$!

cat > "$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "listen": "127.0.0.1:$API_PORT", "services": ["RoutingService"]},
  "inbounds": [
    {"tag": "probe-in", "listen": "127.0.0.1", "port": $PROBE_PORT, "protocol": "socks", "settings": {"auth": "noauth", "udp": false}},
    {"tag": "main-in", "listen": "127.0.0.1", "port": $MAIN_PORT, "protocol": "socks", "settings": {"auth": "noauth", "udp": false}}
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "blackhole", "protocol": "blackhole"}
  ],
  "routing": {
    "balancers": [
      {"tag": "smoke-main", "selector": ["blackhole"], "strategy": {"type": "random"}},
      {"tag": "smoke-probe", "selector": ["direct"], "strategy": {"type": "random"}}
    ],
    "rules": [
      {"inboundTag": ["probe-in"], "balancerTag": "smoke-probe"},
      {"inboundTag": ["main-in"], "balancerTag": "smoke-main"}
    ]
  }
}
EOF

cat > "$RUNTIME_CONFIG" <<EOF
{
  "id": "smoke",
  "xray_config_file": "$XRAY_CONFIG",
  "api_port": $API_PORT,
  "probe_port": $PROBE_PORT,
  "main_balancer": "smoke-main",
  "probe_balancer": "smoke-probe",
  "primary_id": "broken",
  "primary_tag": "blackhole",
  "candidates": [
    {"id": "broken", "tag": "blackhole"},
    {"id": "working", "tag": "direct"}
  ],
  "direct_fallback": false,
  "restore_primary": false,
  "check_interval": 10,
  "connect_timeout": 1,
  "failure_threshold": 2,
  "minimum_failure_duration": 2,
  "recovery_interval": 60,
  "recovery_successes": 2,
  "minimum_dwell": 60,
  "primary_url": "http://127.0.0.1:$HTTP_PORT/cgi-bin/health",
  "secondary_url": "http://127.0.0.1:$HTTP_PORT/cgi-bin/health"
}
EOF

if ! "$XRAY_BIN" run -test -c "$XRAY_CONFIG" >"$WORK_DIR/config-test.log" 2>&1; then
	cat "$WORK_DIR/config-test.log" >&2
	exit 1
fi
"$XRAY_BIN" run -c "$XRAY_CONFIG" >"$WORK_DIR/xray.log" 2>&1 &
XRAY_PID=$!

FAILURE_TEST_STARTED=$(date +%s)
"$SOURCE_ROOT/luci-app-passwall2/root/usr/share/passwall2/priority_failover.sh" "$RUNTIME_CONFIG" >"$WORK_DIR/supervisor.log" 2>&1 &
SUPERVISOR_PID=$!

attempt=0
while [ "$attempt" -lt 20 ]; do
	state=$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.state' 2>/dev/null || true)
	current=$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.current_id' 2>/dev/null || true)
	[ "$state" = "backup" ] && [ "$current" = "working" ] && break
	attempt=$((attempt + 1))
	sleep 1
done

[ "${state:-}" = "backup" ]
[ "${current:-}" = "working" ]
reason=$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.reason')
switched_at=$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.switched_at')
[ "$reason" = "node-failed" ]
[ $((switched_at - FAILURE_TEST_STARTED)) -ge 2 ]
code=$(/usr/bin/curl -o /dev/null -sS -L --connect-timeout 3 --max-time 6 \
	--proxy "socks5h://127.0.0.1:${MAIN_PORT}" -w '%{http_code}' \
	"http://127.0.0.1:$HTTP_PORT/cgi-bin/health")
[ "$code" = "200" ]

kill "$XRAY_PID"
wait "$XRAY_PID" 2>/dev/null || true
XRAY_PID=""
sleep 1
"$XRAY_BIN" run -c "$XRAY_CONFIG" >"$WORK_DIR/xray-restarted.log" 2>&1 &
XRAY_PID=$!

attempt=0
while [ "$attempt" -lt 20 ]; do
	reason=$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.reason' 2>/dev/null || true)
	code=$(/usr/bin/curl -o /dev/null -sS -L --connect-timeout 1 --max-time 2 \
		--proxy "socks5h://127.0.0.1:${MAIN_PORT}" -w '%{http_code}' \
		"http://127.0.0.1:$HTTP_PORT/cgi-bin/health" 2>/dev/null || true)
	[ "$reason" = "xray-recovered" ] && [ "$code" = "200" ] && break
	attempt=$((attempt + 1))
	sleep 1
done

[ "$reason" = "xray-recovered" ]
[ "$code" = "200" ]
[ "$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.state')" = "backup" ]
[ "$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.current_id')" = "working" ]
[ "$(jsonfilter -i "${RUNTIME_CONFIG%.json}.state" -e '@.switched_at')" = "$switched_at" ]
kill -0 "$SUPERVISOR_PID"

echo "priority failover smoke test passed"
