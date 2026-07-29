# utils-colors.awk — costanti ANSI comuni a tutti i tool.
# Caricato da dispatch.sh come secondo -f fisso (dopo utils-time.awk).
# I tool non devono definire colori autonomamente.

BEGIN {
    RED    = "\033[31m"
    YELLOW = "\033[33m"
    GREEN  = "\033[32m"
    CYAN   = "\033[36m"
    BOLD   = "\033[1m"
    DIM    = "\033[2m"
    RESET  = "\033[0m"
}
