# utils-colors.awk — costanti ANSI comuni a tutti i tool.
# Caricato da dispatch.sh come secondo -f fisso (dopo utils-time.awk).
# I tool non devono definire colori autonomamente.
#
# Dal 2026-08-06 i valori NON sono più scritti qui: arrivano dal tema attivo,
# passati da dispatch.sh con `-v C_CRIT='...' -v C_WARN='...'` (vedi
# theme_awk_args in lib/utils-theme.sh). Questo file li mappa sulle costanti
# storiche, così i 13 tool esistenti continuano a funzionare senza modifiche e
# la migrazione ai nomi semantici può procedere un tool per volta.
#
# I 7 ruoli semantici — usare QUESTI nei tool nuovi o migrati, perché dicono
# PERCHÉ un elemento è colorato e non solo di che colore è:
#   C_CRIT    la cosa È grave per definizione (5xx, ERROR, exception)
#   C_WARN    POTREBBE essere un problema (4xx, WARN, oltre soglia)
#   C_OK      esito positivo confermato (2xx)
#   C_VAL     valore numerico su cui deve cadere l'occhio
#   C_LBL     etichetta di contorno, non il dato
#   C_ACCENT  riferimento a un'entità (nome di log, path, metodo HTTP)
#   C_ROW_ALT sfondo per righe alternate
#
# Il default quando i -v non sono passati (es. un tool invocato a mano fuori da
# dispatch.sh, o dai test) è NESSUN COLORE: coerente col tema mono, che è il
# default del progetto. Un tool eseguito direttamente non deve inventarsi una
# palette.

BEGIN {
    # Costanti storiche mappate sui ruoli semantici del tema. La
    # corrispondenza riflette l'uso prevalente nei tool attuali:
    #   RED    → critico (5xx, ERROR) nella maggioranza dei casi
    #   YELLOW → warning e soglie superate
    #   GREEN  → esito positivo
    #   CYAN   → riferimento a entità (path, metodo POST)
    #   WHT    → valore numerico
    #   DIM    → etichetta di contorno
    # Nei tool dove RED indicava "soglia superata" anziché "errore" la resa
    # resta identica finché C_CRIT e C_WARN non divergono nel tema: sarà la
    # migrazione ai nomi semantici a correggere anche quella semantica.
    RED    = C_CRIT
    YELLOW = C_WARN
    GREEN  = C_OK
    CYAN   = C_ACCENT
    WHT    = C_VAL
    DIM    = C_LBL
    BOLD   = C_BOLD
    RESET  = C_RESET
}
