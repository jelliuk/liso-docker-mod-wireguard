# shellcheck shell=bash
# shared helpers for the NordVPN config-rotation scripts (sourced, not executed)

NORDVPN_DIR="${NORDVPN_DIR:-/nordvpn}"
NORDVPN_IFACE="${NORDVPN_IFACE:-nordvpn0}"
NORDVPN_STATE_DIR="${NORDVPN_STATE_DIR:-/config/nordvpn}"
NORDVPN_RUN_DIR="${NORDVPN_RUN_DIR:-/run/nordvpn}"
NORDVPN_CHECK_INTERVAL="${NORDVPN_CHECK_INTERVAL:-3600}"
NORDVPN_RETRY_DELAY="${NORDVPN_RETRY_DELAY:-30}"
NORDVPN_CONNECT_TIMEOUT="${NORDVPN_CONNECT_TIMEOUT:-30}"
NORDVPN_CHECK_TIMEOUT="${NORDVPN_CHECK_TIMEOUT:-10}"
NORDVPN_CHECK_RETRIES="${NORDVPN_CHECK_RETRIES:-3}"
NORDVPN_MAX_HANDSHAKE_AGE="${NORDVPN_MAX_HANDSHAKE_AGE:-180}"
NORDVPN_CHECK_URLS="${NORDVPN_CHECK_URLS:-https://api.nordvpn.com/v1/helpers/ips/insights https://1.1.1.1/cdn-cgi/trace}"
NORDVPN_KILLSWITCH="${NORDVPN_KILLSWITCH:-true}"
NORDVPN_BOOTSTRAP_DNS="${NORDVPN_BOOTSTRAP_DNS:-true}"
NORDVPN_START_FROM_LAST="${NORDVPN_START_FROM_LAST:-true}"
# optional DNS override (comma or space separated), replaces the DNS= line of every conf
NORDVPN_DNS="${NORDVPN_DNS:-}"

log() {
    echo "**** [nordvpn] $* ****"
}

# NORDVPN_ENABLED: true | false | auto (default).
# auto = active when /nordvpn contains *.conf files and server mode (PEERS) is not in use.
nordvpn_enabled() {
    case "${NORDVPN_ENABLED,,}" in
        true | 1 | yes) return 0 ;;
        false | 0 | no) return 1 ;;
    esac
    [[ -z "${PEERS}" ]] && compgen -G "${NORDVPN_DIR}/*.conf" > /dev/null
}

# ---- config discovery -------------------------------------------------------

# fills CONFS[] with valid conf paths, sorted by name
load_confs() {
    CONFS=()
    local f
    while IFS= read -r f; do
        [[ -f "${f}" ]] || continue
        if grep -qi '^\[Interface\]' "${f}" && grep -qi '^\[Peer\]' "${f}"; then
            CONFS+=("${f}")
        else
            log "Skipping ${f##*/}: no [Interface]/[Peer] section"
        fi
    done < <(compgen -G "${NORDVPN_DIR}/*.conf" | LC_ALL=C sort)
}

conf_index() {
    local name="$1" i
    for i in "${!CONFS[@]}"; do
        if [[ "${CONFS[${i}]##*/}" == "${name}" ]]; then
            echo "${i}"
            return 0
        fi
    done
    return 1
}

state_get_last() {
    cat "${NORDVPN_STATE_DIR}/last_conf" 2> /dev/null
}

state_set_last() {
    mkdir -p "${NORDVPN_STATE_DIR}" 2> /dev/null && printf '%s\n' "$1" > "${NORDVPN_STATE_DIR}/last_conf" 2> /dev/null
    return 0
}

# state file read by the docker healthcheck / for debugging: cat /run/nordvpn/status
write_status() {
    mkdir -p "${NORDVPN_RUN_DIR}"
    printf 'state=%s\nconf=%s\nupdated=%s\n' "$1" "$2" "$(date +%s)" > "${NORDVPN_RUN_DIR}/status.tmp"
    mv -f "${NORDVPN_RUN_DIR}/status.tmp" "${NORDVPN_RUN_DIR}/status"
}

# ---- networking -------------------------------------------------------------

