#!/bin/bash
# chequeo.sh - Chequeo del estado de BiblioTech en contenedores (versión 3)
# Verifica: estructura y permisos, contenedores, aplicación web, base de datos,
# respaldos (y su prueba de restauración) y tareas programadas.
# Muestra [OK] / [AVISO] / [ERROR], guarda los avisos y errores en
# logs/chequeo.log y termina con código 0 si no hay errores (1 si los hay).
# Los avisos no cambian el código de salida.
#
# Uso: ./scripts/chequeo.sh

export LC_ALL=C.UTF-8

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
LOG="$BASE/logs/chequeo.log"
ENV_ARCHIVO="$BASE/.env"
RESPALDOS="$BASE/respaldos"
LOG_RESTAURACION="$BASE/logs/restauracion_docker.log"
BASE_DATOS="biblioteca2"
TABLAS="libros socios usuarios prestamos juegos proyectos"
GRUPO_DEV="biblioteca-dev"
GRUPO_BD="biblioteca-bd"
PROYECTO="bibliotech"
UPLOADS_APP="/var/www/html/carpeta2/uploads"
MOVIMIENTOS_APP="/var/log/biblioteca/movimientos.log"
ALERTAS_APP="/var/www/html/carpeta2/alertas/alertas.html"
MAX_HORAS_RESPALDO=26
MAX_DIAS_PRUEBA=8
MAX_MIN_ALERTAS=90
MAX_USO_DISCO=90
CABECERA_REGEX_MOV='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} (PRESTAMO|DEVOLUCION|RESERVA) libro=[^ ]+ usuario=[^ ]+$'

N_OK=0; N_AVISOS=0; N_ERRORES=0
DOCKER_OK=0; DB_UP=0; APP_UP=0

registrar() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; }
ok()     { echo "[OK]     $*"; N_OK=$((N_OK + 1)); }
aviso()  { echo "[AVISO]  $*"; N_AVISOS=$((N_AVISOS + 1)); registrar "AVISO: $*"; }
error()  { echo "[ERROR]  $*"; N_ERRORES=$((N_ERRORES + 1)); registrar "ERROR: $*"; }

# docker compose dentro del proyecto, con límite de tiempo y sin leer del teclado
dc() { ( cd "$BASE" && timeout 30 docker compose "$@" < /dev/null ); }

# Consulta SQL dentro del contenedor db, con el usuario de la aplicación
sql_db() {
    dc exec -T db sh -c \
        'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$1"' sh "$1"
}

# Servicio del sistema activo (con systemd o, si no lo hay, por nombre de proceso)
servicio_activo() { systemctl is-active --quiet "$1" 2> /dev/null || pgrep -x "$2" > /dev/null 2>&1; }

# Comprueba que una ruta exista con el permiso (y grupo) esperados
verificar_ruta() {
    local ruta="$1" modo="$2" grupo="$3" nombre="${1#"$BASE"/}"
    [ "$ruta" = "$BASE" ] && nombre="Biblioteca/"
    if [ ! -e "$ruta" ]; then
        error "Falta $nombre"
        return
    fi
    local modo_real grupo_real
    modo_real="$(stat -c '%a' "$ruta")"
    grupo_real="$(stat -c '%G' "$ruta")"
    if [ "$modo_real" = "$modo" ] && [ "$grupo_real" = "$grupo" ]; then
        ok "$nombre ($modo_real, grupo $grupo_real)"
    else
        error "$nombre tiene $modo_real/$grupo_real y se esperaba $modo/$grupo"
    fi
}

mkdir -p "$BASE/logs" 2> /dev/null
touch "$LOG" && chmod 640 "$LOG" || { echo "No se puede escribir en $LOG"; exit 1; }

echo "Chequeo de BiblioTech - $(date '+%Y-%m-%d %H:%M:%S')"
echo "Proyecto: $BASE"

# --- 1. Estructura, permisos y secretos ---
echo; echo "== 1. Estructura, permisos y secretos =="
verificar_ruta "$BASE" 2750 "$GRUPO_DEV"
for d in codigo docs scripts datos logs; do
    verificar_ruta "$BASE/$d" 2750 "$GRUPO_DEV"
