#!/usr/bin/env bash
# tools/acceso-root.sh — Habilita acceso SSH directo como root con clave (Ubuntu 22.04/24.04/26.04 y Debian)
# Seguro ante cloud-init (usa drop-in 00-joif-root.conf con prioridad maxima) y valida con sshd -t + rollback.
set -euo pipefail

# Rutas y binarios sobreescribibles para pruebas locales
JOIF_SSHD_CONF="${JOIF_SSHD_CONF:-/etc/ssh/sshd_config}"
JOIF_SSHD_DROPIN_DIR="${JOIF_SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
JOIF_SSHD_DROPIN_FILE="${JOIF_SSHD_DROPIN_FILE:-${JOIF_SSHD_DROPIN_DIR}/00-joif-root.conf}"
JOIF_SSHD_BIN="${JOIF_SSHD_BIN:-sshd}"
JOIF_CHPASSWD_BIN="${JOIF_CHPASSWD_BIN:-chpasswd}"
JOIF_PASSWD_BIN="${JOIF_PASSWD_BIN:-passwd}"
JOIF_SYSTEMCTL_BIN="${JOIF_SYSTEMCTL_BIN:-systemctl}"
JOIF_SKIP_SSH_RESTART="${JOIF_SKIP_SSH_RESTART:-0}"
JOIF_ROOT_PASSWORD_INPUT="${JOIF_ROOT_PASSWORD_INPUT:-}"
JOIF_PUBLIC_IP_OVERRIDE="${JOIF_PUBLIC_IP_OVERRIDE:-}"

# Colores ANSI
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
else
    C_RESET=''
    C_BOLD=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
fi

