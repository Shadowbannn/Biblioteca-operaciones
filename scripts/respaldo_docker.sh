#!/bin/bash
# respaldo_docker.sh - Respaldo completo de BiblioTech en contenedores (versión 3)
#
# Crea en respaldos/ un archivo respaldo-docker_FECHA.tar.gz que contiene:
#   bd/            volcado SQL tomado dentro del contenedor de la base de datos
#   uploads/       fotos y portadas (volumen "uploads")
#   movimientos/   registro de movimientos de la aplicación (volumen "movimientos")
#   codigo/, datos/, docs/, scripts/, Dockerfile, docker-compose.yml, .env.example
#   MANIFIESTO.txt fecha, filas por tabla y archivos: sirve para verificar la restauración
# NO incluye .env: el respaldo no contiene contraseñas. Al restaurar en otro
# equipo se crea un .env nuevo a partir de .env.example.
# Junto al archivo deja un .sha256. Conserva solamente los últimos CONSERVAR.
#
# Uso:     ./scripts/respaldo_docker.sh
# Salida:  0 si todo salió bien, 1 si hubo un error (queda registrado en el log)

set -o pipefail
umask 027

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
DESTINO="$BASE/respaldos"
LOG="$BASE/logs/respaldo_docker.log"
BASE_DATOS="biblioteca2"
TABLAS="libros socios usuarios prestamos juegos proyectos"
CONSERVAR=7
FECHA="$(date +%Y-%m-%d_%H-%M-%S)"
ARCHIVO="respaldo-docker_$FECHA.tar.gz"
TMP=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; echo "$*"; }
fallo() { log "ERROR: $*"; exit 1; }
limpiar() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap limpiar EXIT

# Ejecuta mariadb dentro del contenedor "db" con la clave del propio contenedor
# (la contraseña no pasa por la línea de comandos del equipo anfitrión).
sql_db() { docker compose exec -T db sh -c 'exec mariadb -N -uroot -p"$MARIADB_ROOT_PASSWORD" "$@"' sh "$@" < /dev/null; }

mkdir -p "$BASE/logs"
touch "$LOG" && chmod 640 "$LOG" || { echo "No se puede escribir en $LOG"; exit 1; }

# --- 1. Comprobaciones previas ---
command -v docker > /dev/null || fallo "docker no está instalado"
[ -f "$BASE/docker-compose.yml" ] || fallo "No existe $BASE/docker-compose.yml"
[ -r "$BASE/.env" ] || fallo "No se puede leer $BASE/.env"
[ -d "$DESTINO" ] || fallo "No existe la carpeta $DESTINO"
[ -w "$DESTINO" ] || fallo "No se puede escribir en $DESTINO"
cd "$BASE" || fallo "No se pudo entrar a $BASE"

EN_MARCHA="$(docker compose ps --status running --services 2> /dev/null < /dev/null)"
for servicio in db app; do
    echo "$EN_MARCHA" | grep -qx "$servicio" || fallo "El servicio '$servicio' no está en ejecución (iniciar con: docker compose up -d)"
done

TMP="$(mktemp -d -p "$DESTINO" .tmp.XXXXXX)" || fallo "No se pudo crear la carpeta temporal"
mkdir "$TMP/bd"
log "Inicio del respaldo $ARCHIVO"

# --- 2. Volcado de la base de datos (dentro del contenedor) ---
SQL="$TMP/bd/$BASE_DATOS.sql"
sql_db --skip-column-names -e "SELECT 1" > /dev/null || fallo "No se pudo conectar a la base de datos"
docker compose exec -T db sh -c 'exec mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction --routines --triggers --events --default-character-set=utf8mb4 "$1"' sh "$BASE_DATOS" \
    < /dev/null > "$SQL" || fallo "Falló el volcado de la base de datos"
[ -s "$SQL" ] || fallo "El volcado de la base de datos quedó vacío"
tail -n 3 "$SQL" | grep -q 'Dump completed' || fallo "El volcado está incompleto (no termina con 'Dump completed')"

