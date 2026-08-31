# utils-scope.awk — riga di sintesi per nodo per il motore multi-nodo
# (SCOPE-1 passo 4, dispatch_tool_multinode in lib/dispatch.sh).
#
# Settimo -f caricato da common_f (dispatch.sh), DOPO utils-time.awk — usa
# access_ts_ok(), definita là — e PRIMA del .awk del tool. Stesso principio del
# precedente in produzione, utils-time.awk:174 (ats_debug_file): gawk esegue i
# blocchi END nell'ordine dei -f, quindi un END condiviso qui gira SEMPRE prima
# dell'exit del tool nel ramo "zero risultati" (12 tool su 14 hanno un exit lì).
#
# Gated da scope_summary_file: vuoto ⇒ non fa nulla. Il percorso single-node e
# i test esistenti (che invocano i tool senza questo -f) restano invariati.
# Scrive SEMPRE su file, mai su stdout — che è il canale su cui asseriscono i
# test (principio 3 di CLAUDE.md).
#
# I tool incrementano `_scope_n` con un semplice `++`, mai una chiamata a
# funzione: una variabile inutilizzata è inerte, una funzione mancante è
# fatale — un tool invocato senza questo -f (come fanno 4 test che costruiscono
# a mano la propria lista di -f) non deve andare in errore.
#
# tsbad (`!access_ts_ok()`) è un segnale GREZZO, non un'interpretazione: vale
# solo per i tool che leggono l'access log con filtro temporale. Un tool che
# non chiama mai access_ts() (es. filter_errors, che parsa il server log) ha
# _ats_field sempre 0 e quindi access_ts_ok()=0 SEMPRE — non perché il formato
# sia inatteso, ma perché quel tool non usa quella funzione. La decisione se
# mostrare il marcatore `~` sta nel chiamante (dispatch.sh), che sa da
# TOOL_SOURCES se il tool in questione legge davvero l'access log — non qui.
END {
    if (scope_summary_file != "") {
        printf "%s|%d|%d|%d\n", scope_node, _scope_n + 0, NR + 0, \
               (access_ts_ok() ? 0 : 1) >> scope_summary_file
    }
}
