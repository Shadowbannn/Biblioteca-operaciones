#!/bin/bash
# casos_error.sh - Ejecuta casos de error de cada script y guarda la salida en docs/casos_error.txt
# Trabaja sobre copias de los scripts en una carpeta temporal: no modifica los
# datos, logs ni respaldos reales.

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
SALIDA="$BASE/docs/casos_error.txt"
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"

[ -d "$BASE/docs" ] || { echo "No existe $BASE/docs"; exit 1; }
[ -z "$SUDO" ] || sudo -v || exit 1
umask 027

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts" "$T/logs" "$T/datos"
for s in analizador exportar_datos respaldo chequeo desplegar; do
    cp "$DIR_SCRIPT/$s.sh" "$T/scripts/$s.sh" || { echo "Falta $DIR_SCRIPT/$s.sh"; exit 1; }
done
chmod +x "$T"/scripts/*.sh
cd "$T" || exit 1

seccion() { echo; echo "=================== $* ==================="; }

# caso "descripción" comando...  -> muestra el comando, su salida y su código de salida
caso() {
    local desc="$1" rc; shift
    echo; echo "--- $desc"
    echo "\$ $*"
    "$@" 2>&1 | sed "s#$T#/tmp/prueba#g"
    rc=${PIPESTATUS[0]}
    echo "[código de salida: $rc]"
}

{
echo "CASOS DE ERROR - BiblioTech (Quantum Dev)"
echo "Generado: $(date '+%F %T')  (ejecutado sobre una copia temporal; no se tocaron datos reales)"

seccion "analizador.sh"
printf 'id;titulo;autor;categoria;ejemplares\nL1;Titulo;Autor;Cat;1\n' > datos/ok.csv
caso "Modo inexistente" ./scripts/analizador.sh inventado datos/ok.csv datos/ok.csv
caso "Catálogo inexistente" ./scripts/analizador.sh stock /no/existe.csv
: > datos/vacio.csv
caso "Catálogo vacío" ./scripts/analizador.sh stock datos/vacio.csv
printf 'a;b\n1;2\n' > datos/malo.csv
caso "Catálogo con cabecera incorrecta" ./scripts/analizador.sh stock datos/malo.csv
caso "Archivo de movimientos inexistente" ./scripts/analizador.sh stock datos/ok.csv /no/existe.log
caso "Umbral de stock no numérico" env UMBRAL_STOCK=abc ./scripts/analizador.sh stock datos/ok.csv datos/ok.csv
echo; echo "--- Registro de errores (logs/errores.log)"
sed -e 's/^[0-9-]* [0-9:]* - /FECHA HORA - /' -e "s#$T#/tmp/prueba#g" logs/errores.log

seccion "exportar_datos.sh"
caso "Falta el archivo de credenciales .respaldo.cnf" ./scripts/exportar_datos.sh
printf '[client]\nuser=usuario_inexistente\npassword=incorrecta\n' > .respaldo.cnf
caso "Credenciales de base de datos inválidas" ./scripts/exportar_datos.sh

seccion "respaldo.sh"
caso "No existe la carpeta de respaldos" ./scripts/respaldo.sh
mkdir respaldos && rm -f .respaldo.cnf
caso "Falta el archivo de credenciales .respaldo.cnf" ./scripts/respaldo.sh

seccion "chequeo.sh"
printf 'id;titulo\nL1;Uno\n' > datos/catalogo.csv
printf '2026-11-08 10:00:00 PRESTAMO libro=L1 usuario=A1\nlinea con formato incorrecto\n' > datos/movimientos.log
echo; echo "--- Estructura incompleta y datos con formato inválido (se muestran solo avisos y errores)"
echo "\$ ./scripts/chequeo.sh | grep -E '\\[(AVISO|ERROR)\\]|Resumen'"
./scripts/chequeo.sh > "$T/chequeo.out" 2>&1; rc=$?
grep -E '\[(AVISO|ERROR)\]|Resumen' "$T/chequeo.out" | sed "s#$T#/tmp/prueba#g"
echo "[código de salida: $rc]"

seccion "desplegar.sh"
caso "Argumento no válido" ./scripts/desplegar.sh --x
caso "No existe el código fuente (codigo/index.php)" ./scripts/desplegar.sh
caso "Ejecución como root (no permitida)" $SUDO ./scripts/desplegar.sh

echo; echo "FIN DE LOS CASOS DE ERROR"
} > "$SALIDA" 2>&1
echo "Listo: $SALIDA ($(wc -l < "$SALIDA") líneas)"
