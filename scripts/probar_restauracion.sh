#!/bin/bash
# Prueba de restauración: carga el último respaldo en una base TEMPORAL y la compara con la real.
# No modifica biblioteca2. Limpia todo lo temporal al terminar.
B=/home/thony/Biblioteca
DBT=biblioteca_restore_test
TMP=$(mktemp -d)
trap 'sudo mariadb -e "DROP DATABASE IF EXISTS $DBT" 2> /dev/null; rm -rf "$TMP"' EXIT
sudo -v || exit 1
ERR=0

ULT=$(ls -t "$B"/respaldos/*.tar.gz | head -n 1)
echo "Respaldo a probar: $ULT"
(cd "$B/respaldos" && sha256sum -c "$(basename "$ULT").sha256") || exit 1
tar -xzf "$ULT" -C "$TMP" || { echo "ERROR: no se pudo extraer"; exit 1; }

SQL=$(find "$TMP" -name biblioteca2.sql | head -n 1)
[ -n "$SQL" ] || { echo "ERROR: el respaldo no contiene biblioteca2.sql"; exit 1; }
RAIZ=$(dirname "$(dirname "$SQL")")
echo "Contenido del respaldo: $(ls "$RAIZ" | tr '\n' ' ')"
echo "Tamaño del volcado SQL: $(du -h "$SQL" | cut -f1)"

if grep -qiE '^(USE |CREATE DATABASE)' "$SQL"; then
    echo "ABORTADO: el volcado contiene USE/CREATE DATABASE y podría pisar la base real"
    exit 1
fi

sudo mariadb -e "DROP DATABASE IF EXISTS $DBT; CREATE DATABASE $DBT CHARACTER SET utf8mb4;" || exit 1
sudo mariadb "$DBT" < "$SQL" || { echo "ERROR: falló la importación"; exit 1; }
echo "Importación en $DBT: OK"

echo "Comparación (real vs restaurada):"
for t in libros socios usuarios prestamos juegos proyectos; do
    R=$(sudo mariadb -N -e "SELECT COUNT(*) FROM biblioteca2.$t")
    T=$(sudo mariadb -N -e "SELECT COUNT(*) FROM $DBT.$t")
    if [ "$R" = "$T" ]; then E="[OK]"; else E="[DIFERENTE]"; ERR=1; fi
    printf '  %-10s real=%-7s restaurada=%-7s %s\n' "$t" "$R" "$T" "$E"
done
NR=$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='biblioteca2'")
NT=$(sudo mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DBT'")
echo "  tablas     real=$NR restaurada=$NT"
[ "$NR" = "$NT" ] || ERR=1

echo
if [ "$ERR" -eq 0 ]; then echo "RESULTADO: restauración verificada correctamente"; else echo "RESULTADO: hay diferencias (si hubo cambios en la app después del respaldo, es normal)"; fi
exit "$ERR"
