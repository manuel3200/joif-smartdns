#!/usr/bin/env bash
# core/updater.sh — Actualizador seguro desde GitHub (sin requerir .git en /opt/joif-smartdns)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=core/domains.sh
source "${SCRIPT_DIR}/domains.sh"
# shellcheck source=core/maintenance.sh
source "${SCRIPT_DIR}/maintenance.sh"

# Instala un archivo reemplazando el inodo atomicamente (mv -f) para no corromper scripts en ejecucion
_updater_install_file() {
    local src="$1"
    local dst="$2"
    local mode="${3:-644}"
    mkdir -p "$(dirname "$dst")"
    local tmp
    tmp="$(mktemp "$(dirname "$dst")/.upd.XXXXXX")"
    cp -f "$src" "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dst"
}

# Deduplica lineas repetidas de dominio (preservando comentarios) y mezcla dominios nuevos sin pipes grep -q
_updater_merge_list_file() {
    local upstream_file="$1"
    local target_file="$2"

    declare -A seen=()
    local tmp line norm
    tmp="$(mktemp "$(dirname "$target_file")/.listmerge.XXXXXX")"

    # 1) Conservar archivo actual eliminando duplicados exactos (repara duplicados previos si existian)
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        if norm="$(joif_normalize_domain "$line" 2>/dev/null)"; then
            if [[ -n "${seen[$norm]:-}" ]]; then
                continue
            fi
            seen["$norm"]=1
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$target_file"

    # 2) Agregar solo dominios nuevos presentes en upstream
    local added=0 dom
    while IFS= read -r dom; do
        [[ -z "$dom" ]] && continue
        if [[ -z "${seen[$dom]:-}" ]]; then
            seen["$dom"]=1
            printf '%s\n' "$dom" >> "$tmp"
            added=$((added + 1))
        fi
    done < <(domains_parse_file "$upstream_file" 2>/dev/null)

    chmod 644 "$tmp"
    mv -f "$tmp" "$target_file"
    printf '%s\n' "$added"
}

_updater_fetch_source() {
    local dest_dir="$1"
    local local_src="${2:-}"

    if [[ -n "$local_src" ]]; then
        if [[ ! -d "$local_src" ]]; then
            log_error "Directorio origen no encontrado: '${local_src}'"
            return 1
        fi
        cp -a "${local_src}/." "$dest_dir/"
        return 0
    fi

    if command -v git >/dev/null 2>&1; then
        if git clone --depth 1 --quiet "$JOIF_REPO_URL" "$dest_dir" 2>/dev/null; then
            return 0
        fi
        log_warn "git clone fallo; intentando descarga directa por tarball..."
    fi

    if command -v curl >/dev/null 2>&1; then
        local tar_url="${JOIF_REPO_URL%.git}/archive/refs/heads/main.tar.gz"
        local tar_tmp
        tar_tmp="$(mktemp)"
        if curl -4 -fsSL --connect-timeout 5 --max-time 30 "$tar_url" -o "$tar_tmp"; then
            tar -xzf "$tar_tmp" --strip-components=1 -C "$dest_dir"
            rm -f "$tar_tmp"
            return 0
        fi
        rm -f "$tar_tmp"
    fi

    log_error "No se pudo descargar la actualizacion desde ${JOIF_REPO_URL}."
    return 1
}

_updater_validate_source() {
    local src_dir="$1"
    local req
    for req in "install.sh" "menu.sh" "uninstall.sh" "core/common.sh" "core/domains.sh" "core/dnsmasq_gen.sh" "core/nginx_gen.sh" "core/licenses.sh" "core/firewall.sh"; do
        if [[ ! -f "${src_dir}/${req}" ]]; then
            log_error "Actualizacion incompleta: falta '${req}'."
            return 1
        fi
    done

    local shf
    while IFS= read -r shf; do
        if ! bash -n "$shf"; then
            log_error "Error de sintaxis en archivo descargado: ${shf}"
            return 1
        fi
    done < <(find "$src_dir" -maxdepth 3 -type f -name '*.sh')
    return 0
}

