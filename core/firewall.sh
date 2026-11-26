#!/usr/bin/env bash
# core/firewall.sh — Gestion segura de ipset (con counters) + iptables (NUNCA toca SSH puerto 22)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/licenses.sh
source "${SCRIPT_DIR}/licenses.sh"

# Unicos puertos filtrados por joif-smartdns (SSH 22/tcp JAMAS se toca ni se modifica)
JOIF_MANAGED_PORTS=("udp:53" "tcp:53" "tcp:80" "tcp:443")

# Verifica si el ipset existente tiene habilitada la extension 'counters'
_firewall_ipset_has_counters() {
    local header
    header="$("$JOIF_IPSET_BIN" list -t "$JOIF_IPSET_NAME" 2>/dev/null || true)"
    [[ -z "$header" ]] && return 2   # no existe aun
    if printf '%s\n' "$header" | grep -q 'counters'; then
        return 0
    fi
    return 1
}

# Migracion sin cortes de un ipset v1.0 (sin counters) a v1.1 (con counters)
_firewall_migrate_ipset_to_counters() {
    local tmp_set="${JOIF_IPSET_NAME}_mig"
    log_info "Migrando ipset '${JOIF_IPSET_NAME}' a modo 'counters' sin cortar trafico..."

    "$JOIF_IPSET_BIN" create "$tmp_set" hash:net family inet maxelem 65536 counters -exist
    "$JOIF_IPSET_BIN" flush "$tmp_set"

    local ip_cidr
    while IFS= read -r ip_cidr; do
        [[ -z "$ip_cidr" ]] && continue
        "$JOIF_IPSET_BIN" add "$tmp_set" "$ip_cidr" -exist
    done < <(license_active_ips)

    local had_chain=0
    if command -v "$JOIF_IPTABLES_BIN" >/dev/null 2>&1 && "$JOIF_IPTABLES_BIN" -L "$JOIF_IPTABLES_CHAIN" -n >/dev/null 2>&1; then
        had_chain=1
        # 1) Insertar regla temporal con _mig para mantener trafico activo durante el recambio
        "$JOIF_IPTABLES_BIN" -I "$JOIF_IPTABLES_CHAIN" 1 -m set --match-set "$tmp_set" src -j ACCEPT 2>/dev/null || true
        # 2) Quitar referencia al set viejo (sin counters)
        while "$JOIF_IPTABLES_BIN" -D "$JOIF_IPTABLES_CHAIN" -m set --match-set "$JOIF_IPSET_NAME" src -j ACCEPT 2>/dev/null; do
            :
        done
    fi

    # 3) Destruir set viejo y crear el definitivo con counters
    "$JOIF_IPSET_BIN" destroy "$JOIF_IPSET_NAME" 2>/dev/null || true
    "$JOIF_IPSET_BIN" create "$JOIF_IPSET_NAME" hash:net family inet maxelem 65536 counters -exist
    "$JOIF_IPSET_BIN" swap "$tmp_set" "$JOIF_IPSET_NAME"

    if [[ "$had_chain" -eq 1 ]]; then
        # 4) Restaurar regla apuntando al set definitivo y retirar la temporal
        "$JOIF_IPTABLES_BIN" -I "$JOIF_IPTABLES_CHAIN" 3 -m set --match-set "$JOIF_IPSET_NAME" src -j ACCEPT 2>/dev/null || \
            "$JOIF_IPTABLES_BIN" -I "$JOIF_IPTABLES_CHAIN" 1 -m set --match-set "$JOIF_IPSET_NAME" src -j ACCEPT 2>/dev/null || true
        while "$JOIF_IPTABLES_BIN" -D "$JOIF_IPTABLES_CHAIN" -m set --match-set "$tmp_set" src -j ACCEPT 2>/dev/null; do
            :
        done
    fi

    "$JOIF_IPSET_BIN" destroy "$tmp_set" 2>/dev/null || true
    log_ok "Migracion de ipset '${JOIF_IPSET_NAME}' a 'counters' completada."
}

