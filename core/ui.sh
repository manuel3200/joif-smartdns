#!/usr/bin/env bash
# core/ui.sh — Utilidades de interfaz CLI compacta (<=74 cols, UTF-8 / ASCII automatico, Ctrl+C seguro)

[[ -n "${JOIF_UI_LOADED:-}" ]] && return 0
JOIF_UI_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=core/common.sh
source "${SCRIPT_DIR}/common.sh"

JOIF_UI_WIDTH="${JOIF_UI_WIDTH:-74}"

# Detecta soporte UTF-8 de la terminal para evitar bordes rotos en clientes SSH antiguos o VNC
ui_init_charset() {
    local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    if [[ "${JOIF_UI_ASCII:-0}" != "1" && "${loc^^}" == *"UTF-8"* || "${JOIF_UI_ASCII:-0}" != "1" && "${loc^^}" == *"UTF8"* ]]; then
        UI_TL='┌'
        UI_TR='┐'
        UI_BL='└'
        UI_BR='┘'
        UI_ML='├'
        UI_MR='┤'
        UI_H='─'
        UI_V='│'
        UI_DOT_ON='●'
        UI_DOT_OFF='○'
        UI_ARROW='▸'
    else
        UI_TL='+'
        UI_TR='+'
        UI_BL='+'
        UI_BR='+'
        UI_ML='+'
        UI_MR='+'
        UI_H='-'
        UI_V='|'
        UI_DOT_ON='*'
        UI_DOT_OFF='o'
        UI_ARROW='>'
    fi
}

ui_init_charset

ui_repeat_char() {
    local ch="$1"
    local count="$2"
    local out="" i
    for (( i = 0; i < count; i++ )); do
        out+="$ch"
    done
    printf '%s' "$out"
}

ui_box_top() {
    local inner=$(( JOIF_UI_WIDTH - 2 ))
    printf '%b%s%s%s%b\n' "$C_CYAN" "$UI_TL" "$(ui_repeat_char "$UI_H" "$inner")" "$UI_TR" "$C_RESET"
}

ui_box_sep() {
    local inner=$(( JOIF_UI_WIDTH - 2 ))
    printf '%b%s%s%s%b\n' "$C_CYAN" "$UI_ML" "$(ui_repeat_char "$UI_H" "$inner")" "$UI_MR" "$C_RESET"
}

ui_box_bottom() {
    local inner=$(( JOIF_UI_WIDTH - 2 ))
    printf '%b%s%s%s%b\n' "$C_CYAN" "$UI_BL" "$(ui_repeat_char "$UI_H" "$inner")" "$UI_BR" "$C_RESET"
}

# Imprime linea de texto plano dentro de la caja (recorta si supera el ancho para no romper celular)
ui_box_row() {
    local text="${1:-}"
    local max_len=$(( JOIF_UI_WIDTH - 4 ))
    if (( ${#text} > max_len )); then
        text="${text:0:$((max_len - 3))}..."
    fi
    local pad=$(( max_len - ${#text} ))
    printf '%b%s%b %s%*s %b%s%b\n' "$C_CYAN" "$UI_V" "$C_RESET" "$text" "$pad" "" "$C_CYAN" "$UI_V" "$C_RESET"
}

ui_box_title() {
    local text="${1:-}"
    local max_len=$(( JOIF_UI_WIDTH - 4 ))
    if (( ${#text} > max_len )); then
        text="${text:0:$max_len}"
    fi
    local pad=$(( max_len - ${#text} ))
    printf '%b%s%b %b%s%b%*s %b%s%b\n' \
        "$C_CYAN" "$UI_V" "$C_RESET" "$C_BOLD" "$text" "$C_RESET" "$pad" "" "$C_CYAN" "$UI_V" "$C_RESET"
}

ui_section_header() {
    local title="${1:-}"
    local anchor="${2:-}"
    printf '\n'
    ui_box_top
    ui_box_title "$title"
    ui_box_bottom
    if [[ -n "$anchor" ]]; then
        printf '  %bGuia:%b\n  %s#%s\n' "$C_DIM" "$C_RESET" "$JOIF_DOCS_URL" "$anchor"
    fi
    printf '\n'
}

ui_badge() {
    local label="$1"
    local active="$2"
    if [[ "$active" == "1" || "$active" == "ON" || "$active" == "activa" ]]; then
        printf '%s %b[%s ON]%b' "$label" "$C_GREEN" "$UI_DOT_ON" "$C_RESET"
    else
        printf '%s %b[%s OFF]%b' "$label" "$C_RED" "$UI_DOT_OFF" "$C_RESET"
    fi
}

ui_pause() {
    printf '\n'
    read -r -p "Presiona Enter para continuar..." _ || true
}

# Ejecuta un comando interactivo/streaming atrapando Ctrl+C para volver suavemente al menu
ui_run_interruptible() {
    local rc=0
    (
        trap 'printf "\n[INFO] Vista detenida. Volviendo al menu...\n"; exit 0' INT
        "$@"
    ) || rc=$?
    return 0
}
