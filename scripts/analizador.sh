#!/bin/bash
# analizador.sh - Analizador de la biblioteca (versión 3: lee la base de datos real)
#
# Uso:
#   analizador.sh              menú interactivo
#   analizador.sh MODO
#
# MODO:
#   stock      libros con pocos ejemplares disponibles (alerta de reposición)
#   dormidos   libros que nunca se prestaron
#   ranking    los libros más prestados
#   alertas    todo lo anterior: escribe logs/alertas.log y publica la página
#              /carpeta2/alertas/alertas.html para la bibliotecóloga
#   resumen    totales generales
#
# Cómo cuenta (tabla prestamos de la base de datos biblioteca2):
#   disponibles     = ejemplares (libros.stock) - préstamos con estado 'Prestado'
#   "se prestó"     = tiene un préstamo 'Prestado' o 'Devuelto' (reservas y cancelados no cuentan)
#   alerta de stock = disponibles <= UMBRAL_STOCK y el libro tuvo algún préstamo o reserva
# Las consultas se hacen dentro del contenedor "db" con el usuario de la aplicación,
# usando las variables del propio contenedor: ninguna contraseña pasa por este script.
#
# Variables opcionales:
#   UMBRAL_STOCK  se alerta si quedan este número de ejemplares o menos (por defecto 1)
#   LIMITE        filas de dormidos y ranking a mostrar o alertar (por defecto 20; 0 = todas)
#
# Salida: 0 si todo salió bien, 1 si hubo un error (queda en logs/errores.log)

export LC_ALL=C.UTF-8
set -o pipefail
umask 027

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
LOG_ALERTA="$BASE/logs/alertas.log"
LOG_ERRORES="$BASE/logs/errores.log"
LOG_OP="$BASE/logs/analizador.log"
DESTINO_WEB="/var/www/html/carpeta2/alertas"
UMBRAL="${UMBRAL_STOCK:-1}"
LIMITE="${LIMITE:-20}"
TMP=""
TMP_HTML=""

trap 'rm -f "$TMP" "$TMP_HTML"' EXIT

# Fragmento SQL: el libro (alias l) tiene un préstamo 'Prestado' o 'Devuelto'
SE_PRESTO="EXISTS (SELECT 1 FROM prestamos p WHERE p.libroId = l.id AND p.estado IN ('Prestado','Devuelto'))"

# Función de awk para escribir texto seguro dentro del HTML
AWK_ESC=$'function esc(s) { gsub(/&/, "\\\\&amp;", s); gsub(/</, "\\\\&lt;", s); gsub(/>/, "\\\\&gt;", s); return s }\n'

uso() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_OP"; }

error_fatal() {
    echo "ERROR: $*" >&2
    mkdir -p "$BASE/logs"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: $*" >> "$LOG_ERRORES"
    exit 1
}

[[ "$UMBRAL" =~ ^-?[0-9]+$ ]] || error_fatal "UMBRAL_STOCK debe ser un número entero (recibido: $UMBRAL)"
[[ "$LIMITE" =~ ^[0-9]+$ ]] || error_fatal "LIMITE debe ser un número entero positivo o 0 (recibido: $LIMITE)"
mkdir -p "$BASE/logs" || error_fatal "No se pudo crear $BASE/logs"

# Ejecuta una consulta SQL dentro del contenedor db (salida sin cabecera, separada por tabuladores)
sql() {
    docker compose exec -T db sh -c \
        'exec mariadb -N -B --default-character-set=utf8mb4 -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$1"' \
        sh "$1" < /dev/null
}

verificar_entorno() {
    command -v docker > /dev/null || error_fatal "docker no está instalado"
    [ -f "$BASE/docker-compose.yml" ] || error_fatal "No existe $BASE/docker-compose.yml"
    cd "$BASE" || error_fatal "No se pudo entrar a $BASE"
    local en_marcha
    en_marcha="$(docker compose ps --status running --services 2> /dev/null < /dev/null)"
    grep -qx db <<< "$en_marcha" \
        || error_fatal "El servicio db no está en ejecución (iniciar con: docker compose up -d)"
    sql "SELECT 1" > /dev/null 2>&1 || error_fatal "No se pudo consultar la base de datos"
}

