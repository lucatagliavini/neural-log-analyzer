# utils-dedup.awk — aggregazione e deduplicazione messaggi di log.
#
# Espone tre funzioni:
#   dedup_add(dk, level, msg, ts, extra)
#       Aggiunge o aggiorna una voce dedup identificata dalla chiave dk.
#       extra: stringa libera (es. logger, thread) — mostrata come riga dimmed.
#
#   dedup_sort()
#       Ordina _dedup_order[] per conteggio crescente (rari prima, frequenti dopo).
#       Modifica le variabili globali _dedup_order[]/n in-place.
#
#   dedup_print(max_rows, color_fn)
#       Stampa le voci ordinate. color_fn è ignorato (gawk non ha functor):
#       il colore viene determinato dal campo level (ERROR→RED, WARN→YELLOW).
#       Ritorna il numero di righe stampate.
#
# Variabili globali usate (prefisso _dup_ per evitare collisioni):
#   _dup_n           numero di chiavi distinte
#   _dup_order[i]    chiave all'i-esima posizione ordinata
#   _dup_cnt[dk]     occorrenze
#   _dup_level[dk]   livello (ERROR|WARN|INFO|...)
#   _dup_msg[dk]     messaggio (può contenere \n per frame stack)
#   _dup_ts[dk]      timestamp ultima occorrenza
#   _dup_extra[dk]   campo extra (logger, thread, ...)

function dedup_add(dk, level, msg, ts, extra) {
    if (!(dk in _dup_cnt)) {
        _dup_order[++_dup_n] = dk
        _dup_level[dk] = level
        _dup_msg[dk]   = msg
        _dup_extra[dk] = extra
    }
    _dup_cnt[dk]++
    _dup_ts[dk]    = ts
}

function dedup_sort(    i, j, tk, tv) {
    for (i = 2; i <= _dup_n; i++) {
        tk = _dup_order[i]; tv = _dup_cnt[tk]; j = i - 1
        while (j >= 1 && _dup_cnt[_dup_order[j]] > tv) {
            _dup_order[j+1] = _dup_order[j]; j--
        }
        _dup_order[j+1] = tk
    }
}

function dedup_print(max_rows,    i, dk, rl, cnt, color, rst, cnt_str, n_lines, msg_lines, li, printed) {
    printed = 0
    for (i = 1; i <= _dup_n && printed < max_rows; i++) {
        dk    = _dup_order[i]
        rl    = _dup_level[dk]
        cnt   = _dup_cnt[dk]
        color = (rl == "ERROR") ? RED : (rl == "WARN") ? YELLOW : (rl == "INFO") ? WHT : ""
        rst   = (color != "") ? RESET : ""
        cnt_str = (cnt > 1) ? sprintf(" (×%d)", cnt) : ""

        n_lines = split(_dup_msg[dk], msg_lines, "\n")
        printf "%s[%s] %-5s%s  %s%s\n", color, _dup_ts[dk], rl, rst, substr(msg_lines[1], 1, 120), cnt_str
        for (li = 2; li <= n_lines; li++)
            printf "  %s\n", msg_lines[li]
        if (_dup_extra[dk] != "")
            printf "  %s%s%s\n", DIM, _dup_extra[dk], RESET
        printf "\n"
        printed++
    }
    return printed
}
