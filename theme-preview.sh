#!/bin/bash
#
# theme-preview.sh — mostra lo stesso output di esempio in tutti i temi, per
# confrontarli affiancati e scegliere il proprio.
#
# Uso:
#   ./theme-preview.sh                 tutti i temi
#   ./theme-preview.sh dark light      solo quelli indicati
#   ./theme-preview.sh --roles         solo la legenda dei 7 ruoli semantici
#
# Non legge log reali: usa un campione fisso, così il confronto è stabile e
# ripetibile. Per vedere il proprio output reale in un tema:
#   ./chatbot.sh --profile profiles/liquido --theme dark --query "..."
#
# Nota: i colori si vedono solo su un terminale. Sotto pipe o redirect
# l'anteprima non ha senso (le sequenze diventerebbero testo), quindi lo
# script avvisa e prosegue — così `./theme-preview.sh | less -R` resta usabile.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils-theme.sh"

ROLES_ONLY=0
declare -a WANT=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --roles) ROLES_ONLY=1; shift ;;
        -h|--help) grep "^#" "$0" | grep -v "^#!" | sed 's/^# \?//'; exit 0 ;;
        *) WANT+=("$1"); shift ;;
    esac
done

if [[ ! -t 1 ]]; then
    printf "Nota: stdout non e' un terminale, i colori appariranno come sequenze.\n\n" >&2
fi

[[ "${#WANT[@]}" -eq 0 ]] && while IFS= read -r t; do WANT+=("$t"); done < <(theme_list)

# Campione di output: una riga per ciascuno dei 7 ruoli, con il tipo di dato
# reale che ognuno rappresenta nei tool. Serve a rispondere alla domanda
# "questo tema mi fa distinguere le severità e leggere i numeri?".
_sample() {
    printf "  %s┌─%s Query: %squanti errori 500 nelle ultime 2 ore%s\n" \
        "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf "  %s│%s  %s[prod · nodo 04 · ClaimCenter · 2026-08-06 12:00→14:00]%s\n" \
        "$C_BOLD" "$C_RESET" "$C_LBL" "$C_RESET"
    printf "  %s│%s\n" "$C_BOLD" "$C_RESET"
    printf "  %sSTATUS      COUNT        %%  BAR%s\n" "$C_LBL" "$C_RESET"
    printf "  %s──────────  ─────────  ─────  ────────────────%s\n" "$C_LBL" "$C_RESET"
    printf "  %s200%s         %s174382%s  %s94.2%%%s  ████████████████\n" \
        "$C_OK" "$C_RESET" "$C_VAL" "$C_RESET" "$C_LBL" "$C_RESET"
    printf "  %s404%s         %s   971%s  %s 0.5%%%s  ██\n" \
        "$C_WARN" "$C_RESET" "$C_VAL" "$C_RESET" "$C_LBL" "$C_RESET"
    printf "  %s500%s         %s   120%s  %s 0.1%%%s  █\n" \
        "$C_CRIT" "$C_RESET" "$C_VAL" "$C_RESET" "$C_LBL" "$C_RESET"
    printf "  %s──────────  ─────────%s\n" "$C_LBL" "$C_RESET"
    printf "  Tasso errore: %s2.31%%%s   soglia %s1.00%%%s superata\n" \
        "$C_CRIT" "$C_RESET" "$C_LBL" "$C_RESET"
    printf "  %s⚠ [SKIP] gc.log non disponibile per gc_stats%s\n" "$C_WARN" "$C_RESET"
    # Riga con sfondo alternato (raggruppamento per nodo in search_all_logs)
    printf "  %s%snodo 04%s  %sprod1nssd-cc.log%s              %s447%s%s\n" \
        "$C_ROW_ALT" "$C_LBL" "$C_RESET$C_ROW_ALT" "$C_ACCENT" "$C_RESET$C_ROW_ALT" \
        "$C_VAL" "$C_RESET$C_ROW_ALT" "$C_RESET"
    printf "  nodo 12  %sprod1nsse-cc.log%s              %s 16%s\n" \
        "$C_ACCENT" "$C_RESET" "$C_VAL" "$C_RESET"
    printf "  %s→ Per dettaglio: \"cerca X nel cc.log\"%s\n" "$C_LBL" "$C_RESET"
}

_roles() {
    printf "    %sC_CRIT%s    critico: la cosa E' grave (5xx, ERROR, exception)\n" "$C_CRIT" "$C_RESET"
    printf "    %sC_WARN%s    warning: POTREBBE essere un problema (4xx, WARN, soglia)\n" "$C_WARN" "$C_RESET"
    printf "    %sC_OK%s      esito positivo confermato (2xx)\n" "$C_OK" "$C_RESET"
    printf "    %sC_VAL%s     valore numerico su cui deve cadere l'occhio\n" "$C_VAL" "$C_RESET"
    printf "    %sC_LBL%s     etichetta di contorno, non il dato\n" "$C_LBL" "$C_RESET"
    printf "    %sC_ACCENT%s  riferimento a un'entita' (log, path, metodo HTTP)\n" "$C_ACCENT" "$C_RESET"
    printf "    %s C_ROW_ALT %s sfondo righe alternate\n" "$C_ROW_ALT" "$C_RESET"
}

for t in "${WANT[@]}"; do
    theme_load "$t" 2>/dev/null
    printf "\n\033[7m %-76s \033[0m\n" "TEMA: $BOT_THEME_ACTIVE"
    if [[ "$ROLES_ONLY" -eq 1 ]]; then
        _roles
    else
        _roles
        echo ""
        _sample
    fi
done

printf "\n\033[0mPer usarne uno:\n"
printf "  ./chatbot.sh --profile profiles/liquido --theme <nome> ...\n"
printf "  oppure BOT_THEME=<nome> in profiles/<p>/system.local.conf (non deployato)\n"
printf "\nDefault del progetto: %smono%s — zero sequenze ANSI, per servizi e redirect su file.\n" \
    "\033[1m" "\033[0m"
