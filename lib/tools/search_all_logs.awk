# search_all_logs.awk — conta le occorrenze di un pattern in un singolo file
# di log e calcola primo/ultimo match, rispettando il filtro temporale.
#
# Parametri (-v):
#   pat   pattern ERE case-insensitive (stesso valore che prima andava a grep -iE)
#   tf    limite inferiore "YYYY-MM-DD HH:MM:SS" (vuoto = nessun limite)
#   tt    limite superiore "YYYY-MM-DD HH:MM:SS" (vuoto = nessun limite)
#
# Il timestamp è tracciato riga per riga su TUTTO il file (non solo sulle righe
# che matchano): una riga senza timestamp proprio (continuazione di stack
# trace) eredita quello dell'ultima riga con timestamp vista. Senza questa
# eredità un frame "at ..." che matcha il pattern per puro caso testuale
# (es. "SearchHubExtApi" contiene "searchHub") sopravviveva sempre al filtro
# temporale anche quando l'eccezione a cui appartiene è fuori range — bug
# reale (2026-08-05): un'unica passata su tutte le righe è necessaria perché
# solo scandendo il file per intero si sa qual è il timestamp "corrente" nel
# punto in cui si trova la riga di stack trace.
#
# Output: "hits|first_ts|last_ts" su stdout.
#
# Dipende da: nessuna utility esterna (non usa utils-time.awk: qui il
# confronto è per stringa "YYYY-MM-DD HH:MM:SS", non per epoch, per restare
# coerente col resto di search_all_logs.sh che opera sulla stessa rappresentazione).

BEGIN {
    IGNORECASE = 1
    MONTHS["Jan"]="01"; MONTHS["Feb"]="02"; MONTHS["Mar"]="03"; MONTHS["Apr"]="04"
    MONTHS["May"]="05"; MONTHS["Jun"]="06"; MONTHS["Jul"]="07"; MONTHS["Aug"]="08"
    MONTHS["Sep"]="09"; MONTHS["Oct"]="10"; MONTHS["Nov"]="11"; MONTHS["Dec"]="12"
    do_filter = (tf != "" || tt != "")
    hits = 0; first_ts = ""; last_ts = ""
}

{
    ts = ""
    if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        ts = substr($0, RSTART, RLENGTH)
        gsub(/T/, " ", ts)
    } else if (match($0, /\[[0-9]{2}\/[A-Za-z]{3}\/[0-9]{4}:[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        raw = substr($0, RSTART + 1, RLENGTH - 1)
        split(raw, p, "/")
        mnum = MONTHS[p[2]]
        if (mnum != "") {
            split(p[3], q, ":")
            ts = q[1] "-" mnum "-" p[1] " " q[2] ":" q[3] ":" q[4]
        }
    }
    if (ts != "") last_seen_ts = ts
    eff_ts = (ts != "") ? ts : last_seen_ts

    if ($0 !~ pat) next

    if (do_filter && eff_ts != "") {
        if (tf != "" && eff_ts < tf) next
        if (tt != "" && eff_ts > tt) next
    }

    hits++
    if (eff_ts != "") {
        if (first_ts == "") first_ts = eff_ts
        last_ts = eff_ts
    }
}

END {
    printf "%d|%s|%s\n", hits, first_ts, last_ts
}
