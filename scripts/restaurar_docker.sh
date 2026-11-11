#!/bin/bash
# restaurar_docker.sh - Restauración de BiblioTech desde un respaldo (versión 3)
#
# Uso:
#   ./scripts/restaurar_docker.sh --probar [respaldo.tar.gz]
#       Prueba de restauración COMPLETA en un entorno aislado y descartable: otro
#       proyecto de Docker (bibliotech_prueba), otro puerto (8081), volúmenes vacíos
#       y contraseñas nuevas. Restaura el respaldo, lo compara con su MANIFIESTO.txt,
#       prueba la web y elimina todo al terminar. No toca el sistema en funcionamiento.
#       Sin archivo indicado usa el último respaldo.
#   ./scripts/restaurar_docker.sh --produccion respaldo.tar.gz
#       Restaura sobre el sistema en funcionamiento: pide confirmación, hace antes un
#       respaldo de seguridad, reemplaza base de datos, fotos y registro de movimientos
#       y verifica el resultado.
#
# Salida: 0 si lo restaurado coincide con el respaldo, 1 si hubo un error o diferencias.

set -o pipefail
umask 027

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
DESTINO="$BASE/respaldos"
LOG="$BASE/logs/restauracion_docker.log"
BASE_DATOS="biblioteca2"
TABLAS="libros socios usuarios prestamos juegos proyectos"
PROYECTO_PRUEBA="bibliotech_prueba"
PUERTO_PRUEBA=8081
TMP=""
INICIADO=""
DC=()
ERR=0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; echo "$*"; }
fallo() { log "ERROR: $*"; exit 1; }
uso() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

limpiar() {
    # Solo se elimina el entorno de PRUEBA, nunca el sistema en funcionamiento
    if [ "$INICIADO" = "$PROYECTO_PRUEBA" ]; then
        docker compose -p "$PROYECTO_PRUEBA" down -v --remove-orphans > /dev/null 2>&1 < /dev/null
        log "Entorno de prueba '$PROYECTO_PRUEBA' eliminado (contenedores y volúmenes)"
    fi
    [ -n "$TMP" ] && rm -rf "$TMP"
}
trap limpiar EXIT

mkdir -p "$BASE/logs"
touch "$LOG" && chmod 640 "$LOG" || { echo "No se puede escribir en $LOG"; exit 1; }

# --- 1. Argumentos y comprobación del respaldo ---
MODO="${1:-}"
ARCHIVO="${2:-}"
case "$MODO" in
    --probar | --produccion) ;;
    *) uso; exit 1 ;;
esac
if [ -z "$ARCHIVO" ]; then
    [ "$MODO" = "--probar" ] || { uso; fallo "Con --produccion hay que indicar el respaldo a restaurar"; }
    ARCHIVO="$(ls -1t "$DESTINO"/respaldo-docker_*.tar.gz 2> /dev/null | head -n 1)"
fi
[ -n "$ARCHIVO" ] && [ -f "$ARCHIVO" ] || fallo "No hay un respaldo para restaurar (${ARCHIVO:-ninguno})"
ARCHIVO="$(readlink -f "$ARCHIVO")"

[ -f "$ARCHIVO.sha256" ] || fallo "Falta el archivo de suma de control $ARCHIVO.sha256"
(cd "$(dirname "$ARCHIVO")" && sha256sum -c "$(basename "$ARCHIVO").sha256" > /dev/null 2>&1) \
    || fallo "La suma SHA-256 no coincide: el respaldo está dañado o fue modificado"
gzip -t "$ARCHIVO" || fallo "El archivo comprimido está dañado"

command -v docker > /dev/null || fallo "docker no está instalado"
command -v curl > /dev/null || fallo "curl no está instalado"
command -v openssl > /dev/null || fallo "openssl no está instalado"
[ -f "$BASE/docker-compose.yml" ] || fallo "No existe $BASE/docker-compose.yml"
[ -r "$BASE/.env" ] || fallo "No se puede leer $BASE/.env"
cd "$BASE" || fallo "No se pudo entrar a $BASE"

TMP="$(mktemp -d)" || fallo "No se pudo crear la carpeta temporal"
tar -xzf "$ARCHIVO" -C "$TMP" bd uploads movimientos MANIFIESTO.txt || fallo "No se pudo extraer el respaldo"
[ -s "$TMP/bd/$BASE_DATOS.sql" ] || fallo "El respaldo no contiene bd/$BASE_DATOS.sql"
[ -s "$TMP/MANIFIESTO.txt" ] || fallo "El respaldo no contiene MANIFIESTO.txt"
mv "$TMP/movimientos" "$TMP/biblioteca" || fallo "Respaldo sin la carpeta de movimientos"

SECONDS=0

# --- 2. Preparar el destino según el modo ---
if [ "$MODO" = "--probar" ]; then
    PUERTO="$PUERTO_PRUEBA"
    ss -ltn 2> /dev/null | grep -q ":$PUERTO " && fallo "El puerto $PUERTO ya está en uso (otra prueba en curso?)"
    # Claves nuevas solo para esta prueba: demuestra que el respaldo no depende de las de producción
    export APP_PORT="$PUERTO" DB_PASSWORD="$(openssl rand -hex 16)" DB_ROOT_PASSWORD="$(openssl rand -hex 16)"
    DC=(docker compose -p "$PROYECTO_PRUEBA")
    log "PRUEBA de restauración de $(basename "$ARCHIVO") en un entorno aislado ('$PROYECTO_PRUEBA', puerto $PUERTO, claves nuevas)"
    INICIADO="$PROYECTO_PRUEBA"
    "${DC[@]}" up -d --wait --wait-timeout 180 > /dev/null 2>&1 < /dev/null \
        || fallo "No se pudo levantar el entorno de prueba"
