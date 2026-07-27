# utils-time.awk — funzioni di conversione timestamp e filtro temporale.
# Incluso con -f utils-time.awk da tutti i tool che supportano time_from/time_to.
#
# Parametri ricevuti via -v:
#   time_from="YYYY-MM-DDTHH:MM"   (vuoto = nessun limite inferiore)
#   time_to="YYYY-MM-DDTHH:MM"     (vuoto = nessun limite superiore)
#
# Funzioni esposte:
#   parse_iso(s)      → epoch seconds da "YYYY-MM-DDTHH:MM"
#   parse_access(s)   → epoch seconds da "[DD/Mon/YYYY:HH:MM:SS"
#   parse_server(s)   → epoch seconds da "YYYY-MM-DD HH:MM:SS,mmm"
#   parse_gc(s)       → epoch seconds da "[YYYY-MM-DDTHH:MM:SS"
#   in_range(epoch)   → 1 se epoch è nel range [ts_from, ts_to], 0 altrimenti

BEGIN {
    MONTHS["Jan"]=1; MONTHS["Feb"]=2;  MONTHS["Mar"]=3;  MONTHS["Apr"]=4
    MONTHS["May"]=5; MONTHS["Jun"]=6;  MONTHS["Jul"]=7;  MONTHS["Aug"]=8
    MONTHS["Sep"]=9; MONTHS["Oct"]=10; MONTHS["Nov"]=11; MONTHS["Dec"]=12

    ts_from = (time_from != "") ? parse_iso(time_from) : 0
    ts_to   = (time_to   != "") ? parse_iso(time_to)   : 99999999999
}

# "YYYY-MM-DDTHH:MM" oppure "YYYY-MM-DDTHH:MM:SS"
function parse_iso(s,    parts, dp, tp) {
    if (split(s, parts, "T") < 2) return 0
    split(parts[1], dp, "-")
    split(parts[2], tp, ":")
    return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " (tp[3]+0))
}

# "[DD/Mon/YYYY:HH:MM:SS" (access log Undertow)
function parse_access(s,    clean, parts, dp) {
    gsub(/[\[\]]/, "", s)
    # "27/Jul/2026:09:20:00"
    if (split(s, parts, ":") < 4) return 0
    split(parts[1], dp, "/")
    return mktime(dp[3] " " MONTHS[dp[2]] " " dp[1]+0 " " parts[2] " " parts[3] " " parts[4]+0)
}

# "YYYY-MM-DD HH:MM:SS,mmm" (server.log)
function parse_server(date_s, time_s,    dp, tp) {
    split(date_s, dp, "-")
    split(time_s, tp, ":")
    return mktime(dp[1] " " dp[2] " " dp[3] " " tp[1] " " tp[2] " " int(tp[3]))
}

# "[YYYY-MM-DDTHH:MM:SS" (gc.log)
function parse_gc(s) {
    gsub(/[\[\]]/, "", s)
    sub(/\+.*/, "", s)   # rimuove timezone "+0200"
    return parse_iso(s)
}

function in_range(epoch) {
    if (time_from == "" && time_to == "") return 1
    return (epoch >= ts_from && epoch <= ts_to)
}