# remember the container's original (non-VPN) route; must run before a tunnel is up
capture_uplink() {
    mkdir -p "${NORDVPN_RUN_DIR}"
    [[ -s "${NORDVPN_RUN_DIR}/uplink" ]] && return 0
    local line dev gw
    line=$(ip -4 route show default 2> /dev/null | head -n1)
    dev=$(awk '{for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1)}' <<< "${line}")
    gw=$(awk '{for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1)}' <<< "${line}")
    [[ -n "${dev}" ]] && printf 'UPLINK_DEV=%s\nUPLINK_GW=%s\n' "${dev}" "${gw}" > "${NORDVPN_RUN_DIR}/uplink"
    return 0
}

# route NET_LOCAL (comma or space separated CIDRs) via the original gateway so LAN
# clients can still reach published ports / the web UI while the tunnel is up
add_local_routes() {
    [[ -n "${NET_LOCAL}" ]] || return 0
    local UPLINK_DEV UPLINK_GW cidr
    # shellcheck source=/dev/null
    . "${NORDVPN_RUN_DIR}/uplink" 2> /dev/null
    if [[ -z "${UPLINK_DEV}" || -z "${UPLINK_GW}" ]]; then
        log "No original default gateway found, cannot add NET_LOCAL routes"
        return 0
    fi
    for cidr in ${NET_LOCAL//,/ }; do
        if ip route replace "${cidr}" via "${UPLINK_GW}" dev "${UPLINK_DEV}"; then
            log "Route ${cidr} via ${UPLINK_GW} (${UPLINK_DEV})"
        fi
    done
}

# UDP ports of every Endpoint in every conf (default 51820)
endpoint_ports() {
    {
        grep -hi '^[[:space:]]*Endpoint' "${NORDVPN_DIR}"/*.conf 2> /dev/null | tr -d '\r' | sed -E 's/.*:([0-9]+)[[:space:]]*$/\1/'
        echo 51820
    } | grep -E '^[0-9]+$' | sort -un
}

# Drop everything leaving the container except: loopback, the tunnel itself, the LAN
# (NET_LOCAL + connected docker subnet) and the WireGuard handshake to NordVPN endpoints.
setup_killswitch() {
    [[ "${NORDVPN_KILLSWITCH,,}" == "false" ]] && return 0
    local chain="NORDVPN_KILLSWITCH" UPLINK_DEV UPLINK_GW net port
    # shellcheck source=/dev/null
    . "${NORDVPN_RUN_DIR}/uplink" 2> /dev/null

    iptables -N "${chain}" 2> /dev/null || iptables -F "${chain}"
    iptables -C OUTPUT -j "${chain}" 2> /dev/null || iptables -I OUTPUT 1 -j "${chain}"
    iptables -A "${chain}" -o lo -j ACCEPT
    iptables -A "${chain}" -o "${NORDVPN_IFACE}" -j ACCEPT
    if [[ -n "${UPLINK_DEV}" ]]; then
        while read -r net; do
            [[ -n "${net}" ]] && iptables -A "${chain}" -d "${net}" -j ACCEPT
        done < <(ip -4 route show dev "${UPLINK_DEV}" scope link | awk '{print $1}')
    fi
    for net in ${NET_LOCAL//,/ }; do
        iptables -A "${chain}" -d "${net}" -j ACCEPT
    done
    for port in $(endpoint_ports); do
        iptables -A "${chain}" -p udp --dport "${port}" -j ACCEPT
    done
    if [[ "${NORDVPN_BOOTSTRAP_DNS,,}" != "false" ]]; then
        # needed to resolve Endpoint hostnames while no tunnel is up
        iptables -A "${chain}" -p udp --dport 53 -j ACCEPT
        iptables -A "${chain}" -p tcp --dport 53 -j ACCEPT
    fi
    iptables -A "${chain}" -j REJECT

    # best effort for IPv6 (usually disabled via sysctl anyway)
    if ip6tables -L OUTPUT > /dev/null 2>&1; then
        ip6tables -N "${chain}" 2> /dev/null || ip6tables -F "${chain}"
        ip6tables -C OUTPUT -j "${chain}" 2> /dev/null || ip6tables -I OUTPUT 1 -j "${chain}"
        ip6tables -A "${chain}" -o lo -j ACCEPT
        ip6tables -A "${chain}" -o "${NORDVPN_IFACE}" -j ACCEPT
        ip6tables -A "${chain}" -j REJECT
    fi
    log "Kill switch active (only the tunnel, ${NET_LOCAL:-no NET_LOCAL} and the docker subnet may bypass it)"
}

# ---- tunnel lifecycle -------------------------------------------------------

# rewrites the DNS= line of [Interface] when NORDVPN_DNS is set, otherwise passes through
apply_dns_override() {
    if [[ -z "${NORDVPN_DNS// /}" ]]; then
        cat
        return
    fi
    local dns="${NORDVPN_DNS//,/ }"
    dns="$(echo ${dns} | tr -s ' ' ',')"
    awk -v dns="${dns}" '
        tolower($0) ~ /^[ \t]*dns[ \t]*=/ { next }
        { print }
        tolower($0) ~ /^[ \t]*\[interface\]/ && !done { print "DNS = " dns; done = 1 }
    '
}

stage_conf() {
    local dst="${NORDVPN_RUN_DIR}/${NORDVPN_IFACE}.conf"
    mkdir -p "${NORDVPN_RUN_DIR}"
    (umask 077 && tr -d '\r' < "$1" | apply_dns_override > "${dst}.new") && mv -f "${dst}.new" "${dst}"
}

tunnel_down() {
    local f="${NORDVPN_RUN_DIR}/${NORDVPN_IFACE}.conf"
    if ip link show dev "${NORDVPN_IFACE}" > /dev/null 2>&1; then
        if [[ -f "${f}" ]]; then
            wg-quick down "${f}" || :
        fi
        # fallback if wg-quick could not clean up
        ip link del dev "${NORDVPN_IFACE}" 2> /dev/null || :
        resolvconf -d "${NORDVPN_IFACE}" 2> /dev/null || :
    fi
}

# seconds since last handshake, empty if none
handshake_age() {
    local ts
    ts=$(wg show "${NORDVPN_IFACE}" latest-handshakes 2> /dev/null | awk 'NR == 1 {print $2}')
    [[ -n "${ts}" && "${ts}" != "0" ]] || return 1
    echo $(($(date +%s) - ts))
}

wait_handshake() {
    local t=0
    # nudge the handshake along in case the conf has no PersistentKeepalive
    (ping -c 1 -W 2 1.1.1.1 > /dev/null 2>&1 &)
    while ((t < NORDVPN_CONNECT_TIMEOUT)); do
        handshake_age > /dev/null && return 0
        sleep 1
        t=$((t + 1))
    done
    return 1
}

# true if any check URL answers through the tunnel
check_connectivity() {
    local attempt url
    for ((attempt = 1; attempt <= NORDVPN_CHECK_RETRIES; attempt++)); do
        for url in ${NORDVPN_CHECK_URLS}; do
            if curl -fsS -o /dev/null --max-time "${NORDVPN_CHECK_TIMEOUT}" "${url}" 2> /dev/null; then
                return 0
            fi
        done
        sleep 2
    done
    return 1
}

# full health check used by the monitor. Connectivity is tested first so the traffic
# itself triggers a fresh handshake on an idle tunnel before the handshake age is read.
tunnel_healthy() {
    ip link show dev "${NORDVPN_IFACE}" > /dev/null 2>&1 || return 1
    check_connectivity || return 1
    local age
    age=$(handshake_age) || return 1
    ((age <= NORDVPN_MAX_HANDSHAKE_AGE))
}

log_exit_info() {
    local info
    info=$(curl -fsS --max-time "${NORDVPN_CHECK_TIMEOUT}" "https://api.nordvpn.com/v1/helpers/ips/insights" 2> /dev/null |
        grep -oE '"(ip|country|city|protected)":("[^"]*"|true|false)' | tr -d '"' | tr '\n' ' ')
    [[ -n "${info}" ]] && log "Exit info: ${info}"
    return 0
}

# bring up one conf and verify it works; leaves the tunnel down on failure
tunnel_up() {
    local conf="$1"
    stage_conf "${conf}" || return 1
    if ! wg-quick up "${NORDVPN_RUN_DIR}/${NORDVPN_IFACE}.conf"; then
        log "wg-quick failed for ${conf##*/}"
        tunnel_down
        return 1
    fi
    add_local_routes
    if ! wait_handshake; then
        log "No handshake within ${NORDVPN_CONNECT_TIMEOUT}s for ${conf##*/}"
        tunnel_down
        return 1
    fi
    if ! check_connectivity; then
        log "Handshake OK but no connectivity through ${conf##*/}"
        tunnel_down
        return 1
    fi
    return 0
}
