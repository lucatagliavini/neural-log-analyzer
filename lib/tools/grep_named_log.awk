# Filtra un log applicativo custom per livello (ERROR/WARN/INFO) e/o pattern testuale.
#
# Parametri:
#   -v level="ERROR"        livello (ERROR|WARN|INFO|WARN+|ALL)
#   -v pattern=""           pattern ERE aggiuntivo (vuoto = nessun filtro)
#   -v tail_n=50            massimo righe di output
#   -v time_from="YYYY-MM-DDTHH:MM"
#   -v time_to="YYYY-MM-DDTHH:MM"
#   -v kind=""              "access"|"gc"|"server"|"" — passato solo da
#                           dispatch.sh sul ramo SRCH-2 (log di sistema
#                           nominato). Su access/gc il primo [...] della riga
#                           è il timestamp (consumato da logline_parse), non
#                           un thread: senza questo kind la colonna "thread"
#                           mostrerebbe la data (vedi piano, A4).
#
# Il riconoscimento di timestamp/livello è delegato a logline_parse()
# (utils-logline.awk): il formato non è un'assunzione di questo tool, è una
# proprietà del file (vedi il piano di correzione, Intervento 1/2). Una riga
# non riconosciuta non viene scartata (principio 5): resta senza livello e
# senza timestamp, quindi non passa un filtro per livello specifico ma resta
# visibile con level=ALL o un pattern testuale.
#
# Dipende da: utils-colors.awk, utils-dedup.awk, utils-time.awk, utils-logline.awk

BEGIN {
    FS = " "
    n = (tail_n+0 > 0) ? tail_n+0 : 50
    if (level == "") level = "ERROR"
    count = 0
    matched_level = 0
}

{
    row_recognized = logline_parse()

    row_ts    = _ll_ts
    row_level = _ll_level
    if (row_level != "") matched_level++
    row_msg   = row_recognized ? _ll_msg : $0
    row_epoch = _ll_epoch

    if (level == "WARN+") {
        if (row_level != "ERROR" && row_level != "WARN") next
    } else if (level != "ALL" && row_level != level) next

    if (pattern != "" && $0 !~ pattern) next

    if ((time_from != "" || time_to != "") && (row_epoch <= 0 || !in_range(row_epoch))) next

    # Il primo [...] è un thread/logger applicativo solo su named/server: su
    # access e gc è il timestamp che logline_parse ha già consumato per
    # _ll_ts/_ll_epoch (rami 1/2 di utils-logline.awk), quindi qui non c'è
    # nulla da estrarre — mostrarlo comunque duplicherebbe la data.
    thread = ""
    if (kind != "access" && kind != "gc") {
        if (match($0, /\[([^\]]+)\]/, th)) thread = th[1]
    }

    buf_ts[count % n]     = row_ts
    buf_level[count % n]  = row_level
    buf_msg[count % n]    = row_msg
    buf_thread[count % n] = thread
    count++
    _scope_n++
}

END {
    if (count == 0) {
        if (NR > 0 && matched_level == 0) {
            printf "Nessuna riga riconosciuta nel formato atteso (%d righe lette). ", NR
            printf "Il log potrebbe non avere livelli ERROR/WARN riconoscibili: prova a cercare una stringa specifica.\n"
            exit
        }
        printf "Nessuna riga trovata"
        if (level == "WARN+")    printf " (level=ERROR+WARN)"
        else if (level != "ALL") printf " (level=%s)", level
        if (pattern != "")       printf " (pattern=%s)", pattern
        print "."
        exit
    }

    shown = (count < n) ? count : n
    start = (count < n) ? 0 : (count % n)

    for (i = 0; i < shown; i++) {
        idx = (start + i) % n
        # Livello vuoto (access/gc) → nessun campo aiuta a distinguere due
        # righe: usare il messaggio troncato a 120 come su ERROR/WARN farebbe
        # collassare richieste diverse che condividono solo il prefisso.
        # Chiave sul messaggio intero: dedup solo se davvero identiche.
        key_msg = (buf_level[idx] == "") ? buf_msg[idx] : substr(buf_msg[idx], 1, 120)
        dk  = buf_level[idx] SUBSEP key_msg
        dedup_add(dk, buf_level[idx], buf_msg[idx], buf_ts[idx], buf_thread[idx])
    }

    dedup_sort()

    for (i = 1; i <= _dup_n; i++) {
        dk    = _dup_order[i]
        rl    = _dup_level[dk]
        cnt   = _dup_cnt[dk]
        color = (rl == "ERROR") ? C_CRIT : (rl == "WARN") ? C_WARN : (rl == "INFO") ? C_VAL : ""
        rst   = (color != "") ? C_RESET : ""
        # Il contatore di deduplicazione (×N) è un metadato, non un riferimento
        # a un'entità: C_TAG (UI-12).
        cnt_str = (cnt > 1) ? sprintf(" %s(×%d)%s", C_TAG, cnt, C_RESET) : ""
        printf "%s%-5s%s  %s%s%s  %s%s\n", \
            color, rl, rst, \
            C_LBL, substr(_dup_ts[dk], 1, 19), C_RESET, \
            ellipsize(_dup_msg[dk], 100), cnt_str
        if (_dup_extra[dk] != "")
            printf "       %s[%s]%s\n", C_LBL, ellipsize(_dup_extra[dk], 60), C_RESET
    }

    distinct = _dup_n
    if (count > shown)
        printf "\n... (mostrate ultime %d di %d totali, %d messaggi distinti)\n", shown, count, distinct
    else
        printf "\nTotale: %d righe, %d messaggi distinti\n", count, distinct
}
