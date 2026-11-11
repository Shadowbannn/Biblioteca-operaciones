#!/bin/bash
# Prepara el registro de movimientos que escribe la aplicación (se ejecuta una vez).
B=/home/thony/Biblioteca
D=/var/log/biblioteca
LOG=$D/movimientos.log
sudo -v || exit 1
sudo install -d -o www-data -g biblioteca-dev -m 2750 "$D" || exit 1
if ! sudo test -e "$LOG"; then
    sudo install -o www-data -g biblioteca-dev -m 640 /dev/null "$LOG" || exit 1
fi
if sudo test -s "$LOG"; then
    echo "El registro ya tiene contenido: no se siembra el histórico."
else
    sudo tee -a "$LOG" < "$B/datos/movimientos.log" > /dev/null || exit 1
    echo "Histórico inicial copiado desde datos/movimientos.log"
fi
echo "--- resultado ---"
sudo ls -ld "$D" "$LOG"
sudo wc -l "$LOG"
if sudo -u www-data test -w "$LOG"; then echo "www-data puede escribir en el registro"; else echo "ERROR: www-data NO puede escribir"; fi
