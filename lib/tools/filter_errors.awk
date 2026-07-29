# Filtra righe ERROR e WARN dal server.log JBoss/WildFly/WebSphere.
# Parametri: -v time_from="YYYY-MM-DDTHH:MM"  -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato: YYYY-MM-DD HH:MM:SS,mmm LEVEL [classe] (thread) messaggio
#
# Gestisce stack trace multiriga: ogni frame "at ..." viene riconosciuto come
# continuazione dell'eccezione precedente, non come errore distinto.
# Mostra: messaggio eccezione + prime 3 righe at + "... N frame omessi"

BEGIN {
    FS = " "; max_rows = 50
    RED = "\033[31m"; YELLOW = "\033[33m"; RESET = "\033[0m"
    DIM = "\033[2m"
    in_exc = 0; exc_frames = 0; exc_omitted = 0
}

function parse_jboss(    cap) {
    # Estrae level e msg direttamente da $0 con regex — immune a thread con spazi.
    # Formato: YYYY-MM-DD HH:MM:SS,mmm LEVEL [logger] (thread) messaggio
    # Il thread può contenere spazi (es. "webcontainer-worker task-7049")
    # quindi si usa la prima ")" dopo "(" come delimitatore del campo thread.
    if (!match($0, /^[0-9-]+ [0-9:,]+ (ERROR|WARN) /, cap)) return 0
    _level = cap[1]
    # Avanza oltre "LEVEL [logger] (thread) " — trova la ")" del thread
    rest = substr($0, RSTART + RLENGTH)       # "[logger] (thread) msg..."
    if (match(rest, /^[^\)]+\) /)) {
        _msg = substr(rest, RSTART + RLENGTH)
    } else {
        _msg = rest
    }
    return 1
}

function is_frame(msg) {
    sub(/^\t/, "", msg)
    return (msg ~ /^at [a-zA-Z$\[_]/ || msg ~ /^Caused by:/ || msg ~ /^\.\.\. [0-9]+ more$/)
}

function flush_exception(    dk) {
    if (!in_exc) return
    if (exc_level == "ERROR") nerror++
    else nwarn++
    count++

    # Aggrega frame nel messaggio: prime 3 righe + "... N omessi"
    full_msg = exc_msg
    for (f = 1; f <= exc_frame_n && f <= 3; f++)
        full_msg = full_msg "\n    " exc_frame[f]
    if (exc_omitted > 0)
        full_msg = full_msg "\n    " DIM "... (" exc_omitted " frame omessi)" RESET

    dk = exc_level SUBSEP substr(exc_msg, 1, 80)
    if (!(dk in dedup_cnt)) {
        dedup_order[++dedup_n] = dk
        dedup_level[dk]  = exc_level
        dedup_msg[dk]    = full_msg
        dedup_ts[dk]     = exc_ts
        dedup_log[dk]    = exc_log
    }
    dedup_cnt[dk]++
    dedup_ts[dk] = exc_ts
    dedup_log[dk] = exc_log

    in_exc = 0; exc_frame_n = 0; exc_omitted = 0
    delete exc_frame
}

/ERROR|WARN/ {
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next
    if (!parse_jboss()) next
    level  = _level
    msg    = _msg
    logger = $4; gsub(/[\[\]]/, "", logger)

    if (is_frame(msg)) {
        # Riga di continuazione stack trace
        if (in_exc) {
            exc_frame_n++
            if (exc_frame_n <= 3)
                exc_frame[exc_frame_n] = substr(msg, 1, 100)
            else
                exc_omitted++
        }
        # Frame orfano (senza eccezione aperta): ignorato
        next
    }

    if (msg == "") next

    # Nuova riga non-frame: chiude eventuale eccezione precedente
    flush_exception()

    # Apre nuovo gruppo eccezione
    in_exc     = 1
    exc_level  = level
    exc_msg    = msg
    exc_ts     = $1 " " $2
    exc_log    = logger
    exc_frame_n = 0; exc_omitted = 0
}

END {
    flush_exception()

    if (count == 0) {
        print "Nessun errore o warning trovato nel server log."
        exit
    }

    # Ordina: rari (cnt=1) prima, frequenti alla fine
    for (i = 2; i <= dedup_n; i++) {
        tk = dedup_order[i]; tv = dedup_cnt[tk]; j = i-1
        while (j >= 1 && dedup_cnt[dedup_order[j]] > tv) {
            dedup_order[j+1] = dedup_order[j]; j--
        }
        dedup_order[j+1] = tk
    }

    printed = 0
    for (i = 1; i <= dedup_n && printed < max_rows; i++) {
        dk    = dedup_order[i]
        rl    = dedup_level[dk]
        cnt   = dedup_cnt[dk]
        color = (rl == "ERROR") ? RED : YELLOW
        cnt_str = (cnt > 1) ? sprintf(" (×%d)", cnt) : ""
        # Prima riga del messaggio (può contenere \n per i frame)
        n_lines = split(dedup_msg[dk], msg_lines, "\n")
        printf "%s[%s] %-5s%s  %s%s\n", color, dedup_ts[dk], rl, RESET, substr(msg_lines[1], 1, 120), cnt_str
        for (li = 2; li <= n_lines; li++)
            printf "  %s\n", msg_lines[li]
        printf "  %s%s%s\n\n", DIM, dedup_log[dk], RESET
        printed++
    }

    if (dedup_n > max_rows) printf "... (mostrati %d di %d errori distinti)\n", max_rows, dedup_n
    printf "Totale: %s%d ERROR%s, %s%d WARN%s (%d distinti)\n", \
        RED, nerror+0, RESET, YELLOW, nwarn+0, RESET, dedup_n
}
