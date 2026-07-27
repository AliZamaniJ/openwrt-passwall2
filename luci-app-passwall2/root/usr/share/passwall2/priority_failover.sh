#!/bin/sh

. /usr/share/libubox/jshn.sh
. /usr/share/passwall2/utils.sh

CONFIG_FILE="$1"
[ -s "$CONFIG_FILE" ] || exit 1

RUNTIME_NAME="$(basename "$CONFIG_FILE" .json)"
STATE_FILE="${CONFIG_FILE%.json}.state"
READY_FILE="${CONFIG_FILE%.json}.ready"
XRAY_BIN="$(first_type "$(config_t_get global_app xray_file)" xray)"
[ -x "$XRAY_BIN" ] || exit 1

load_config() {
	json_cleanup
	json_load "$(cat "$CONFIG_FILE")" || return 1
	json_get_var FAILOVER_ID id
	json_get_var API_PORT api_port
	json_get_var PROBE_PORT probe_port
	json_get_var MAIN_BALANCER main_balancer
	json_get_var PROBE_BALANCER probe_balancer
	json_get_var PRIMARY_ID primary_id
	json_get_var PRIMARY_TAG primary_tag
	json_get_var DIRECT_FALLBACK direct_fallback
	json_get_var RESTORE_PRIMARY restore_primary
	json_get_var CHECK_INTERVAL check_interval
	json_get_var CONNECT_TIMEOUT connect_timeout
	json_get_var FAILURE_THRESHOLD failure_threshold
	json_get_var RECOVERY_INTERVAL recovery_interval
	json_get_var RECOVERY_SUCCESSES recovery_successes
	json_get_var MINIMUM_DWELL minimum_dwell
	json_get_var PRIMARY_URL primary_url
	json_get_var SECONDARY_URL secondary_url

	CHECK_INTERVAL=${CHECK_INTERVAL:-20}
	CONNECT_TIMEOUT=${CONNECT_TIMEOUT:-3}
	FAILURE_THRESHOLD=${FAILURE_THRESHOLD:-2}
	RECOVERY_INTERVAL=${RECOVERY_INTERVAL:-300}
	RECOVERY_SUCCESSES=${RECOVERY_SUCCESSES:-2}
	MINIMUM_DWELL=${MINIMUM_DWELL:-600}
	PRIMARY_URL=${PRIMARY_URL:-https://www.gstatic.com/generate_204}
	SECONDARY_URL=${SECONDARY_URL:-https://cp.cloudflare.com/generate_204}
}

log_event() {
	logger -t passwall2-failover "[$FAILOVER_ID] $*"
}

override_balancer() {
	local balancer="$1"
	local outbound="$2"
	"$XRAY_BIN" api bo --server="127.0.0.1:${API_PORT}" -b "$balancer" "$outbound" >/dev/null 2>&1
}

write_state() {
	local reason="$1"
	printf '{"id":"%s","state":"%s","current_id":"%s","current_tag":"%s","reason":"%s","switched_at":%s}\n' \
		"$FAILOVER_ID" "$STATE" "$CURRENT_ID" "$CURRENT_TAG" "$reason" "$SWITCHED_AT" > "$STATE_FILE"
}

set_main() {
	local node_id="$1"
	local node_tag="$2"
	local state="$3"
	local reason="$4"
	override_balancer "$MAIN_BALANCER" "$node_tag" || return 1
	CURRENT_ID="$node_id"
	CURRENT_TAG="$node_tag"
	STATE="$state"
	SWITCHED_AT="$(date +%s)"
	ACTIVE_FAILURES=0
	RECOVERY_COUNT=0
	write_state "$reason"
	log_event "state=$STATE node=$CURRENT_ID reason=$reason"
}

probe_url() {
	local url="$1"
	local code
	code="$(/usr/bin/curl -o /dev/null -sS -L \
		--connect-timeout "$CONNECT_TIMEOUT" \
		--max-time "$((CONNECT_TIMEOUT + 3))" \
		--proxy "socks5h://127.0.0.1:${PROBE_PORT}" \
		-w '%{http_code}' "$url" 2>/dev/null)"
	[ "$code" = "204" ]
}

probe_tag() {
	local node_tag="$1"
	override_balancer "$PROBE_BALANCER" "$node_tag" || return 1
	probe_url "$PRIMARY_URL" && return 0
	probe_url "$SECONDARY_URL"
}

candidate_tag() {
	local wanted_id="$1"
	local keys key node_id node_tag
	json_select candidates || return 1
	json_get_keys keys
	for key in $keys; do
		json_select "$key"
		json_get_var node_id id
		json_get_var node_tag tag
		json_select ..
		if [ "$node_id" = "$wanted_id" ]; then
			json_select ..
			printf '%s' "$node_tag"
			return 0
		fi
	done
	json_select ..
	return 1
}

find_healthy_candidate() {
	local skip_id="$1"
	local keys key node_id node_tag
	json_select candidates || return 1
	json_get_keys keys
	for key in $keys; do
		json_select "$key"
		json_get_var node_id id
		json_get_var node_tag tag
		json_select ..
		[ "$node_id" = "$skip_id" ] && continue
		if probe_tag "$node_tag"; then
			json_select ..
			printf '%s|%s' "$node_id" "$node_tag"
			return 0
		fi
	done
	json_select ..
	return 1
}

backoff_seconds() {
	case "$1" in
		0) echo 15 ;;
		1) echo 30 ;;
		2) echo 60 ;;
		3) echo 120 ;;
		*) echo 300 ;;
	esac
}

