# Cerca un pattern testuale in un singolo log.
# Dispatch lo chiama una volta per ogni log disponibile sul nodo.
#
# Parametri:
#   -v pattern="<ERE>"     pattern da cercare (obbligatorio)
#   -v log_label="<nome>"  nome leggibile del log (es: "cc.log", "server.log")
#   -v context_n=1         righe di contesto prima/dopo il match (default 1)
#   -v max_matches=20      massimo match per file (default 20)

BEGIN {
    if (pattern == "") { print "[SKIP] pattern vuoto"; exit 1 }
    ctx  = (context_n+0 >= 0) ? context_n+0 : 1
    maxm = (max_matches+0 > 0) ? max_matches+0 : 20
    count = 0; post = 0; prev_n = 0; header = 0
}

{
    # Ring buffer pre-context
    if (ctx > 0) {
        pre[prev_n % ctx] = $0
        prev_n++
    }

    if ($0 ~ pattern && count < maxm) {
        count++

        if (!header) {
            printf "\n%s%s%s\n", BOLD, log_label, RESET
            printf "%s────────────────────────────────────────────────%s\n", DIM, RESET
            header = 1
        }

        # Pre-context
        if (ctx > 0) {
            start = prev_n - ctx - 1
            if (start < 0) start = 0
            for (i = start; i < prev_n - 1; i++) {
                if (pre[i % ctx] != "")
                    printf "  %s%s%s\n", DIM, substr(pre[i % ctx], 1, 120), RESET
            }
        }

        # Riga match — evidenzia il pattern
        hl = $0; gsub(pattern, YELLOW "&" RESET, hl)
        printf "  %s▶%s %s\n", CYAN, RESET, substr(hl, 1, 150)

        post = ctx  # attiva contatore post-context
        next
    }

    # Post-context
    if (post > 0) {
        printf "  %s%s%s\n", DIM, substr($0, 1, 120), RESET
        post--
    }
}

END {
    if (count == 0) {
        printf "__MATCHES__ %s 0\n", log_label
        exit
    }
    if (count >= maxm)
        printf "  %s... (mostrati primi %d match su questo log)%s\n", DIM, maxm, RESET
    printf "__MATCHES__ %s %d\n", log_label, count
}