info() { printf '%b[INFO]%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%b[ OK ]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%b[ERR ]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }

require_root() {
    if [[ "${JOIF_ALLOW_NONROOT_TEST:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "Ejecuta este script como root (usa: sudo ./acceso-root.sh)."
        exit 1
    fi
}

detect_public_ip() {
    if [[ -n "$JOIF_PUBLIC_IP_OVERRIDE" ]]; then
        printf '%s\n' "$JOIF_PUBLIC_IP_OVERRIDE"
        return 0
    fi
    local url ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip="$(curl -4 -fsSL --connect-timeout 3 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" || true
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            printf '%s\n' "$ip"
            return 0
        fi
    done
    # Fallback a IP local principal si no hubo salida externa
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    printf '%s\n' "${ip:-NO_DETECTADA}"
}

detect_ssh_port() {
    local port=""
    if command -v "$JOIF_SSHD_BIN" >/dev/null 2>&1; then
        port="$("$JOIF_SSHD_BIN" -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
    fi
    if [[ -z "$port" && -f "$JOIF_SSHD_CONF" ]]; then
        port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' "$JOIF_SSHD_CONF" 2>/dev/null || true)"
    fi
    printf '%s\n' "${port:-22}"
}

prompt_password() {
    if [[ -n "$JOIF_ROOT_PASSWORD_INPUT" ]]; then
        ROOT_PASS="$JOIF_ROOT_PASSWORD_INPUT"
        return 0
    fi

    local tty_in="/dev/tty"
    [[ -r "$tty_in" ]] || tty_in="/dev/stdin"

    printf '\n%b=================================================%b\n' "$C_CYAN" "$C_RESET"
    printf '%b  JOIF — Habilitar Acceso SSH Root con Clave%b\n' "$C_BOLD" "$C_RESET"
    printf '%b=================================================%b\n\n' "$C_CYAN" "$C_RESET"

    local p1 p2
    while true; do
        read -r -s -p "Ingresa la nueva clave para root: " p1 < "$tty_in"
        printf '\n'
        if [[ -z "$p1" ]]; then
            warn "La clave no puede estar vacia."
            continue
        fi
        if (( ${#p1} < 6 )); then
            warn "Recomendacion: usa al menos 6 caracteres para mayor seguridad."
        fi
        read -r -s -p "Confirma la nueva clave para root: " p2 < "$tty_in"
        printf '\n'
        if [[ "$p1" != "$p2" ]]; then
            warn "Las claves no coinciden. Intenta nuevamente."
            continue
        fi
        ROOT_PASS="$p1"
        break
    done
}

configure_sshd() {
    local used_dropin=0
    local bak_dropin="" bak_main="" had_dropin=0

    # Verificar si sshd_config incluye /etc/ssh/sshd_config.d/*.conf (estandar Ubuntu 22.04/24.04/26.04)
    if [[ -f "$JOIF_SSHD_CONF" ]] && grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' "$JOIF_SSHD_CONF"; then
        used_dropin=1
        mkdir -p "$JOIF_SSHD_DROPIN_DIR"
        if [[ -f "$JOIF_SSHD_DROPIN_FILE" ]]; then
            bak_dropin="$(mktemp)"
            cp -p "$JOIF_SSHD_DROPIN_FILE" "$bak_dropin"
            had_dropin=1
        fi

        # 00-joif-root.conf se carga PRIMERO, ganando prioridad sobre 50-cloud-init.conf y 60-cloudimg-settings.conf
        cat > "$JOIF_SSHD_DROPIN_FILE" <<'EOF'
# Managed by joif-smartdns (tools/acceso-root.sh)
# Prioridad 00 para prevalecer sobre cloud-init en Ubuntu 22.04 / 24.04 / 26.04 LTS
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
EOF
        chmod 644 "$JOIF_SSHD_DROPIN_FILE"
    else
        # Fallback para sistemas sin sshd_config.d
        if [[ ! -f "$JOIF_SSHD_CONF" ]]; then
            err "No se encontro ${JOIF_SSHD_CONF}."
            exit 1
        fi
        bak_main="$(mktemp)"
        cp -p "$JOIF_SSHD_CONF" "$bak_main"

        sed -i -E \
            -e 's/^[#[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin yes/' \
            -e 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' \
            -e 's/^[#[:space:]]*KbdInteractiveAuthentication[[:space:]].*/KbdInteractiveAuthentication yes/' \
            "$JOIF_SSHD_CONF"

        grep -Eq '^[[:space:]]*PermitRootLogin[[:space:]]+' "$JOIF_SSHD_CONF" || printf '\nPermitRootLogin yes\n' >> "$JOIF_SSHD_CONF"
        grep -Eq '^[[:space:]]*PasswordAuthentication[[:space:]]+' "$JOIF_SSHD_CONF" || printf 'PasswordAuthentication yes\n' >> "$JOIF_SSHD_CONF"
    fi

    # Validar sintaxis antes de reiniciar SSH (rollback automatico si falla)
    if command -v "$JOIF_SSHD_BIN" >/dev/null 2>&1; then
        local -a test_cmd=("$JOIF_SSHD_BIN" -t)
        if [[ "$JOIF_SSHD_CONF" != "/etc/ssh/sshd_config" ]]; then
            test_cmd=("$JOIF_SSHD_BIN" -t -f "$JOIF_SSHD_CONF")
        fi

        if ! "${test_cmd[@]}" >/dev/null 2>&1; then
            err "La validacion de SSH (sshd -t) fallo. Ejecutando rollback para proteger tu acceso..."
            "${test_cmd[@]}" >&2 || true
            if [[ "$used_dropin" -eq 1 ]]; then
                if [[ "$had_dropin" -eq 1 ]]; then
                    mv -f "$bak_dropin" "$JOIF_SSHD_DROPIN_FILE"
                else
                    rm -f "$JOIF_SSHD_DROPIN_FILE"
                fi
            elif [[ -n "$bak_main" && -f "$bak_main" ]]; then
                mv -f "$bak_main" "$JOIF_SSHD_CONF"
            fi
            exit 1
        fi
    fi

    rm -f "${bak_dropin:-}" "${bak_main:-}"
    ok "Configuracion SSH validada correctamente."
}

apply_root_password() {
    printf 'root:%s\n' "$ROOT_PASS" | "$JOIF_CHPASSWD_BIN"
    if command -v "$JOIF_PASSWD_BIN" >/dev/null 2>&1; then
        "$JOIF_PASSWD_BIN" -u root >/dev/null 2>&1 || true
    fi
    ok "Clave de root actualizada y cuenta desbloqueada."
}

restart_ssh_service() {
    if [[ "$JOIF_SKIP_SSH_RESTART" == "1" ]]; then
        return 0
    fi
    if command -v "$JOIF_SYSTEMCTL_BIN" >/dev/null 2>&1; then
        if "$JOIF_SYSTEMCTL_BIN" restart ssh 2>/dev/null || "$JOIF_SYSTEMCTL_BIN" restart sshd 2>/dev/null; then
            ok "Servicio SSH reiniciado correctamente."
            return 0
        fi
    fi
    if command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
    fi
}

print_summary_card() {
    local ip port ssh_cmd
    ip="$(detect_public_ip)"
    port="$(detect_ssh_port)"
    if [[ "$port" == "22" ]]; then
        ssh_cmd="ssh root@${ip}"
    else
        ssh_cmd="ssh -p ${port} root@${ip}"
    fi

    printf '\n'
    printf '%b########################################################%b\n' "$C_CYAN" "$C_RESET"
    printf '%b#          JOIF — ACCESO ROOT HABILITADO               #%b\n' "$C_BOLD" "$C_RESET"
    printf '%b########################################################%b\n' "$C_CYAN" "$C_RESET"
    printf '  Estos son los Datos para iniciar sesion:\n\n'
    printf '  %bUsuario:%b root   %bClave:%b %s   %bIP:%b %s\n' \
        "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET" "$ROOT_PASS" "$C_GREEN" "$C_RESET" "$ip"
    printf '  %bPuerto :%b %s\n' "$C_GREEN" "$C_RESET" "$port"
    printf '  %bComando:%b %s\n' "$C_CYAN" "$C_RESET" "$ssh_cmd"
    printf '%b########################################################%b\n\n' "$C_CYAN" "$C_RESET"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        cat <<'EOF'
Uso: sudo ./acceso-root.sh

Habilita el inicio de sesion SSH como 'root' con clave en Ubuntu 22.04/24.04/26.04 y Debian,
respetando la prioridad sobre cloud-init y validando con 'sshd -t' antes de reiniciar SSH.
EOF
        exit 0
    fi

    require_root
    prompt_password
    info "Configurando OpenSSH (prioridad sobre cloud-init)..."
    configure_sshd
    apply_root_password
    restart_ssh_service
    print_summary_card
}

main "$@"
