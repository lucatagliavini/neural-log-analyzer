# Filtra righe ERROR e WARN dal server.log JBoss/WildFly/WebSphere.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Gestisce stack trace multiriga: ogni frame "at ..." viene riconosciuto come
# continuazione dell'eccezione precedente, non come errore distinto.
# Mostra: messaggio eccezione + prime 3 righe at + "... N frame omessi"
#
# Dipende da: utils-colors.awk, utils-jboss.awk (o formato alternativo),
#             utils-dedup.awk, utils-time.awk

BEGIN {
    FS = " "; max_rows = 50
    in_exc = 0; exc_omitted = 0
}

function norm_key(msg,    k) {
    # Rimuove "Exception in thread \"...\": " per fare collassare istanze dello stesso errore
    # lanciate da thread diversi (pattern JBoss/stderr).
    k = msg
    sub(/^Exception in thread "[^"]*" /, "", k)
    # substr nudo, NON ellipsize(): questo valore è una CHIAVE di deduplicazione,
    # mai stampato. Il taglio è il meccanismo che fa collassare istanze dello
    # stesso errore, e un "…" la allungherebbe senza cambiare cosa raggruppa
    # (TRUNC-1: la distinzione chiave/display è il punto della voce).
    return substr(k, 1, 80)
}

function flush_exception(    dk, full_msg, f) {
    if (!in_exc) return
    # logline_count_level() invece di `if ERROR … else nwarn++` (LVLCNT-1): la
    # classificazione binaria attribuiva ai WARN qualsiasi livello diverso da ERROR,
    # e con il selettore per sottostringa di sotto ci finivano righe INFO. Ora la
    # regola è una sola, condivisa con tail_log e tail_named_log.
    logline_count_level(exc_level)
    count++

    full_msg = exc_msg
    for (f = 1; f <= exc_frame_n && f <= 3; f++)
        full_msg = full_msg "\n    " exc_frame[f]
    if (exc_omitted > 0)
        full_msg = full_msg "\n    " C_LBL "... (" exc_omitted " frame omessi)" C_RESET

    dk = exc_level SUBSEP norm_key(exc_msg)
    dedup_add(dk, exc_level, full_msg, exc_ts, exc_log)

    in_exc = 0; exc_frame_n = 0; exc_omitted = 0
    delete exc_frame
}

# Selettore ANCORATO alla posizione del livello, non una sottostringa (LVLCNT-1).
#
# Qui c'era `/ERROR|WARN/`, che matcha in qualsiasi punto della riga — e in italiano
# il plurale di «errore» è «ERRORI», che CONTIENE «ERROR». Misurato sul nodo 4 di
# produzione: 44 righe `INFO [stdout] [(1) ERRORI AGENZIA - …]` entravano nel filtro,
# venivano contate come WARN (vedi flush_exception) e STAMPATE in un report
# intitolato «Righe ERROR/WARN dal server.log». Il totale dichiarava 46 WARN dove
# nella finestra ce n'erano 2.
#
# La forma ancorata `^data ora LIVELLO ` non può confondere un contenuto con un
# livello, ed è la stessa che parse_server_log() (utils-jboss.awk) usa per
# riconoscere la riga: il pre-filtro e il parser ora concordano invece di divergere.
#
# Verificato sui log reali che nessuna riga necessaria venga scartata: i frame di
# stack trace sono record JBoss completi col proprio livello ERROR (32 righe su 32
# ben formate), quindi l'ancora li conserva tutti — è il raggruppamento sotto
# l'eccezione a dipendere da loro, e continua a funzionare.
/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:,]+ +(ERROR|WARN) / {
    if (!parse_server_log()) next
    if ((time_from != "" || time_to != "") && !in_range(parse_server(_ts_date, _ts_time))) next
    level = _level
    msg   = _msg

    if (is_stack_frame(msg)) {
        if (in_exc) {
            sub(/^\t/, "", msg)
            exc_frame_n++
            if (exc_frame_n <= 3)
                # I frame vengono stampati (righe 2..n del messaggio in
                # dedup_print, non troncate là), quindi QUESTO è il limite di
                # display effettivo: il taglio va dichiarato — TRUNC-1.
                exc_frame[exc_frame_n] = ellipsize(msg, 100)
            else
                exc_omitted++
        }
        next
    }

    if (msg == "") next

    flush_exception()

    in_exc      = 1
    exc_level   = level
    exc_msg     = msg
    exc_ts      = _ts
    exc_log     = _logger
    exc_frame_n = 0; exc_omitted = 0
}

END {
    flush_exception()

    if (count == 0) {
        print "Nessun errore o warning trovato nel server log."
        exit
    }

    dedup_sort()
    dedup_print(max_rows)

    if (_dup_n > max_rows) printf "... (mostrati %d di %d errori distinti)\n", max_rows, _dup_n
    printf "Totale: %s%d ERROR%s, %s%d WARN%s (%d distinti)\n", \
        C_CRIT, nerror+0, C_RESET, C_WARN, nwarn+0, C_RESET, _dup_n
}