# --- 3. Archivos de los volúmenes ---
docker compose exec -T app tar -c -C /var/www/html/carpeta2 uploads < /dev/null | tar -x -C "$TMP" \
    || fallo "No se pudieron copiar las fotos y portadas (uploads)"
[ -d "$TMP/uploads" ] || fallo "La copia de uploads quedó vacía"
docker compose exec -T app tar -c -C /var/log biblioteca < /dev/null | tar -x -C "$TMP" \
    || fallo "No se pudo copiar el registro de movimientos"
mv "$TMP/biblioteca" "$TMP/movimientos" || fallo "No se pudo preparar la copia de movimientos"

# --- 4. Manifiesto (para comprobar la restauración) ---
{
    echo "respaldo=$ARCHIVO"
    echo "fecha=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "base_datos=$BASE_DATOS"
    for t in $TABLAS; do
        n="$(sql_db -e "SELECT COUNT(*) FROM $BASE_DATOS.$t")" || exit 1
        echo "filas.$t=$n"
    done
    echo "uploads_archivos=$(find "$TMP/uploads" -type f | wc -l)"
    echo "movimientos_lineas=$(cat "$TMP/movimientos/movimientos.log" 2> /dev/null | wc -l)"
} > "$TMP/MANIFIESTO.txt" || fallo "No se pudo armar el manifiesto (¿falta alguna tabla?)"

# --- 5. Empaquetar y comprimir ---
tar -czf "$TMP/$ARCHIVO" \
    --exclude='.git' --exclude='codigo/uploads' --exclude='codigo/BD' \
    -C "$BASE" codigo datos docs scripts Dockerfile docker-compose.yml .env.example .dockerignore \
    -C "$TMP" bd uploads movimientos MANIFIESTO.txt
RC=$?
[ "$RC" -le 1 ] || fallo "tar falló (código $RC)"
[ "$RC" -eq 0 ] || log "AVISO: algunos archivos cambiaron mientras se respaldaban"

# --- 6. Verificar el archivo antes de guardarlo ---
gzip -t "$TMP/$ARCHIVO" || fallo "El archivo comprimido está dañado"
tar -tzf "$TMP/$ARCHIVO" > "$TMP/lista.txt" || fallo "No se puede leer el contenido del archivo"
for esperado in "bd/$BASE_DATOS.sql" "MANIFIESTO.txt" "docker-compose.yml"; do
    grep -qx "$esperado" "$TMP/lista.txt" || fallo "Al respaldo le falta $esperado"
done
grep -q '^uploads/' "$TMP/lista.txt" || fallo "Al respaldo le faltan los uploads"
if tar -tzf "$TMP/$ARCHIVO" | grep -qE '(^|/)\.env$'; then fallo "El respaldo contiene un .env (no debe llevar contraseñas)"; fi

mv "$TMP/$ARCHIVO" "$DESTINO/$ARCHIVO" || fallo "No se pudo mover el respaldo a $DESTINO"
chmod 640 "$DESTINO/$ARCHIVO"
(cd "$DESTINO" && sha256sum "$ARCHIVO" > "$ARCHIVO.sha256") || fallo "No se pudo calcular el sha256"
chmod 640 "$DESTINO/$ARCHIVO.sha256"

TAM="$(du -h "$DESTINO/$ARCHIVO" | cut -f1)"
HASH="$(cut -c1-12 "$DESTINO/$ARCHIVO.sha256")"
log "ÉXITO: Respaldo creado ($ARCHIVO, $TAM, sha256 $HASH...)"

# --- 7. Rotación: conservar solo los últimos CONSERVAR ---
ls -1t "$DESTINO"/respaldo-docker_*.tar.gz 2> /dev/null | tail -n +$((CONSERVAR + 1)) | while read -r viejo; do
    rm -f "$viejo" "$viejo.sha256"
    log "Respaldo antiguo eliminado: $(basename "$viejo")"
done

exit 0