updater_run() {
    local merge_lists=1
    local local_src=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-lists)   merge_lists=0; shift ;;
            --source-dir) local_src="${2:-}"; shift 2 ;;
            *)            shift ;;
        esac
    done

    joif_ensure_dirs
    local work_dir
    work_dir="$(mktemp -d)"

    log_info "Descargando ultima version de joif-smartdns..."
    if ! _updater_fetch_source "$work_dir" "$local_src"; then
        rm -rf "$work_dir"
        return 1
    fi

    log_info "Validando integridad y sintaxis de los archivos descargados..."
    if ! _updater_validate_source "$work_dir"; then
        rm -rf "$work_dir"
        return 1
    fi

    local new_ver
    new_ver="$(sed -nE 's/^JOIF_VERSION="([^"]+)"/\1/p' "${work_dir}/core/common.sh" | head -n1)"
    log_info "Version actual: v${JOIF_VERSION} -> Version descargada: v${new_ver:-desconocida}"

    # Backup automatico de seguridad antes de actualizar (~3 KB)
    maintenance_backup >/dev/null || true

    # Desplegar scripts actualizados con reemplazo atomico de inodo (nunca corrompe menu.sh en ejecucion)
    mkdir -p "${JOIF_INSTALL_DIR}/core" "${JOIF_INSTALL_DIR}/domains.d" "${JOIF_INSTALL_DIR}/systemd" "${JOIF_INSTALL_DIR}/tools"
    _updater_install_file "${work_dir}/install.sh"   "${JOIF_INSTALL_DIR}/install.sh"   755
    _updater_install_file "${work_dir}/uninstall.sh" "${JOIF_INSTALL_DIR}/uninstall.sh" 755
    _updater_install_file "${work_dir}/menu.sh"      "${JOIF_INSTALL_DIR}/menu.sh"      755

    local f
    shopt -s nullglob
    for f in "${work_dir}/core/"*.sh; do
        _updater_install_file "$f" "${JOIF_INSTALL_DIR}/core/$(basename "$f")" 755
    done
    for f in "${work_dir}/domains.d/"*.list; do
        _updater_install_file "$f" "${JOIF_INSTALL_DIR}/domains.d/$(basename "$f")" 644
    done
    for f in "${work_dir}/systemd/"*; do
        [[ -f "$f" ]] && _updater_install_file "$f" "${JOIF_INSTALL_DIR}/systemd/$(basename "$f")" 644
    done
    if [[ -d "${work_dir}/tools" ]]; then
        for f in "${work_dir}/tools/"*.sh; do
            _updater_install_file "$f" "${JOIF_INSTALL_DIR}/tools/$(basename "$f")" 755
        done
    fi
    shopt -u nullglob

    # Merge inteligente de listas base (respeta categorias pausadas y nunca toca 99-custom.list)
    if [[ "$merge_lists" -eq 1 ]]; then
        local src_list base slug active_path disabled_path added
        shopt -s nullglob
        for src_list in "${work_dir}/domains.d/"*.list; do
            base="$(basename "$src_list")"
            slug="${base%.list}"
            [[ "$slug" == "99-custom" ]] && continue
            active_path="${JOIF_DOMAINS_DIR}/${slug}.list"
            disabled_path="${JOIF_DOMAINS_DIR}/${slug}.list.disabled"

            if [[ -f "$active_path" ]]; then
                added="$(_updater_merge_list_file "$src_list" "$active_path")"
                (( added > 0 )) && log_ok "Lista '${slug}' actualizada (+${added} dominios nuevos)."
            elif [[ -f "$disabled_path" ]]; then
                added="$(_updater_merge_list_file "$src_list" "$disabled_path")"
                (( added > 0 )) && log_info "Lista pausada '${slug}' actualizada (+${added} dominios; se mantiene pausada)."
            else
                cp -f "$src_list" "$active_path"
                chmod 644 "$active_path"
                log_ok "Nueva categoria agregada: ${slug}"
            fi
        done
        shopt -u nullglob
    fi

    # Actualizar unidades systemd y protecciones de disco si estamos en entorno real
    if [[ "${JOIF_SKIP_SERVICE_RELOAD:-0}" != "1" ]]; then
        maintenance_install_disk_guards

        if [[ -d /etc/systemd/system ]]; then
            cp -f "${JOIF_INSTALL_DIR}/systemd/joif-smartdns-firewall.service" /etc/systemd/system/joif-smartdns-firewall.service
            cp -f "${JOIF_INSTALL_DIR}/systemd/joif-smartdns-expire.service"   /etc/systemd/system/joif-smartdns-expire.service
            cp -f "${JOIF_INSTALL_DIR}/systemd/joif-smartdns-expire.timer"     /etc/systemd/system/joif-smartdns-expire.timer
            chmod 644 /etc/systemd/system/joif-smartdns-firewall.service \
                      /etc/systemd/system/joif-smartdns-expire.service \
                      /etc/systemd/system/joif-smartdns-expire.timer
            "$JOIF_SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
        fi

        # Reaplicar dnsmasq, nginx y firewall (migra ipset a counters sin cortes)
        joif_load_config
        bash "${JOIF_INSTALL_DIR}/core/dnsmasq_gen.sh" apply "${JOIF_PUBLIC_IP:-}"
        bash "${JOIF_INSTALL_DIR}/core/nginx_gen.sh" apply
        bash "${JOIF_INSTALL_DIR}/core/firewall.sh" apply
        bash "${JOIF_INSTALL_DIR}/core/licenses.sh" refresh-geo >/dev/null 2>&1 || true
    fi

    rm -rf "$work_dir"
    log_ok "joif-smartdns actualizado correctamente a v${new_ver:-desconocida} (licencias y configuracion intactas)."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    joif_with_lock updater_run "$@"
fi
