#!/bin/bash
# Genera docs/evidencias.txt con la salida de los controles de cada objetivo.
B=/home/thony/Biblioteca
OUT=$B/docs/evidencias.txt
LOGAPP=/var/log/biblioteca/movimientos.log
sudo -v || exit 1
umask 027
sec() { echo; echo "================ $* ================"; }
{
echo "EVIDENCIAS - BiblioTech (Quantum Dev)"
echo "Generado: $(date '+%F %T') en $(hostname)"

sec "OBJ 1 - Usuarios y grupos"
id thony; id walter; id jose
getent group biblioteca-dev biblioteca-bd
echo "Miembros de sudo: $(getent group sudo | cut -d: -f4)"

sec "OBJ 2 - Permisos de archivos y carpetas"
stat -c '%A %U:%G %n' "$B" "$B"/* "$B"/scripts/* "$B"/datos/* "$B"/respaldos/*.tar.gz
stat -c '%A %U:%G %n' /var/www/biblioteca /var/www/biblioteca/uploads
sudo stat -c '%A %U:%G %n' /etc/biblioteca /etc/biblioteca/db.conf /var/log/biblioteca "$LOGAPP"
getfacl -p /home/thony 2> /dev/null | grep -E '^(user|group):'

sec "OBJ 3 - SSH"
sudo sshd -t && echo "sshd -t: configuración válida"
systemctl is-active ssh.socket
sudo sshd -T | grep -Ei '^(port|permitrootlogin|maxauthtries|logingracetime|allowgroups|permitemptypasswords|x11forwarding) '
echo "--- journalctl -u ssh (rechazos y fallos) ---"
sudo journalctl -u ssh --no-pager | grep -iE 'not allowed|invalid user|failed|refused' | tail -n 8

sec "OBJ 4 - Apache y servicios al arranque"
sudo apache2ctl configtest 2>&1
for s in apache2 mariadb cron ssh.socket; do
    printf '%-12s activo: %-9s al arranque: %s\n' "$s" "$(systemctl is-active "$s")" "$(systemctl is-enabled "$s" 2>&1)"
done
curl -s -o /dev/null -w 'inicioo.php                    -> HTTP %{http_code}\n' http://localhost/carpeta2/inicioo.php
curl -s -o /dev/null -w 'index.php?accion=listarCatalogo -> HTTP %{http_code}\n' 'http://localhost/carpeta2/index.php?accion=listarCatalogo'
curl -s -o /dev/null -w 'uploads/ (sin listado)         -> HTTP %{http_code}\n' http://localhost/carpeta2/uploads/

sec "OBJ 5 - Despliegue (desplegar.log)"
cat "$B/logs/despliegue.log"

sec "OBJ 6 - Respaldo"
tail -n 6 "$B/logs/respaldo.log"
ls -lh "$B/respaldos"
(cd "$B/respaldos" && sha256sum -c "$(ls -t ./*.sha256 | head -n 1)")

sec "OBJ 7 - Chequeo (ejecución en vivo)"
"$B/scripts/chequeo.sh"

sec "OBJ 8 y 9 - Registro que escribe la aplicación y analizador"
echo "--- registro de la aplicación ($LOGAPP) ---"
sudo ls -l "$LOGAPP"
sudo wc -l "$LOGAPP"
sudo tail -n 6 "$LOGAPP"
echo "--- datos/catalogo.csv (primeras líneas) ---"
head -n 4 "$B/datos/catalogo.csv"
echo "--- datos/movimientos.log (copia para el analizador) ---"
cat "$B/datos/movimientos.log"
echo "--- analizador resumen ---"
"$B/scripts/analizador.sh" resumen
echo "--- analizador ranking ---"
LIMITE=5 "$B/scripts/analizador.sh" ranking
echo "--- analizador alertas ---"
"$B/scripts/analizador.sh" alertas
echo "--- logs/alertas.log (ejemplos de cada tipo) ---"
wc -l "$B/logs/alertas.log"
grep -m 3 'ALERTA STOCK' "$B/logs/alertas.log"
grep -m 3 'ALERTA DORMIDO' "$B/logs/alertas.log"
grep -m 1 'INFO DORMIDOS' "$B/logs/alertas.log"
grep -m 3 'ALERTA RANKING' "$B/logs/alertas.log"

sec "OBJ 10 - Cron"
crontab -l | grep -vE '^(#|$)'
echo "--- ejecuciones registradas por el sistema ---"
sudo journalctl -u cron --no-pager | grep 'CMD (umask' | tail -n 8
echo "--- logs/cron.log (final) ---"
tail -n 4 "$B/logs/cron.log"

sec "OBJ 11 y 12 - Documentación"
ls -l "$B/docs" "$B/README.md"

echo; echo "FIN DE EVIDENCIAS"
} 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT"
echo "Listo: $OUT ($(wc -l < "$OUT") líneas)"
