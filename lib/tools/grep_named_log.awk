# Filtra un log Guidewire per livello (ERROR/WARN/INFO) e/o pattern testuale.
# A differenza di tail_named_log, non restituisce le ultime N righe ma le righe
# che corrispondono ai criteri di filtro (utile per trovare errori nel cc.log, ecc.)
#
# Parametri:
#   -v level="ERROR"        livello da filtrare (ERROR|WARN|INFO|"" per tutti)
#   -v pattern=""           pattern ERE aggiuntivo (vuoto = nessun filtro pattern)
#   -v tail_n=50            massimo righe di output
#   -v time_from="YYYY-MM-DDTHH:MM"
#   -v time_to="YYYY-MM-DDTHH:MM"
#
# Formato atteso: YYYY-MM-DD HH:MM:SS,mmm LEVEL [classe] (thread) messaggio

BEGIN {
    FS = " "
    max_rows = (tail_n+0 > 0) ? tail_n+0 : 50
    if (level == "") level = "ERROR"
    count = 0; shown = 0
}

/^[0-9]{4}-[0-9]{2}-[0-9]{2}/ {
    # Filtro temporale
    if ((time_from != "" || time_to != "") && !in_range(parse_server($1, $2))) next

    # Filtro per livello
    row_level = $3
    if (level != "ALL" && row_level != level) next

    # Filtro pattern aggiuntivo
    if (pattern != "" && $0 !~ pattern) next

    count++

    if (shown < max_rows) {
        shown++
        logger = $4; gsub(/[\[\]]/, "", logger)
        msg = ""
        for (i = 6; i <= NF; i++) msg = msg " " $i
        sub(/^ /, "", msg)
        printf "[%s %s] %-5s  %-35s  %s\n",
            $1, $2, row_level, substr(logger, 1, 35), substr(msg, 1, 72)
    }
}

END {
    if (count == 0) {
        printf "Nessuna riga trovata"
        if (level != "ALL") printf " (level=%s)", level
        if (pattern != "")  printf " (pattern=%s)", pattern
        print "."
    } else {
        if (count > shown) printf "... (mostrate %d di %d)\n", shown, count
        printf "Totale: %d righe\n", count
    }
}
