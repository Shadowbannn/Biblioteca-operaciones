#!/bin/bash
# respaldo.sh - Respaldo completo de BiblioTech (versión 2)
# Crea en respaldos/ un archivo respaldo_FECHA.tar.gz que contiene:
#   bd/       volcado SQL de la base de datos
#   codigo/   código de la aplicación (sin .git ni uploads)
#   uploads/  archivos subidos por los usuarios (fotos y portadas en uso)
#   datos/, docs/, scripts/
# Junto al archivo deja un .sha256 para comprobar su integridad.
# Conserva solamente los últimos CONSERVAR respaldos.

set -o pipefail

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
DESTINO="$BASE/respaldos"
LOG="$BASE/logs/respaldo.log"
CNF="$BASE/.respaldo.cnf"
WEB_UPLOADS="/var/www/biblioteca/uploads"
BASE_DATOS="biblioteca2"
CONSERVAR=7
FECHA="$(date +%Y-%m-%d_%H-%M-%S)"
ARCHIVO="respaldo_$FECHA.tar.gz"
TMP=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; echo "$*"; }
fallo() { log "ERROR: $*"; exit 1; }
limpiar() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap limpiar EXIT

touch "$LOG" && chmod 640 "$LOG" || { echo "No se puede escribir en $LOG"; exit 1; }

# --- 1. Comprobaciones previas ---
[ -d "$DESTINO" ] || fallo "No existe la carpeta $DESTINO"
[ -w "$DESTINO" ] || fallo "No se puede escribir en $DESTINO"
[ -r "$CNF" ] || fallo "No se puede leer $CNF (credenciales del usuario de respaldo)"
command -v mariadb-dump > /dev/null || fallo "mariadb-dump no está instalado"
[ -d "$WEB_UPLOADS" ] || fallo "No existe $WEB_UPLOADS (¿se desplegó la aplicación?)"

TMP="$(mktemp -d -p "$DESTINO" .tmp.XXXXXX)" || fallo "No se pudo crear la carpeta temporal"
mkdir "$TMP/bd"
log "Inicio del respaldo $ARCHIVO"

# --- 2. Volcado de la base de datos ---
mariadb-dump --defaults-extra-file="$CNF" --single-transaction --no-tablespaces \
    "$BASE_DATOS" > "$TMP/bd/$BASE_DATOS.sql" || fallo "Falló el volcado de la base de datos"
[ -s "$TMP/bd/$BASE_DATOS.sql" ] || fallo "El volcado de la base de datos quedó vacío"

# --- 3. Empaquetar y comprimir ---
tar -czf "$TMP/$ARCHIVO" \
    --exclude='.git' --exclude='codigo/uploads' \
    -C "$BASE" codigo datos docs scripts \
    -C "$WEB_UPLOADS/.." uploads \
    -C "$TMP" bd
RC=$?
[ "$RC" -le 1 ] || fallo "tar falló (código $RC)"
[ "$RC" -eq 0 ] || log "AVISO: algunos archivos cambiaron mientras se respaldaban"

# --- 4. Verificar el archivo antes de guardarlo ---
gzip -t "$TMP/$ARCHIVO" || fallo "El archivo comprimido está dañado"
tar -tzf "$TMP/$ARCHIVO" > /dev/null || fallo "No se puede leer el contenido del archivo"

mv "$TMP/$ARCHIVO" "$DESTINO/$ARCHIVO" || fallo "No se pudo mover el respaldo a $DESTINO"
chmod 640 "$DESTINO/$ARCHIVO"
(cd "$DESTINO" && sha256sum "$ARCHIVO" > "$ARCHIVO.sha256") || fallo "No se pudo calcular el sha256"
chmod 640 "$DESTINO/$ARCHIVO.sha256"

TAM="$(du -h "$DESTINO/$ARCHIVO" | cut -f1)"
HASH="$(cut -c1-12 "$DESTINO/$ARCHIVO.sha256")"
log "ÉXITO: Respaldo creado ($ARCHIVO, $TAM, sha256 $HASH...)"

# --- 5. Rotación: conservar solo los últimos CONSERVAR ---
ls -1t "$DESTINO"/respaldo_*.tar.gz 2> /dev/null | tail -n +$((CONSERVAR + 1)) | while read -r viejo; do
    rm -f "$viejo" "$viejo.sha256"
    log "Respaldo antiguo eliminado: $(basename "$viejo")"
done

exit 0