done
verificar_ruta "$BASE/respaldos" 2770 "$GRUPO_BD"
for s in "$BASE"/scripts/*.sh; do
    [ -e "$s" ] && verificar_ruta "$s" 750 "$GRUPO_DEV"
done

if [ ! -e "$ENV_ARCHIVO" ]; then
    error "Falta .env (se crea a partir de .env.example)"
else
    modo_env="$(stat -c '%a' "$ENV_ARCHIVO")"
    if [ "${modo_env: -1}" = "0" ]; then
        ok ".env ($modo_env): sin acceso para otros usuarios"
    else
        error ".env tiene permisos $modo_env: otros usuarios pueden leer las contraseñas"
    fi
fi
if grep -Eiq '(password|passwd|secret)[a-z_]*[:=] *[^ $"]' "$BASE/docker-compose.yml" "$BASE/Dockerfile" 2> /dev/null; then
    error "Hay contraseñas escritas en docker-compose.yml o en el Dockerfile (deben venir de .env)"
else
    ok "docker-compose.yml y Dockerfile sin contraseñas escritas"
fi

# --- 2. Docker y contenedores ---
echo; echo "== 2. Docker y contenedores =="
if ! command -v docker > /dev/null 2>&1; then
    error "docker no está instalado"
elif ! timeout 20 docker info > /dev/null 2>&1 < /dev/null; then
    error "El servicio de Docker no responde (¿este usuario está en el grupo docker?)"
else
    DOCKER_OK=1
    ok "Docker activo"
fi

if [ "$DOCKER_OK" -eq 1 ]; then
    en_marcha="$(dc ps --status running --services 2> /dev/null)"
    for s in db app; do
        if grep -qx "$s" <<< "$en_marcha"; then
            ok "Contenedor $s en ejecución"
            [ "$s" = "db" ] && DB_UP=1
            [ "$s" = "app" ] && APP_UP=1
        else
            error "Contenedor $s detenido (iniciar con: docker compose up -d)"
        fi
    done
    if [ "$DB_UP" -eq 1 ]; then
        id_db="$(dc ps -q db 2> /dev/null)"
        salud="$(timeout 20 docker inspect -f '{{.State.Health.Status}}' "$id_db" 2> /dev/null)"
        if [ "$salud" = "healthy" ]; then
            ok "Base de datos saludable (healthcheck)"
        else
            error "La base de datos no está saludable (estado: ${salud:-desconocido})"
        fi
    fi
    for v in db_data uploads movimientos; do
        if timeout 20 docker volume inspect "${PROYECTO}_$v" > /dev/null 2>&1; then
            ok "Volumen ${PROYECTO}_$v existe"
        else
            error "Falta el volumen ${PROYECTO}_$v (los datos no sobrevivirían)"
        fi
    done
fi

# --- 3. Aplicación web ---
echo; echo "== 3. Aplicación web =="
PUERTO="$(grep -E '^APP_PORT=' "$ENV_ARCHIVO" 2> /dev/null | cut -d= -f2)"
PUERTO="${PUERTO:-8080}"
URL="http://localhost:$PUERTO"

codigo="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$URL/carpeta2/inicioo.php")"
[ "$codigo" = "200" ] && ok "$URL/carpeta2/inicioo.php -> 200" || error "$URL/carpeta2/inicioo.php -> $codigo (se esperaba 200)"

pagina="$(curl -s -m 30 -w '\n%{http_code}' "$URL/carpeta2/index.php?accion=listarCatalogo")"
codigo_cat="${pagina##*$'\n'}"
if [ "$codigo_cat" != "200" ]; then
    error "Catálogo -> $codigo_cat (se esperaba 200)"
elif grep -qE '(Fatal error|Parse error|Warning|Notice|Deprecated)(</b>)?:|Uncaught |Error de conexi' <<< "$pagina"; then
    error "El catálogo responde 200 pero muestra errores de PHP o de conexión"
else
    ok "Catálogo responde 200 y lee la base de datos"
fi

if [ "$APP_UP" -eq 1 ]; then
    if dc exec -T -u www-data app test -w "$UPLOADS_APP" 2> /dev/null; then
        ok "uploads/ existe y Apache puede escribir"
    else
        error "uploads/ no existe o Apache (www-data) no puede escribir"
    fi

    if ! dc exec -T app test -f "$MOVIMIENTOS_APP" 2> /dev/null; then
        aviso "La aplicación todavía no creó el registro de movimientos ($MOVIMIENTOS_APP)"
    else
        if dc exec -T -u www-data app test -w "$MOVIMIENTOS_APP" 2> /dev/null; then
            ok "Registro de movimientos: Apache puede escribir"
        else
            error "Apache (www-data) no puede escribir en $MOVIMIENTOS_APP"
        fi
        movs="$(dc exec -T app cat "$MOVIMIENTOS_APP" 2> /dev/null)"
        total="$(printf '%s' "$movs" | awk 'END { print NR }')"
        invalidas="$(printf '%s' "$movs" | grep -cvE "$CABECERA_REGEX_MOV")"
        if [ "$invalidas" -eq 0 ]; then
            ok "Registro de movimientos: formato válido (líneas: $total)"
        else
            error "Registro de movimientos: formato inválido en $invalidas de $total líneas"
        fi
    fi

    codigo_al="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$URL/carpeta2/alertas/alertas.html")"
    if [ "$codigo_al" != "200" ]; then
        error "Página de alertas -> $codigo_al (generarla con: ./scripts/analizador.sh alertas)"
    else
        mtime="$(dc exec -T app stat -c %Y "$ALERTAS_APP" 2> /dev/null)"
        if [[ "$mtime" =~ ^[0-9]+$ ]]; then
            edad_min=$(( ($(date +%s) - mtime) / 60 ))
            if [ "$edad_min" -le "$MAX_MIN_ALERTAS" ]; then
                ok "Página de alertas responde 200 y se actualizó hace $edad_min min"
            else
                aviso "La página de alertas tiene $edad_min min (máximo $MAX_MIN_ALERTAS): ¿el cron del analizador corre?"
            fi
        else
            ok "Página de alertas responde 200"
        fi
    fi
fi

# --- 4. Base de datos ---
echo; echo "== 4. Base de datos =="
if [ "$DB_UP" -eq 0 ]; then
    error "No se puede consultar la base de datos: el contenedor db no está en ejecución"
else
    for t in $TABLAS; do
        n="$(sql_db "SELECT COUNT(*) FROM $t" 2> /dev/null)"
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            ok "Tabla $t: $n filas"
        else
            error "No se pudo leer la tabla $t de $BASE_DATOS"
        fi
    done
fi

# --- 5. Respaldos ---
echo; echo "== 5. Respaldos =="
ultimo="$(ls -1t "$RESPALDOS"/respaldo-docker_*.tar.gz 2> /dev/null | head -n 1)"
if [ -z "$ultimo" ]; then
    error "No hay ningún respaldo respaldo-docker_*.tar.gz en respaldos/"
else
    cantidad="$(ls -1 "$RESPALDOS"/respaldo-docker_*.tar.gz | wc -l)"
    edad_h=$(( ($(date +%s) - $(stat -c %Y "$ultimo")) / 3600 ))
    ok "Respaldos disponibles: $cantidad; el último es $(basename "$ultimo")"
    if [ "$edad_h" -le "$MAX_HORAS_RESPALDO" ]; then
        ok "Antigüedad del último respaldo: $edad_h h (máximo $MAX_HORAS_RESPALDO h)"
    else
        aviso "Antigüedad del último respaldo: $edad_h h (máximo $MAX_HORAS_RESPALDO h)"
    fi
    if (cd "$RESPALDOS" && sha256sum -c --status "$(basename "$ultimo").sha256" 2> /dev/null); then
        ok "El sha256 del último respaldo coincide"
    else
        error "El sha256 del último respaldo NO coincide (o falta el .sha256)"
    fi
    if lista="$(tar -tzf "$ultimo" 2> /dev/null)"; then
        faltan=""
        for esperado in "bd/$BASE_DATOS.sql" "MANIFIESTO.txt" "docker-compose.yml"; do
            grep -qx "$esperado" <<< "$lista" || faltan="$faltan $esperado"
        done
        grep -q '^uploads/' <<< "$lista" || faltan="$faltan uploads/"
        if [ -z "$faltan" ]; then
            ok "El último respaldo se puede leer y contiene base de datos, uploads y manifiesto"
        else
            error "Al último respaldo le falta:$faltan"
        fi
        if grep -qE '(^|/)\.env$' <<< "$lista"; then
            error "El último respaldo contiene un .env (no debe llevar contraseñas)"
        else
            ok "El último respaldo no contiene contraseñas (.env)"
        fi
    else
        error "El último respaldo está dañado (no se puede leer con tar)"
    fi
fi

ultima_prueba="$(grep 'restauración verificada (--probar' "$LOG_RESTAURACION" 2> /dev/null | tail -n 1 | cut -c1-19)"
if [ -z "$ultima_prueba" ]; then
    aviso "Nunca se probó una restauración (ejecutar: ./scripts/restaurar_docker.sh --probar)"
elif ts_prueba="$(date -d "$ultima_prueba" +%s 2> /dev/null)"; then
    dias=$(( ($(date +%s) - ts_prueba) / 86400 ))
    if [ "$dias" -le "$MAX_DIAS_PRUEBA" ]; then
        ok "Última prueba de restauración exitosa: $ultima_prueba (antigüedad: $dias d)"
    else
        aviso "La última prueba de restauración exitosa fue el $ultima_prueba (antigüedad: $dias d; máximo $MAX_DIAS_PRUEBA d)"
    fi
fi

# --- 6. Tareas programadas y servicios del servidor ---
echo; echo "== 6. Tareas programadas y servicios =="
if servicio_activo cron cron; then
    ok "Servicio cron activo"
else
    error "Servicio cron inactivo (no se ejecutan las tareas programadas)"
fi
if servicio_activo ssh sshd || systemctl is-active --quiet ssh.socket 2> /dev/null; then
    ok "Servicio SSH activo"
else
    aviso "Servicio SSH inactivo"
fi

cron_activo="$(crontab -l 2> /dev/null | grep -v '^[[:space:]]*#')"
if [ -z "$cron_activo" ]; then
    error "El usuario $(id -un) no tiene tareas en cron"
else
    grep -qF 'respaldo_docker.sh' <<< "$cron_activo" \
        && ok "cron: respaldo_docker.sh programado" \
        || error "cron: falta programar respaldo_docker.sh (el respaldo automático no existe)"
    grep -qF 'analizador.sh alertas' <<< "$cron_activo" \
        && ok "cron: analizador.sh alertas programado" \
        || error "cron: falta programar analizador.sh alertas"
    grep -qF 'restaurar_docker.sh --probar' <<< "$cron_activo" \
        && ok "cron: prueba de restauración programada" \
        || aviso "cron: falta programar restaurar_docker.sh --probar (prueba periódica)"
    grep -qF 'chequeo.sh' <<< "$cron_activo" \
        && ok "cron: chequeo.sh programado" \
        || aviso "cron: falta programar chequeo.sh"
    if grep -Eq '(^|/)respaldo\.sh|exportar_datos\.sh|/entrega/' <<< "$cron_activo"; then
        aviso "cron: quedan tareas de la versión anterior (respaldo.sh, exportar_datos.sh o /entrega/)"
    fi
fi

# --- 7. Disco ---
echo; echo "== 7. Disco =="
uso="$(df --output=pcent "$BASE" | tail -n 1 | tr -dc '0-9')"
if [ "$uso" -le "$MAX_USO_DISCO" ]; then
    ok "Uso del disco: $uso% (máximo $MAX_USO_DISCO%)"
else
    aviso "Uso del disco: $uso% (máximo $MAX_USO_DISCO%)"
fi

# --- Resumen ---
echo
echo "Resumen: $N_OK correctos, $N_AVISOS avisos, $N_ERRORES errores"
registrar "Chequeo: $N_OK correctos, $N_AVISOS avisos, $N_ERRORES errores"
[ "$N_ERRORES" -eq 0 ]
