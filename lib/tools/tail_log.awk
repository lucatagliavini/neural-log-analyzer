# Mostra le ultime N righe del log (implementazione tail in AWK).
# Parametri: -v tail_n="50"

BEGIN { if (tail_n == "" || tail_n+0 <= 0) tail_n = 50; n = tail_n+0; head = 0; count = 0 }

{
    buf[count % n] = $0
    count++
}

END {
    start = (count >= n) ? count - n : 0
    for (i = start; i < count; i++)
        print buf[i % n]
    printf "\n── Ultimi %d di %d righe totali ──\n", (count < n ? count : n), count
}
