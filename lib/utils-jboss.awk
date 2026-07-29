# utils-jboss.awk — parsing del formato log JBoss/WildFly.
#
# Espone l'API generica usata dai tool:
#   parse_server_log()   → popola _level, _msg, _ts, _logger; restituisce 1 se match
#   is_stack_frame(msg)  → 1 se la riga è un frame di stack trace
#
# Formato JBoss: YYYY-MM-DD HH:MM:SS,mmm LEVEL [logger] (thread) messaggio
# Il campo (thread) può contenere spazi (es. "webcontainer-worker task-7049"),
# per cui si usa regex su $0 grezzo invece di field splitting posizionale.
#
# Per aggiungere un formato alternativo (WebSphere, Tomcat, ecc.) creare un
# utils-websphere.awk (o altro) che implementa le stesse funzioni parse_server_log()
# e is_stack_frame(), e selezionarlo via SERVER_LOG_FORMAT in domain.conf /
# dispatch.sh con: -f "$LIB_DIR/utils-${SERVER_LOG_FORMAT:-jboss}.awk"

function parse_server_log(    cap, rest) {
    if (!match($0, /^([0-9-]+) ([0-9:,]+) (ERROR|WARN|INFO) /, cap)) return 0
    _level   = cap[3]
    _ts_date = cap[1]
    _ts_time = cap[2]
    _ts      = cap[1] " " cap[2]
    rest     = substr($0, RSTART + RLENGTH)
    # rest = "[logger] (thread) messaggio"
    # salta [logger]
    if (match(rest, /^\[[^\]]*\] /)) rest = substr(rest, RSTART + RLENGTH)
    # salta (thread con eventuali spazi)
    if (match(rest, /^[^\)]+\) /))  rest = substr(rest, RSTART + RLENGTH)
    _msg    = rest
    # _logger: primo campo [classe] della riga originale
    _logger = $4; gsub(/[\[\]]/, "", _logger)
    return 1
}

function is_stack_frame(msg) {
    sub(/^\t/, "", msg)
    return (msg ~ /^at [a-zA-Z$\[_]/ || msg ~ /^Caused by:/ || msg ~ /^\.\.\. [0-9]+ more$/)
}