limitar() { if [ "$LIMITE" -gt 0 ]; then head -n "$LIMITE"; else cat; fi; }
contar() { printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'; }
filas() { printf '%s\n' "$1" | awk 'NF'; }
sql_limite() { if [ "$LIMITE" -gt 0 ]; then echo "LIMIT $LIMITE"; fi; }

nota_limite() {
    local total="$1"
    if [ "$LIMITE" -gt 0 ] && [ "$total" -gt "$LIMITE" ]; then
        echo "  ... y $((total - LIMITE)) más (se muestran $LIMITE; usar LIMITE=0 para verlos todos)"
    fi
}

# --- Consultas (cada una devuelve filas separadas por tabuladores) ---

# id, título, ejemplares, prestados, disponibles, veces prestado, reservas
consulta_stock() {
    sql "SELECT l.id, l.titulo, l.stock,
                SUM(p.estado = 'Prestado') AS prestados,
                CAST(l.stock AS SIGNED) - SUM(p.estado = 'Prestado') AS disponibles,
                SUM(p.estado IN ('Prestado','Devuelto')) AS veces,
                SUM(p.estado = 'Reservado') AS reservas
         FROM libros l JOIN prestamos p ON p.libroId = l.id AND p.estado <> 'Cancelado'
         GROUP BY l.id, l.titulo, l.stock
         HAVING disponibles <= $UMBRAL
         ORDER BY disponibles, veces DESC, l.id"
}

# id, título, autor
consulta_dormidos() {
    sql "SELECT l.id, l.titulo, l.autor FROM libros l WHERE NOT $SE_PRESTO ORDER BY l.id $(sql_limite)"
}
total_dormidos() { sql "SELECT COUNT(*) FROM libros l WHERE NOT $SE_PRESTO"; }

# veces prestado, id, título, autor
consulta_ranking() {
    sql "SELECT COUNT(*) AS veces, l.id, l.titulo, l.autor
         FROM prestamos p JOIN libros l ON l.id = p.libroId
         WHERE p.estado IN ('Prestado','Devuelto')
         GROUP BY l.id, l.titulo, l.autor
         ORDER BY veces DESC, l.id $(sql_limite)"
}

total_libros() { sql "SELECT COUNT(*) FROM libros"; }

# --- Página para la bibliotecóloga ---

tabla_html() { # $1 = filas HTML, $2 = cabeceras separadas por |
    if [ -z "$1" ]; then
        echo "<p class=\"vacio\">No hay libros en esta situación.</p>"
        return
    fi
    echo "<table><thead><tr>$(echo "$2" | awk -F'|' '{ for (i = 1; i <= NF; i++) printf "<th>%s</th>", $i }')</tr></thead><tbody>"
    echo "$1"
    echo "</tbody></table>"
}

generar_html() { # $1 fecha, $2 datos de stock, $3 dormidos, $4 total dormidos, $5 ranking
    local fecha="$1" d_stock="$2" d_dorm="$3" n_dorm="$4" d_rank="$5" agotados pocos dorm rank
    agotados="$(filas "$d_stock" | awk -F'\t' "${AWK_ESC}"'$5 <= 0 { printf "<tr><td>L%05d</td><td>%s</td><td class=\"n\">%d</td><td class=\"n\">%d</td><td class=\"n\">%d</td></tr>\n", $1, esc($2), $3, $4, $7 }')"
    pocos="$(filas "$d_stock" | awk -F'\t' "${AWK_ESC}"'$5 > 0 { printf "<tr><td>L%05d</td><td>%s</td><td class=\"n\">%d</td><td class=\"n\">%d</td><td class=\"n\">%d</td><td class=\"n\">%d</td></tr>\n", $1, esc($2), $3, $5, $4, $7 }')"
    dorm="$(filas "$d_dorm" | awk -F'\t' "${AWK_ESC}"'{ printf "<tr><td>L%05d</td><td>%s</td><td>%s</td></tr>\n", $1, esc($2), esc($3) }')"
    rank="$(filas "$d_rank" | awk -F'\t' "${AWK_ESC}"'{ printf "<tr><td class=\"n\">%d</td><td>L%05d</td><td>%s</td><td>%s</td></tr>\n", $1, $2, esc($3), esc($4) }')"

    cat << EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Alertas de la biblioteca</title>
<style>
  :root { color-scheme: light dark; --linea: #8886; --aviso: #b3261e; }
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 60rem; margin: 0 auto; padding: 1.5rem 1rem 3rem; }
  h1 { font-size: 1.6rem; margin: 0 0 .25rem; }
  h2 { font-size: 1.15rem; margin: 2.2rem 0 .25rem; }
  h2.urgente { color: var(--aviso); }
  p { margin: .25rem 0 .75rem; max-width: 42rem; }
  .fecha, .vacio, .nota { opacity: .75; }
  .tabla { overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid var(--linea); vertical-align: top; }
  th { font-weight: 600; }
  .n { text-align: right; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
<h1>Alertas de la biblioteca</h1>
<p class="fecha">Actualizado el $fecha. Se renueva cada 30 minutos.</p>

<h2 class="urgente">Sin ejemplares disponibles: conviene comprar</h2>
<p>Todos los ejemplares de estos libros están prestados.</p>
<div class="tabla">
$(tabla_html "$agotados" "Código|Título|Ejemplares|Prestados|Reservas")
</div>

<h2>Quedan pocos ejemplares</h2>
<p>Libros con $UMBRAL o menos ejemplares disponibles que ya se prestaron o se reservaron.</p>
<div class="tabla">
$(tabla_html "$pocos" "Código|Título|Ejemplares|Disponibles|Prestados|Reservas")
</div>

<h2>Los más prestados</h2>
<p>Candidatos a comprar más ejemplares.</p>
<div class="tabla">
$(tabla_html "$rank" "Veces prestado|Código|Título|Autor")
</div>

<h2>Libros que nunca se prestaron</h2>
<p>Se muestran $(contar "$d_dorm") de $n_dorm.</p>
<div class="tabla">
$(tabla_html "$dorm" "Código|Título|Autor")
</div>
</body>
</html>
EOF
}

