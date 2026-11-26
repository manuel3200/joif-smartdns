#!/usr/bin/env bash
# core/metrics.sh — Metricas ultralivianas (Mbps en vivo, disco/RAM, origen/trafico por IP, top dominios)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/licenses.sh
source "${SCRIPT_DIR}/licenses.sh"

metrics_default_iface() {
    local iface=""
    if command -v ip >/dev/null 2>&1; then
        iface="$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    fi
    if [[ -z "$iface" && -d /sys/class/net ]]; then
        local d base
        for d in /sys/class/net/*; do
            base="$(basename "$d")"
            [[ "$base" == "lo" ]] && continue
            iface="$base"
            break
        done
    fi
    printf '%s\n' "${iface:-eth0}"
}

# Mide velocidad instantanea RX/TX en Mbps leyendo /sys/class/net (sin paquetes extra)
# Salida: iface|rx_mbps|tx_mbps|total_mbps
metrics_net_mbps() {
    local sample_sec="${1:-${JOIF_NET_SAMPLE_SEC:-1}}"
    local iface
    iface="$(metrics_default_iface)"
    local rx_file="/sys/class/net/${iface}/statistics/rx_bytes"
    local tx_file="/sys/class/net/${iface}/statistics/tx_bytes"

    if [[ ! -r "$rx_file" || ! -r "$tx_file" ]]; then
        printf '%s|0.00|0.00|0.00\n' "$iface"
        return 0
    fi

    local rx1 tx1 rx2 tx2
    rx1="$(cat "$rx_file" 2>/dev/null || echo 0)"
    tx1="$(cat "$tx_file" 2>/dev/null || echo 0)"
    sleep "$sample_sec"
    rx2="$(cat "$rx_file" 2>/dev/null || echo 0)"
    tx2="$(cat "$tx_file" 2>/dev/null || echo 0)"

    awk -v iface="$iface" -v rx1="$rx1" -v tx1="$tx1" -v rx2="$rx2" -v tx2="$tx2" -v dt="$sample_sec" 'BEGIN {
        if (dt <= 0) dt = 1;
        drx = (rx2 >= rx1) ? (rx2 - rx1) : 0;
        dtx = (tx2 >= tx1) ? (tx2 - tx1) : 0;
        rx_mbps = (drx * 8) / (dt * 1000000);
        tx_mbps = (dtx * 8) / (dt * 1000000);
        printf "%s|%.2f|%.2f|%.2f\n", iface, rx_mbps, tx_mbps, rx_mbps + tx_mbps;
    }'
}

# Salida: disk_used|disk_total|disk_pct|disk_avail|ram_used_mb|ram_total_mb
metrics_disk_ram() {
    local d_used="-" d_total="-" d_pct="-" d_avail="-" r_used="-" r_total="-"

    if command -v df >/dev/null 2>&1; then
        read -r d_total d_used d_avail d_pct < <(df -h -P / 2>/dev/null | awk 'NR==2{print $2, $3, $4, $5}' || true)
    fi

    if command -v free >/dev/null 2>&1; then
        read -r r_total r_used < <(free -m 2>/dev/null | awk '/^Mem:/{print $2, $3}' || true)
    elif [[ -r /proc/meminfo ]]; then
        read -r r_total r_used < <(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{if(t>0) printf "%d %d\n", t/1024, (t-a)/1024}' /proc/meminfo 2>/dev/null || true)
    fi

    printf '%s|%s|%s|%s|%s|%s\n' "${d_used:--}" "${d_total:--}" "${d_pct:--}" "${d_avail:--}" "${r_used:--}" "${r_total:--}"
}

# Top dominios SNI interceptados desde el log liviano actual (excluyendo pruebas de 127.0.0.1)
# Salida: domain|hits|bytes|human_bytes
metrics_top_domains() {
    local limit="${1:-10}"
    local log_file="${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log"
    [[ -f "$log_file" ]] || return 0

    local dom hits bytes
    while IFS='|' read -r dom hits bytes; do
        [[ -z "$dom" ]] && continue
        printf '%s|%s|%s|%s\n' "$dom" "$hits" "$bytes" "$(joif_human_bytes "$bytes")"
    done < <(
        awk '
            $1 == "127.0.0.1" { next }
            {
                sni=""; sent=0; recv=0; allowed=0;
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^sni="/) {
                        sni=$i; sub(/^sni="/, "", sni); sub(/"$/, "", sni);
                    } else if ($i ~ /^allowed=/) {
                        allowed=substr($i, 9);
                    } else if ($i ~ /^sent=/) {
                        sent=substr($i, 6) + 0;
                    } else if ($i ~ /^recv=/) {
                        recv=substr($i, 6) + 0;
                    }
                }
                if (allowed == "1" && sni != "") {
                    h[sni]++;
                    b[sni] += (sent + recv);
                }
            }
            END {
                for (d in h) {
                    printf "%s|%d|%d\n", d, h[d], b[d];
                }
            }
        ' "$log_file" | sort -t'|' -k3,3nr | head -n "$limit"
    )
}

# Resumen ultraliviano por IP conectada: combina DB (alias+geo), ipset counters y ultima actividad del log
# Salida: ip|alias|geo|ipset_packets|ipset_bytes|log_hits|log_bytes|last_seen
metrics_ip_activity() {
    license_init_db
    local log_file="${JOIF_NGINX_LOG_DIR}/joif-smartdns-stream.log"

    declare -A db_alias=()
    declare -A db_geo=()
    local ip alias created expires status updated geo base_ip
    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        base_ip="${ip%%/*}"
        db_alias["$ip"]="$alias"
        db_alias["$base_ip"]="$alias"
        db_geo["$ip"]="${geo:--}"
        db_geo["$base_ip"]="${geo:--}"
    done < <(license_list_raw)

    declare -A k_pkts=()
    declare -A k_bytes=()
    if command -v "$JOIF_IPSET_BIN" >/dev/null 2>&1; then
        local m_ip m_pkts m_bytes norm_m
        while read -r m_ip _ m_pkts _ m_bytes; do
            [[ -z "$m_ip" || ! "${m_bytes:-}" =~ ^[0-9]+$ ]] && continue
            norm_m="$m_ip"
            [[ "$norm_m" != */* ]] && norm_m="${norm_m}/32"
            k_pkts["$norm_m"]="$m_pkts"
            k_bytes["$norm_m"]="$m_bytes"
            k_pkts["${norm_m%%/*}"]="$m_pkts"
            k_bytes["${norm_m%%/*}"]="$m_bytes"
        done < <("$JOIF_IPSET_BIN" list "$JOIF_IPSET_NAME" 2>/dev/null | awk '/^Members:/{f=1;next} f && $2=="packets" && $4=="bytes"{print $1, $2, $3, $4, $5}' || true)
    fi

    declare -A l_hits=()
    declare -A l_bytes=()
    declare -A l_last=()
    if [[ -f "$log_file" ]]; then
        local lip hits bytes last
        while IFS='|' read -r lip hits bytes last; do
            [[ -z "$lip" ]] && continue
            l_hits["$lip"]="$hits"
            l_bytes["$lip"]="$bytes"
            l_last["$lip"]="$last"
        done < <(
            awk '
                $1 == "127.0.0.1" { next }
                {
                    ip=$1;
                    ts=$2; gsub(/^\[/, "", ts);
                    sent=0; recv=0;
                    for (i=1; i<=NF; i++) {
                        if ($i ~ /^sent=/) sent=substr($i, 6) + 0;
                        else if ($i ~ /^recv=/) recv=substr($i, 6) + 0;
                    }
                    h[ip]++;
                    b[ip] += (sent + recv);
                    last[ip] = ts;
                }
                END {
                    for (ip in h) {
                        printf "%s|%d|%d|%s\n", ip, h[ip], b[ip], last[ip];
                    }
                }
            ' "$log_file"
        )
    fi

    while IFS='|' read -r ip alias created expires status updated geo; do
        [[ -z "$ip" ]] && continue
        base_ip="${ip%%/*}"
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$ip" \
            "$alias" \
            "${geo:--}" \
            "${k_pkts[$ip]:-${k_pkts[$base_ip]:-0}}" \
            "${k_bytes[$ip]:-${k_bytes[$base_ip]:-0}}" \
            "${l_hits[$base_ip]:-0}" \
            "${l_bytes[$base_ip]:-0}" \
            "${l_last[$base_ip]:-sin actividad}"
    done < <(license_list_raw)
}