# Sincroniza atomicamente licenses.db -> ipset joif_smartdns_allow (preservando contadores y cero downtime)
firewall_sync_ipset() {
    joif_ensure_dirs
    if ! command -v "$JOIF_IPSET_BIN" >/dev/null 2>&1; then
        log_error "Binario '${JOIF_IPSET_BIN}' no encontrado. Instala el paquete 'ipset'."
        return 1
    fi

    local state=0
    _firewall_ipset_has_counters || state=$?
    if [[ "$state" -eq 1 ]]; then
        _firewall_migrate_ipset_to_counters
    elif [[ "$state" -eq 2 ]]; then
        "$JOIF_IPSET_BIN" create "$JOIF_IPSET_NAME" hash:net family inet maxelem 65536 counters -exist
    fi

    # Preservar contadores existentes (packets/bytes) antes del swap atomico
    declare -A prev_pkts=()
    declare -A prev_bytes=()
    local m_ip m_pkts m_bytes norm_m
    while read -r m_ip m_pkts m_bytes; do
        [[ -z "$m_ip" ]] && continue
        norm_m="$m_ip"
        [[ "$norm_m" != */* ]] && norm_m="${norm_m}/32"
        prev_pkts["$norm_m"]="$m_pkts"
        prev_bytes["$norm_m"]="$m_bytes"
    done < <("$JOIF_IPSET_BIN" save "$JOIF_IPSET_NAME" 2>/dev/null | awk '$1=="add" && $4=="packets" && $6=="bytes"{print $3, $5, $7}' || true)

    local tmp_set="${JOIF_IPSET_NAME}_tmp"
    "$JOIF_IPSET_BIN" destroy "$tmp_set" 2>/dev/null || true
    "$JOIF_IPSET_BIN" create "$tmp_set" hash:net family inet maxelem 65536 counters -exist
    "$JOIF_IPSET_BIN" flush "$tmp_set"

    local count=0 ip_cidr p b
    while IFS= read -r ip_cidr; do
        [[ -z "$ip_cidr" ]] && continue
        p="${prev_pkts[$ip_cidr]:-}"
        b="${prev_bytes[$ip_cidr]:-}"
        if [[ -n "$p" && -n "$b" ]]; then
            "$JOIF_IPSET_BIN" add "$tmp_set" "$ip_cidr" packets "$p" bytes "$b" -exist
        else
            "$JOIF_IPSET_BIN" add "$tmp_set" "$ip_cidr" -exist
        fi
        count=$((count + 1))
    done < <(license_active_ips)

    "$JOIF_IPSET_BIN" swap "$tmp_set" "$JOIF_IPSET_NAME"
    "$JOIF_IPSET_BIN" destroy "$tmp_set" 2>/dev/null || true

    # Guardar snapshot liviano para auditoria
    local save_tmp
    save_tmp="$(mktemp "${JOIF_STATE_DIR}/.ipset.XXXXXX")"
    if "$JOIF_IPSET_BIN" save "$JOIF_IPSET_NAME" > "$save_tmp" 2>/dev/null; then
        chmod 640 "$save_tmp"
        mv -f "$save_tmp" "$JOIF_IPSET_SAVE_FILE"
    else
        rm -f "$save_tmp"
    fi

    log_ok "ipset '${JOIF_IPSET_NAME}' sincronizado atomicamente (${count} IP/CIDR activas)."
}

# Aplica cadena dedicada JOIF_SMARTDNS unicamente en puertos 53/udp, 53/tcp, 80/tcp, 443/tcp
# NUNCA toca politica por defecto de INPUT ni el puerto SSH (22/tcp).
firewall_apply() {
    if ! command -v "$JOIF_IPTABLES_BIN" >/dev/null 2>&1; then
        log_error "Binario '${JOIF_IPTABLES_BIN}' no encontrado. Instala el paquete 'iptables'."
        return 1
    fi

    # 1. Asegurar ipset poblado (con counters) antes de referenciarlo desde iptables
    firewall_sync_ipset

    # 2. Crear y reconstruir unicamente nuestra cadena dedicada
    "$JOIF_IPTABLES_BIN" -N "$JOIF_IPTABLES_CHAIN" 2>/dev/null || true
    "$JOIF_IPTABLES_BIN" -F "$JOIF_IPTABLES_CHAIN"

    "$JOIF_IPTABLES_BIN" -A "$JOIF_IPTABLES_CHAIN" -i lo -j ACCEPT
    "$JOIF_IPTABLES_BIN" -A "$JOIF_IPTABLES_CHAIN" -s 127.0.0.1/32 -j ACCEPT
    "$JOIF_IPTABLES_BIN" -A "$JOIF_IPTABLES_CHAIN" -m set --match-set "$JOIF_IPSET_NAME" src -j ACCEPT
    "$JOIF_IPTABLES_BIN" -A "$JOIF_IPTABLES_CHAIN" -j DROP

    # 3. Enlazar desde INPUT solo para los 4 puertos del servicio (idempotente)
    local spec proto port
    for spec in "${JOIF_MANAGED_PORTS[@]}"; do
        proto="${spec%%:*}"
        port="${spec#*:}"
        if ! "$JOIF_IPTABLES_BIN" -C INPUT -p "$proto" --dport "$port" -j "$JOIF_IPTABLES_CHAIN" 2>/dev/null; then
            "$JOIF_IPTABLES_BIN" -I INPUT 1 -p "$proto" --dport "$port" -j "$JOIF_IPTABLES_CHAIN"
        fi
    done

    # 4. Sellar IPv6 en puertos 53/80/443 si ip6tables esta activo (evita DNS abierto en IPv6)
    if command -v "$JOIF_IP6TABLES_BIN" >/dev/null 2>&1 && "$JOIF_IP6TABLES_BIN" -L INPUT -n >/dev/null 2>&1; then
        "$JOIF_IP6TABLES_BIN" -N "$JOIF_IP6TABLES_CHAIN" 2>/dev/null || true
        "$JOIF_IP6TABLES_BIN" -F "$JOIF_IP6TABLES_CHAIN"
        "$JOIF_IP6TABLES_BIN" -A "$JOIF_IP6TABLES_CHAIN" -i lo -j ACCEPT
        "$JOIF_IP6TABLES_BIN" -A "$JOIF_IP6TABLES_CHAIN" -s ::1/128 -j ACCEPT
        "$JOIF_IP6TABLES_BIN" -A "$JOIF_IP6TABLES_CHAIN" -j DROP

        for spec in "${JOIF_MANAGED_PORTS[@]}"; do
            proto="${spec%%:*}"
            port="${spec#*:}"
            if ! "$JOIF_IP6TABLES_BIN" -C INPUT -p "$proto" --dport "$port" -j "$JOIF_IP6TABLES_CHAIN" 2>/dev/null; then
                "$JOIF_IP6TABLES_BIN" -I INPUT 1 -p "$proto" --dport "$port" -j "$JOIF_IP6TABLES_CHAIN"
            fi
        done
    fi

    log_ok "Firewall aplicado en puertos 53/udp, 53/tcp, 80/tcp y 443/tcp (SSH 22 intacto)."
}

# Restauracion al arranque (via joif-smartdns-firewall.service): expira vencidas y aplica reglas
firewall_restore() {
    JOIF_AUTO_SYNC_FIREWALL=0 license_expire_overdue >/dev/null || true
    firewall_apply
}

# Limpieza segura (usada por uninstall.sh): elimina SOLO nuestras cadenas e ipset, nunca toca SSH
firewall_teardown() {
    local spec proto port
    if command -v "$JOIF_IPTABLES_BIN" >/dev/null 2>&1; then
        for spec in "${JOIF_MANAGED_PORTS[@]}"; do
            proto="${spec%%:*}"
            port="${spec#*:}"
            while "$JOIF_IPTABLES_BIN" -D INPUT -p "$proto" --dport "$port" -j "$JOIF_IPTABLES_CHAIN" 2>/dev/null; do
                :
            done
        done
        "$JOIF_IPTABLES_BIN" -F "$JOIF_IPTABLES_CHAIN" 2>/dev/null || true
        "$JOIF_IPTABLES_BIN" -X "$JOIF_IPTABLES_CHAIN" 2>/dev/null || true
    fi

    if command -v "$JOIF_IP6TABLES_BIN" >/dev/null 2>&1; then
        for spec in "${JOIF_MANAGED_PORTS[@]}"; do
            proto="${spec%%:*}"
            port="${spec#*:}"
            while "$JOIF_IP6TABLES_BIN" -D INPUT -p "$proto" --dport "$port" -j "$JOIF_IP6TABLES_CHAIN" 2>/dev/null; do
                :
            done
        done
        "$JOIF_IP6TABLES_BIN" -F "$JOIF_IP6TABLES_CHAIN" 2>/dev/null || true
        "$JOIF_IP6TABLES_BIN" -X "$JOIF_IP6TABLES_CHAIN" 2>/dev/null || true
    fi

    if command -v "$JOIF_IPSET_BIN" >/dev/null 2>&1; then
        "$JOIF_IPSET_BIN" destroy "$JOIF_IPSET_NAME" 2>/dev/null || true
        "$JOIF_IPSET_BIN" destroy "${JOIF_IPSET_NAME}_tmp" 2>/dev/null || true
        "$JOIF_IPSET_BIN" destroy "${JOIF_IPSET_NAME}_mig" 2>/dev/null || true
    fi

    log_ok "Reglas de firewall joif-smartdns eliminadas limpiamente (SSH 22 intacto)."
}

firewall_status() {
    printf '=== ipset (%s) ===\n' "$JOIF_IPSET_NAME"
    if command -v "$JOIF_IPSET_BIN" >/dev/null 2>&1; then
        "$JOIF_IPSET_BIN" list "$JOIF_IPSET_NAME" 2>/dev/null || echo "(ipset no creado)"
    else
        echo "(ipset no instalado)"
    fi
    printf '\n=== iptables (%s) ===\n' "$JOIF_IPTABLES_CHAIN"
    if command -v "$JOIF_IPTABLES_BIN" >/dev/null 2>&1; then
        "$JOIF_IPTABLES_BIN" -L "$JOIF_IPTABLES_CHAIN" -n -v 2>/dev/null || echo "(cadena no creada)"
    else
        echo "(iptables no instalado)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    cmd="${1:-status}"
    shift || true
    case "$cmd" in
        sync-ipset) joif_with_lock firewall_sync_ipset ;;
        apply)      joif_with_lock firewall_apply ;;
        restore)    joif_with_lock firewall_restore ;;
        teardown)   joif_with_lock firewall_teardown ;;
        status)     firewall_status ;;
        *)
            echo "Uso: $0 {sync-ipset|apply|restore|teardown|status}" >&2
            exit 1
            ;;
    esac
fi