restore_previous_state() {
	[ -s "$STATE_FILE" ] || return 1
	local saved_id saved_tag saved_state saved_switched candidate
	saved_id="$(jsonfilter -i "$STATE_FILE" -e '@.current_id' 2>/dev/null)"
	saved_tag="$(jsonfilter -i "$STATE_FILE" -e '@.current_tag' 2>/dev/null)"
	saved_state="$(jsonfilter -i "$STATE_FILE" -e '@.state' 2>/dev/null)"
	saved_switched="$(jsonfilter -i "$STATE_FILE" -e '@.switched_at' 2>/dev/null)"
	case "$saved_id" in
		direct) [ "$DIRECT_FALLBACK" = "1" ] || return 1 ;;
		blackhole) [ "$DIRECT_FALLBACK" != "1" ] || return 1 ;;
		*)
			candidate="$(candidate_tag "$saved_id")" || return 1
			[ "$candidate" = "$saved_tag" ] || return 1
		;;
	esac
	override_balancer "$MAIN_BALANCER" "$saved_tag" || return 1
	CURRENT_ID="$saved_id"
	CURRENT_TAG="$saved_tag"
	STATE=${saved_state:-backup}
	SWITCHED_AT=${saved_switched:-$(date +%s)}
	return 0
}

load_config || exit 1

CURRENT_ID="$PRIMARY_ID"
CURRENT_TAG="$PRIMARY_TAG"
STATE="primary"
SWITCHED_AT="$(date +%s)"
ACTIVE_FAILURES=0
RECOVERY_COUNT=0
LAST_RECOVERY_CHECK=0
BACKOFF_INDEX=0

api_ready=0
attempt=0
while [ "$attempt" -lt 10 ]; do
	if override_balancer "$PROBE_BALANCER" "$PRIMARY_TAG"; then
		api_ready=1
		break
	fi
	attempt=$((attempt + 1))
	sleep 1
done
[ "$api_ready" = "1" ] || exit 1

if ! restore_previous_state; then
	set_main "$PRIMARY_ID" "$PRIMARY_TAG" "primary" "startup" || exit 1
else
	write_state "supervisor-restart"
	log_event "state=$STATE node=$CURRENT_ID reason=supervisor-restart"
fi
touch "$READY_FILE"

trap 'rm -f "$READY_FILE"; exit 0' INT TERM EXIT

while true; do
	if [ "$STATE" = "all-down" ] || [ "$STATE" = "direct-fallback" ]; then
		candidate="$(find_healthy_candidate "")"
		if [ -n "$candidate" ]; then
			node_id=${candidate%%|*}
			node_tag=${candidate#*|}
			if [ "$node_id" = "$PRIMARY_ID" ]; then
				set_main "$node_id" "$node_tag" "primary" "node-recovered"
			else
				set_main "$node_id" "$node_tag" "backup" "node-recovered"
			fi
			BACKOFF_INDEX=0
			continue
		fi
		delay="$(backoff_seconds "$BACKOFF_INDEX")"
		[ "$BACKOFF_INDEX" -lt 4 ] && BACKOFF_INDEX=$((BACKOFF_INDEX + 1))
		sleep "$delay"
		continue
	fi

	if probe_tag "$CURRENT_TAG"; then
		ACTIVE_FAILURES=0
		if [ "$STATE" = "backup" ] && [ "$RESTORE_PRIMARY" != "0" ]; then
			now="$(date +%s)"
			if [ $((now - SWITCHED_AT)) -ge "$MINIMUM_DWELL" ] && [ $((now - LAST_RECOVERY_CHECK)) -ge "$RECOVERY_INTERVAL" ]; then
				LAST_RECOVERY_CHECK="$now"
				if probe_tag "$PRIMARY_TAG"; then
					RECOVERY_COUNT=$((RECOVERY_COUNT + 1))
					if [ "$RECOVERY_COUNT" -ge "$RECOVERY_SUCCESSES" ]; then
						set_main "$PRIMARY_ID" "$PRIMARY_TAG" "primary" "primary-stable"
					fi
				else
					RECOVERY_COUNT=0
				fi
			fi
		fi
		sleep "$CHECK_INTERVAL"
		continue
	fi

	ACTIVE_FAILURES=$((ACTIVE_FAILURES + 1))
	if [ "$ACTIVE_FAILURES" -lt "$FAILURE_THRESHOLD" ]; then
		sleep 2
		continue
	fi

	candidate="$(find_healthy_candidate "$CURRENT_ID")"
	if [ -n "$candidate" ]; then
		node_id=${candidate%%|*}
		node_tag=${candidate#*|}
		if [ "$node_id" = "$PRIMARY_ID" ]; then
			set_main "$node_id" "$node_tag" "primary" "active-node-failed"
		else
			set_main "$node_id" "$node_tag" "backup" "active-node-failed"
		fi
		continue
	fi

	if [ "$DIRECT_FALLBACK" = "1" ]; then
		set_main "direct" "direct" "direct-fallback" "all-nodes-failed"
	else
		set_main "blackhole" "blackhole" "all-down" "all-nodes-failed"
	fi
	BACKOFF_INDEX=0
done