metrics_print_report() {
    local net_info disk_ram_info
    net_info="$(metrics_net_mbps "${JOIF_NET_SAMPLE_SEC:-1}")"
    disk_ram_info="$(metrics_disk_ram)"

    local iface rx_m tx_m tot_m d_used d_total d_pct d_avail r_used r_total
    IFS='|' read -r iface rx_m tx_m tot_m <<< "$net_info"
    IFS='|' read -r d_used d_total d_pct d_avail r_used r_total <<< "$disk_ram_info"

    printf '\n%b=== Recursos y Trafico en Vivo ===%b\n' "$C_BOLD" "$C_RESET"
    printf '  Red (%s) : RX %s Mbps | TX %s Mbps | Total %b%s Mbps%b\n' \
        "$iface" "$rx_m" "$tx_m" "$C_CYAN" "$tot_m" "$C_RESET"
    printf '  Disco (/) : %s / %s (%s usado, %b%s libre%b)\n' \
        "$d_used" "$d_total" "$d_pct" "$C_GREEN" "$d_avail" "$C_RESET"
    printf '  RAM       : %s MB / %s MB\n' "$r_used" "$r_total"

    printf '\n%b=== Origen y Actividad por IP Autorizada ===%b\n' "$C_BOLD" "$C_RESET"
    printf '%b%-18s %-16s %-22s %-10s %-8s %s%b\n' \
        "$C_BOLD" "IP / CIDR" "ALIAS" "ORIGEN (GEO/ISP)" "KERNEL" "SNI" "ULTIMA CONEXION" "$C_RESET"
    printf '%s\n' "----------------------------------------------------------------------------------------------"
    local ip alias geo kp kb lh lb last any=0
    while IFS='|' read -r ip alias geo kp kb lh lb last; do
        [[ -z "$ip" ]] && continue
        any=1
        printf '%-18s %-16s %-22s %-10s %-8s %s\n' \
            "$ip" "${alias:0:15}" "${geo:0:21}" "$(joif_human_bytes "$kb")" "${lh} req" "$last"
    done < <(metrics_ip_activity)
    [[ "$any" -eq 0 ]] && echo "  (Sin IPs autorizadas)"

    printf '\n%b=== Top Dominios SNI (Log Actual) ===%b\n' "$C_BOLD" "$C_RESET"
    local dom hits bytes hbytes any_d=0
    while IFS='|' read -r dom hits bytes hbytes; do
        [[ -z "$dom" ]] && continue
        any_d=1
        printf '  %-42s %6s req   %s\n' "${dom:0:42}" "$hits" "$hbytes"
    done < <(metrics_top_domains 10)
    [[ "$any_d" -eq 0 ]] && echo "  (Sin trafico registrado en el log actual)"
    printf '\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-report}"
    shift || true
    case "$cmd" in
        report)      metrics_print_report ;;
        net)         metrics_net_mbps "${1:-1}" ;;
        disk-ram)    metrics_disk_ram ;;
        top-domains) metrics_top_domains "${1:-10}" ;;
        ip-activity) metrics_ip_activity ;;
        *)
            echo "Uso: $0 {report|net|disk-ram|top-domains|ip-activity}" >&2
            exit 1
            ;;
    esac
fi
