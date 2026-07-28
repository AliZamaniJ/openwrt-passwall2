# Priority Failover design

This document records why Priority Failover was added, how it works, and how to test or roll it back before proposing it upstream.

## Why this change exists

The first test device is a Linksys MX4200 with 512 MB of physical RAM. Two kernel OOM events killed Xray. One event coincided with roughly 26 private DNSMasq TCP worker processes. A local low-memory watchdog then made the outage worse by restarting all of PassWall2 repeatedly whenever `MemAvailable` dropped below a fixed threshold.

The high virtual-memory percentage shown for Xray in LuCI was not enough to establish a Go heap leak. Short samples showed Xray moving memory between RSS and swap without monotonic growth. The initial work therefore addresses unbounded helper processes and unnecessary restart churn instead of imposing `GOMEMLIMIT` or periodically restarting Xray.

The queued-process monitor fix from upstream PR #1197 is a prerequisite. It keeps queued Xray processes registered with the existing PassWall2 monitor. Priority Failover uses that monitor for process recovery and does not replace it.

## Why existing modes are not enough

`leastPing` and `leastLoad` continuously probe every selected outbound. Disabling observatory concurrency makes those probes serial, but it still tests every node forever and increases the time needed to complete a probe cycle.

Balancing also selects an outbound per connection. `random` and `roundRobin` intentionally spread new connections, while `leastPing` or `leastLoad` may change the selected outbound as observation results change. That is useful for distribution and latency, but it can expose different egress IPs over time to destinations that are sensitive to IP, country, or session changes. Priority Failover keeps the primary egress stable while it is healthy and changes it only after confirmed failure. Recovery thresholds and minimum backup dwell prevent frequent switching.

Socks Auto Switch provides primary/backup behavior, but it runs a separate SOCKS service and requires shunt traffic to be routed through that service. Priority Failover instead operates inside the existing Xray process and can be selected directly by a shunt rule.

## Configuration model

A `_failover` virtual node contains:

- one explicit primary Xray node;
- an ordered list of explicit backup Xray nodes;
- at most ten candidates in total;
- optional stable return to the primary;
- optional direct fallback, disabled by default;
- probe and hysteresis settings hidden behind an advanced switch.

Candidates are stored by UCI section ID. They are selected from every registered Xray node, including nodes created by any subscription. Special nodes, duplicate nodes, and the failover node itself are rejected. If a subscription removes a referenced node, the ID stays in the configuration and is shown as missing instead of being replaced by a name or country match.

## Runtime architecture

The existing Xray process contains all candidate outbounds, two balancers, a loopback-only probe SOCKS inbound, and a loopback-only RoutingService API inbound.

- The main balancer carries real shunt and remote-DNS traffic.
- The probe balancer is used only by the supervisor.
- The supervisor changes balancer overrides through the local Xray API.
- Runtime state is stored under `/tmp/etc/passwall2/failover` and is never committed to UCI.

PassWall2 starts queued processes before enabling transparent-proxy firewall rules. A failover profile must apply its initial override and create its readiness file before firewall activation. If initialization times out, startup is aborted and the normal cleanup path removes the partial state.

## State machine

The default timings are:

| Setting | Default |
| --- | ---: |
| Active check interval | 20 seconds |
| Connect timeout | 3 seconds |
| Failed health cycles | 2 |
| Minimum failure duration | 10 seconds |
| Primary recovery interval | 5 minutes |
| Primary recovery successes | 2 |
| Minimum backup dwell | 10 minutes |
| All-down retry backoff | 15, 30, 60, 120, 300 seconds |

The primary probe is `https://www.gstatic.com/generate_204`. If it fails, `https://cp.cloudflare.com/generate_204` confirms the failure. Custom URLs are also supported; any final HTTP 2xx response is healthy. A node is unhealthy only when both endpoints fail. By default, the second failed health cycle cannot complete the failure decision until at least ten seconds after the first failed cycle, which filters short correlated network stalls without requiring a third cycle.

Every failed endpoint probe records the node ID, URL, curl exit status, HTTP status, connect time, TLS handshake time, and total time in syslog with the `probe-endpoint-failed` reason. A confirmed active-node failure is recorded as `node-failed` when another candidate answers the same probes. If no candidate answers, the supervisor checks the default route and link carrier: a missing route or failed carrier is recorded as `wan-down`, while an available WAN with no successful candidate is recorded as `probe-endpoint-failed` and follows the configured all-down fallback policy. A gateway ping is diagnostic only because an unanswered ICMP request does not prove that the WAN is unavailable and must never suppress the all-down fallback.

While a node is healthy, no other candidate is probed. After the active node reaches the failure threshold, backups are tested serially in their configured order and the first healthy candidate wins. While a backup is active, only that backup receives normal health checks. The primary receives a recovery probe every five minutes and is restored only after the recovery threshold and minimum dwell time are both satisfied.

If every candidate fails, the main balancer is overridden to `blackhole` and retries continue with bounded backoff. When direct fallback is explicitly enabled, the override uses `direct` instead. Because remote DNS follows the same main balancer, direct fallback also exposes remote DNS until a proxy node recovers.

## DNSMasq TCP worker limit

PassWall2 copies the system DNSMasq configuration for private DNS instances, but custom limits were not reliably applied to every private configuration. The generator now ensures one effective `max-tcp-connections` value per instance. It reuses a value inherited through `conf-file`, or writes the PassWall2 value when no inherited limit exists, so DNSMasq never receives a duplicate keyword.

`dnsmasq_tcp_max_connections=0` selects 8 on devices whose visible memory is at most 512 MB and 20 on larger devices. An advanced value from 1 through 100 overrides the automatic choice.

## Testing

Run `tests/router-smoke.sh` from an unpacked tree on an OpenWrt test device. It performs Lua and shell syntax checks, starts an isolated Xray API/balancer configuration on temporary ports, verifies that a blackholed primary fails over to a working outbound, and leaves the active PassWall2 configuration untouched.

Before enabling the feature for real traffic, also test:

1. primary failure and ordered backup selection;
2. all candidates down with direct fallback both disabled and enabled;
3. stable primary restoration without flapping;
4. subscription deletion of the primary and a backup;
5. remote DNS before and after every switch;
6. a 48-hour soak with OOM, RSS+swap, file descriptors, DNSMasq workers, and service restarts recorded.

## Rollback

Change the shunt default back to the previous balancing node, restart PassWall2, and remove the `_failover` node. Existing balancing, shunt, SOCKS, Wi-Fi, and network UCI settings are not migrated or rewritten by this feature.

## Current limitations

- Only concrete, self-contained Xray nodes are accepted as candidates. Nodes that use pre-proxy or landing-node chaining are excluded so Priority Failover never starts an extra proxy core; outbound-interface binding remains supported.
- Existing connections are not migrated; new connections use the new override.
- Runtime state is intentionally lost on a full PassWall2 restart, which starts again from the configured primary.
- This branch is intended for fork testing on the MX4200 before any upstream proposal.
