#!/bin/bash
# exportar_datos.sh - Publica en datos/ los archivos que lee el analizador
#   datos/catalogo.csv     id;titulo;autor;categoria;ejemplares   (se genera desde la tabla libros)
#   datos/movimientos.log  una línea por movimiento real          (copia del registro que escribe la aplicación)
# Formato de movimientos:  2026-10-22 10:15:30 PRESTAMO libro=L09785 usuario=A022
#
# La aplicación (includes/registro_movimientos.php) agrega una línea a
# /var/log/biblioteca/movimientos.log cada vez que se registra un préstamo,
# una devolución o una reserva. Este script copia ese registro a datos/ tras
# validar su formato. Se puede cambiar el origen con la variable MOVIMIENTOS_APP.
# El catálogo se lee con el usuario de solo lectura biblioteca_respaldo (.respaldo.cnf).

set -o pipefail

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
DATOS="$BASE/datos"
CNF="$BASE/.respaldo.cnf"
LOG="$BASE/logs/exportar.log"
BASE_DATOS="biblioteca2"
ORIGEN_MOV="${MOVIMIENTOS_APP:-/var/log/biblioteca/movimientos.log}"
REGEX_MOV='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (PRESTAMO|DEVOLUCION|RESERVA) libro=[^ ]+ usuario=[^ ]+$'
TMP_CAT=""
TMP_MOV=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; echo "$*"; }
fallo() { log "ERROR: $*"; exit 1; }
limpiar() { rm -f "$TMP_CAT" "$TMP_MOV"; }
trap limpiar EXIT

touch "$LOG" && chmod 640 "$LOG" || { echo "No se puede escribir en $LOG"; exit 1; }

[ -w "$DATOS" ] || fallo "No se puede escribir en $DATOS"
[ -r "$CNF" ] || fallo "No se puede leer $CNF"
command -v mariadb > /dev/null || fallo "mariadb (cliente) no está instalado"

TMP_CAT="$(mktemp -p "$DATOS" .catalogo.XXXXXX)" || fallo "No se pudo crear un archivo temporal"
TMP_MOV="$(mktemp -p "$DATOS" .movimientos.XXXXXX)" || fallo "No se pudo crear un archivo temporal"

# --- 1. Catálogo (libros) ---
echo "id;titulo;autor;categoria;ejemplares" > "$TMP_CAT"
mariadb --defaults-extra-file="$CNF" --default-character-set=utf8mb4 -N -B -r "$BASE_DATOS" >> "$TMP_CAT" <<'SQL' || fallo "No se pudo leer la tabla libros"
SELECT CONCAT_WS(';',
    CONCAT('L', LPAD(id, 5, '0')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(titulo, ';', ','), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')),
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(autor, ';', ','), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')),
    COALESCE(NULLIF(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(genero, ';', ','), CHAR(13), ' '), CHAR(10), ' '), CHAR(9), ' ')), ''), 'Sin categoría'),
    stock)
FROM libros
ORDER BY id;
SQL
LIBROS=$(($(wc -l < "$TMP_CAT") - 1))
[ "$LIBROS" -gt 0 ] || fallo "La tabla libros no devolvió ninguna fila"

# --- 2. Movimientos (registro que escribe la aplicación) ---
[ -r "$ORIGEN_MOV" ] || fallo "No se puede leer el registro de la aplicación: $ORIGEN_MOV"
cat "$ORIGEN_MOV" > "$TMP_MOV" || fallo "No se pudo copiar $ORIGEN_MOV"
MOVS=$(wc -l < "$TMP_MOV")
INVALIDAS=$(grep -cvE "$REGEX_MOV" "$TMP_MOV")
[ "$INVALIDAS" -eq 0 ] || fallo "El registro de la aplicación tiene $INVALIDAS líneas con formato inválido"

# --- 3. Publicar (reemplazo atómico) ---
chmod 640 "$TMP_CAT" "$TMP_MOV"
mv "$TMP_CAT" "$DATOS/catalogo.csv" || fallo "No se pudo escribir catalogo.csv"
mv "$TMP_MOV" "$DATOS/movimientos.log" || fallo "No se pudo escribir movimientos.log"
TMP_CAT=""; TMP_MOV=""

RES=$(grep -c ' RESERVA ' "$DATOS/movimientos.log")
PRE=$(grep -c ' PRESTAMO ' "$DATOS/movimientos.log")
DEV=$(grep -c ' DEVOLUCION ' "$DATOS/movimientos.log")
log "ÉXITO: catalogo.csv con $LIBROS libros; movimientos.log con $MOVS movimientos (reservas: $RES, préstamos: $PRE, devoluciones: $DEV)"
exit 0