# Copia el archivo $1 al contenedor app, donde Apache lo publica
publicar_html() {
    docker compose exec -T -u root app sh -c "
        mkdir -p $DESTINO_WEB &&
        chown root:www-data $DESTINO_WEB && chmod 750 $DESTINO_WEB &&
        cat > $DESTINO_WEB/.alertas.tmp &&
        chown root:www-data $DESTINO_WEB/.alertas.tmp && chmod 640 $DESTINO_WEB/.alertas.tmp &&
        mv $DESTINO_WEB/.alertas.tmp $DESTINO_WEB/alertas.html" < "$1"
}

# --- Modos ---

ejecutar_modo() {
    local modo="$1"
    case "$modo" in
        stock | dormidos | ranking | alertas | resumen) ;;
        *) echo "Modo no válido: $modo"; uso; exit 1 ;;
    esac
    verificar_entorno

    local total_libros fecha datos nd
    total_libros="$(total_libros)" || error_fatal "No se pudo leer la tabla libros"

    case "$modo" in
        stock)
            echo "--- MODO STOCK Y REPOSICIÓN (alerta si quedan $UMBRAL o menos disponibles) ---"
            datos="$(consulta_stock)" || error_fatal "Falló la consulta de stock"
            filas "$datos" | limitar | awk -F'\t' '{
                if ($5 <= 0) msg = "¡ALERTA! Sin ejemplares disponibles. Necesita reposición."
                else         msg = "Aviso: " ($5 == 1 ? "queda 1 ejemplar disponible" : "quedan " $5 " ejemplares disponibles") ". Considerar reposición."
                printf "Libro: L%05d | Título: %s | Disponibles: %d de %d\n  -> %s\n", $1, $2, $5, $3, msg }'
            nota_limite "$(contar "$datos")"
            echo "Libros analizados: $total_libros | en alerta: $(contar "$datos")"
            ;;

        dormidos)
            echo "--- MODO LIBROS DORMIDOS (nunca prestados) ---"
            datos="$(consulta_dormidos)" || error_fatal "Falló la consulta de libros dormidos"
            nd="$(total_dormidos)" || error_fatal "Falló el conteo de libros dormidos"
            filas "$datos" | awk -F'\t' '{ printf "Libro dormido: L%05d - %s (%s)\n", $1, $2, $3 }'
            nota_limite "$nd"
            echo "Libros dormidos: $nd de $total_libros"
            ;;

        ranking)
            if [ "$LIMITE" -gt 0 ]; then
                echo "--- MODO RANKING TOP $LIMITE MÁS PRESTADOS ---"
            else
                echo "--- MODO RANKING COMPLETO DE LIBROS PRESTADOS ---"
            fi
            datos="$(consulta_ranking)" || error_fatal "Falló la consulta del ranking"
            if [ -n "$datos" ]; then
                filas "$datos" | awk -F'\t' '{ printf "  %d %s -> Libro: L%05d (%s)\n", $1, ($1 == 1 ? "préstamo" : "préstamos"), $2, $3 }'
            else
                echo "No hay préstamos registrados."
            fi
            ;;

        alertas)
            echo "--- GENERANDO ALERTAS ---"
            fecha="$(date '+%Y-%m-%d %H:%M:%S')"
            local d_stock d_dorm n_dorm d_rank n_stock n_rank
            d_stock="$(consulta_stock)" || error_fatal "Falló la consulta de stock"
            d_dorm="$(consulta_dormidos)" || error_fatal "Falló la consulta de libros dormidos"
            n_dorm="$(total_dormidos)" || error_fatal "Falló el conteo de libros dormidos"
            d_rank="$(consulta_ranking)" || error_fatal "Falló la consulta del ranking"
            n_stock="$(contar "$d_stock")"
            n_rank="$(contar "$d_rank")"

            TMP="$(mktemp)" || error_fatal "No se pudo crear un archivo temporal"
            {
                filas "$d_stock" | awk -F'\t' -v f="$fecha" \
                    '{ printf "%s - ALERTA STOCK: Libro L%05d (%s) stock disponible: %d\n", f, $1, $2, $5 }'
                filas "$d_dorm" | awk -F'\t' -v f="$fecha" \
                    '{ printf "%s - ALERTA DORMIDO: Libro L%05d (%s) nunca se prestó\n", f, $1, $2 }'
                if [ "$LIMITE" -gt 0 ] && [ "$n_dorm" -gt "$LIMITE" ]; then
                    echo "$fecha - INFO DORMIDOS: se listan $LIMITE de $n_dorm libros que nunca se prestaron"
                fi
                filas "$d_rank" | awk -F'\t' -v f="$fecha" \
                    '{ printf "%s - ALERTA RANKING: Libro L%05d (%s) entre los más prestados: %d %s (considerar comprar más ejemplares)\n", f, $2, $3, $1, ($1 == 1 ? "préstamo" : "préstamos") }'
            } > "$TMP"
            cat "$TMP" > "$LOG_ALERTA" && chmod 640 "$LOG_ALERTA" || error_fatal "No se pudo escribir $LOG_ALERTA"

            TMP_HTML="$(mktemp)" || error_fatal "No se pudo crear un archivo temporal"
            generar_html "$fecha" "$d_stock" "$d_dorm" "$n_dorm" "$d_rank" > "$TMP_HTML" \
                || error_fatal "No se pudo generar la página de alertas"
            publicar_html "$TMP_HTML" || error_fatal "No se pudo publicar la página de alertas en el contenedor app"

            log "ÉXITO: alertas (stock: $n_stock, dormidos: $(contar "$d_dorm") de $n_dorm, ranking: $n_rank, umbral: $UMBRAL)"
            echo "Proceso finalizado (umbral de stock: $UMBRAL)."
            echo "  Stock: $n_stock | Dormidos: $(contar "$d_dorm") (de $n_dorm) | Ranking: $n_rank"
            echo "  Registro: $LOG_ALERTA"
            echo "  Página para la bibliotecóloga: /carpeta2/alertas/alertas.html"
            ;;

        resumen)
            echo "--- RESUMEN GENERAL ---"
            local ej pr re de du ag
            IFS=$'\t' read -r _ ej pr re de du <<< "$(sql "SELECT COUNT(*),
                (SELECT COALESCE(SUM(stock), 0) FROM libros),
                (SELECT COUNT(*) FROM prestamos WHERE estado = 'Prestado'),
                (SELECT COUNT(*) FROM prestamos WHERE estado = 'Reservado'),
                (SELECT COUNT(*) FROM prestamos WHERE estado = 'Devuelto'),
                (SELECT COUNT(*) FROM libros l WHERE NOT $SE_PRESTO)
                FROM libros")" || error_fatal "Falló la consulta del resumen"
            datos="$(consulta_stock)" || error_fatal "Falló la consulta de stock"
            ag="$(filas "$datos" | awk -F'\t' '$5 <= 0' | wc -l)"
            echo "Libros en el catálogo: $total_libros (ejemplares en total: $ej)"
            echo "Préstamos: $pr prestados ahora | $re reservados | $de devueltos"
            echo "Libros que nunca se prestaron: $du"
            echo "Libros en alerta ($UMBRAL o menos disponibles): $(contar "$datos") (sin ejemplares: $ag)"
            ;;
    esac
}

menu() {
    while true; do
        clear
        echo "=========================================="
        echo "   MENÚ INTERACTIVO - ANALIZADOR BIBLIOTECA"
        echo "=========================================="
        echo "1. Ver Stock y Reposición"
        echo "2. Ver Libros Dormidos (nunca prestados)"
        echo "3. Ver Ranking de Libros más prestados"
        echo "4. Generar Alertas (registro y página web)"
        echo "5. Ver Resumen general"
        echo "6. Salir"
        echo "------------------------------------------"
        read -r -p "Elige una opción [1-6]: " opcion
        case "$opcion" in
            1) echo; ejecutar_modo stock ;;
            2) echo; ejecutar_modo dormidos ;;
            3) echo; ejecutar_modo ranking ;;
            4) echo; ejecutar_modo alertas ;;
            5) echo; ejecutar_modo resumen ;;
            6) echo "¡Saliendo del analizador. ¡Hasta luego!"; exit 0 ;;
            *) echo "Opción inválida. Intenta de nuevo."; sleep 1; continue ;;
        esac
        echo
        read -r -p "Presiona ENTER para continuar..."
    done
}

case "${1:-}" in
    -h | --help) uso ;;
    "") menu ;;
    *) ejecutar_modo "$1" ;;
esac