else
    PUERTO="$(grep -E '^APP_PORT=' "$BASE/.env" | cut -d= -f2)"
    PUERTO="${PUERTO:-8080}"
    DC=(docker compose)
    echo
    echo "ATENCIÓN: se van a REEMPLAZAR la base de datos, las fotos y el registro de movimientos"
    echo "del sistema en funcionamiento por el contenido de $(basename "$ARCHIVO")"
    echo "(respaldo del $(grep -m1 '^fecha=' "$TMP/MANIFIESTO.txt" | cut -d= -f2))."
    read -r -p "Para continuar escribe RESTAURAR: " RESPUESTA
    [ "$RESPUESTA" = "RESTAURAR" ] || fallo "Restauración cancelada por el usuario"
    log "Respaldo de seguridad previo a la restauración"
    "$DIR_SCRIPT/respaldo_docker.sh" || fallo "No se pudo hacer el respaldo de seguridad previo; no se restaura nada"
    log "RESTAURACIÓN EN PRODUCCIÓN de $(basename "$ARCHIVO")"
    "${DC[@]}" stop app < /dev/null > /dev/null 2>&1 || fallo "No se pudo detener la aplicación"
fi

# Si la app está detenida (modo --produccion), se usa un contenedor temporal con los mismos volúmenes
if "${DC[@]}" ps --status running --services < /dev/null 2>/dev/null | grep -qx app; then
    EN_APP=("${DC[@]}" exec -T -u root app)
else
    EN_APP=("${DC[@]}" run --rm --no-deps -T -u root app)
fi

sql_db() { "${DC[@]}" exec -T db sh -c 'exec mariadb -N -uroot -p"$MARIADB_ROOT_PASSWORD" "$@"' sh "$@" < /dev/null; }

# --- 3. Restaurar: base de datos, fotos y movimientos ---
log "Restaurando la base de datos $BASE_DATOS..."
sql_db -e "DROP DATABASE IF EXISTS $BASE_DATOS; CREATE DATABASE $BASE_DATOS CHARACTER SET utf8mb4;" \
    || fallo "No se pudo recrear la base de datos"
"${DC[@]}" exec -T db sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$1"' sh "$BASE_DATOS" < "$TMP/bd/$BASE_DATOS.sql" \
    || fallo "Falló la importación del volcado SQL"

log "Restaurando fotos y portadas..."
tar -c -C "$TMP" uploads | "${EN_APP[@]}" sh -c '
    find /var/www/html/carpeta2/uploads -mindepth 1 -delete &&
    tar -x -C /var/www/html/carpeta2 &&
    chown -R www-data:www-data /var/www/html/carpeta2/uploads &&
    find /var/www/html/carpeta2/uploads -type d -exec chmod 2770 {} + &&
    find /var/www/html/carpeta2/uploads -type f -exec chmod 660 {} +' \
    || fallo "No se pudieron restaurar las fotos y portadas"

log "Restaurando el registro de movimientos..."
tar -c -C "$TMP" biblioteca | "${EN_APP[@]}" sh -c '
    find /var/log/biblioteca -mindepth 1 -delete &&
    tar -x -C /var/log &&
    chown -R www-data:www-data /var/log/biblioteca &&
    chmod 750 /var/log/biblioteca' \
    || fallo "No se pudo restaurar el registro de movimientos"

if [ "$MODO" = "--produccion" ]; then
    "${DC[@]}" start app < /dev/null > /dev/null 2>&1 || fallo "No se pudo volver a iniciar la aplicación"
    sleep 5
fi

# --- 4. Verificar contra el manifiesto del respaldo ---
valor() { grep -m1 "^$1=" "$TMP/MANIFIESTO.txt" | cut -d= -f2-; }
comparar() {
    local estado="[OK]"
    [ "$2" = "$3" ] || { estado="[DIFERENTE]"; ERR=1; }
    printf '  %-26s respaldo=%-8s restaurado=%-8s %s\n' "$1" "$2" "$3" "$estado"
}

echo
echo "Verificación (respaldo vs. restaurado):"
for t in $TABLAS; do
    n="$(sql_db -e "SELECT COUNT(*) FROM $BASE_DATOS.$t")" || n="error"
    comparar "tabla $t" "$(valor "filas.$t")" "$n"
done
n="$("${DC[@]}" exec -T app sh -c 'find /var/www/html/carpeta2/uploads -type f | wc -l' < /dev/null)"
comparar "archivos de uploads" "$(valor uploads_archivos)" "$n"
n="$("${DC[@]}" exec -T app sh -c 'cat /var/log/biblioteca/movimientos.log 2> /dev/null | wc -l' < /dev/null)"
comparar "líneas de movimientos" "$(valor movimientos_lineas)" "$n"

codigo="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://localhost:$PUERTO/carpeta2/inicioo.php")"
comparar "web: inicioo.php (HTTP)" "200" "$codigo"
pagina="$(curl -s -w '\n%{http_code}' --max-time 30 "http://localhost:$PUERTO/carpeta2/index.php?accion=listarCatalogo")"
codigo_cat="${pagina##*$'\n'}"
if [ "$codigo_cat" != "200" ]; then
    estado_cat="HTTP $codigo_cat"
elif echo "$pagina" | grep -qiE 'Fatal error|Error de conexi'; then
    estado_cat="con errores"
else
    estado_cat="HTTP 200 ok"
fi
comparar "web: catálogo (lee la BD)" "HTTP 200 ok" "$estado_cat"

echo
if [ "$ERR" -eq 0 ]; then
    log "ÉXITO: restauración verificada ($MODO, $(basename "$ARCHIVO"), ${SECONDS} s)"
    exit 0
fi
fallo "Lo restaurado NO coincide con el respaldo (ver las diferencias arriba)"
