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
#   C_ACCENT  riferimento a un'entità (nome di log, path)
#   C_INFO    livello NEUTRO di una scala di severità (status 3xx: né ok né errore)
#   C_TAG     codifica per CATEGORIA, non per gravità (metodo HTTP, contatori)
#   C_ROW_ALT sfondo per righe alternate
#
# La distinzione C_INFO/C_TAG da C_ACCENT è emersa migrando i tool (UI-12): il
# ciano era usato per tre cose diverse — il nome di un log (accento), lo status
# 3xx (livello intermedio di una scala), e il metodo POST (categoria). Mapparle
# tutte su C_ACCENT avrebbe fatto sì che un tema con accento giallo (dark-warm)
# rendesse POST indistinguibile da un warning.
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
    # Fallback: un tema che non definisce i due ruoli nuovi ricade su C_ACCENT,
    # cioè il comportamento pre-UI-12 — nessun tema si rompe.
    if (C_INFO == "") C_INFO = C_ACCENT
    if (C_TAG  == "") C_TAG  = C_ACCENT

    RED    = C_CRIT
    YELLOW = C_WARN
    GREEN  = C_OK
    CYAN   = C_ACCENT
    WHT    = C_VAL
    DIM    = C_LBL
    BOLD   = C_BOLD
    RESET  = C_RESET
}

# bar_color(v, max) — colore della barra per il valore v su un massimo max.
# Unica fonte di verità per tutti i tool che disegnano barre (principio 2):
# prima search_all_logs usava verde/giallo/rosso per intensità e count_status
# nessun colore.
#
# La scala è SEQUENZIALE (cinque livelli della stessa tonalità) e non
# divergente (verde/giallo/rosso): una barra rappresenta una QUANTITÀ, e la
# quantità non è un giudizio — 400 occorrenze possono essere gravi o normali
# secondo il contesto. Il giudizio resta sul colore dello status, così i due
# piani non competono per lo stesso significato.
#
# La TONALITÀ la scegli il tema (C_BAR_1..5), perché deve accordarsi con la sua
# palette: rossi nei temi caldi, ciano in dark-cool (che evita rosso/verde per
# la discromatopsia), colori base a piena intensità in high-contrast.
#
# Soglie ai quinti del massimo. Se il tema non definisce la scala tutti i
# livelli sono vuoti e la barra esce nel colore di default, come prima.
function bar_color(v, max,    r) {
    if (max <= 0) return C_BAR_1
    r = v / max
    if (r >= 0.8) return C_BAR_5
    if (r >= 0.6) return C_BAR_4
    if (r >= 0.4) return C_BAR_3
    if (r >= 0.2) return C_BAR_2
    return C_BAR_1
}
