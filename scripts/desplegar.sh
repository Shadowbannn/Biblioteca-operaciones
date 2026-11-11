#!/bin/bash
# desplegar.sh - Publica la aplicación BiblioTech en Apache (versión 2)
# Uso: desplegar.sh [--git]
#   --git   antes de copiar, actualiza el código con git pull
#           (solo si en codigo/ no hay cambios sin guardar)

set -o pipefail

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$(dirname "$DIR_SCRIPT")"
ORIGEN="$BASE/codigo"
DESTINO="/var/www/biblioteca"
LOG="$BASE/logs/despliegue.log"
URLS_PRUEBA="http://localhost/carpeta2/inicioo.php http://localhost/carpeta2/index.php?accion=listarCatalogo"
CARPETAS_UPLOADS="fotos juegos portadas proyectos usuarios"

USAR_GIT=0
case "${1:-}" in
    "") ;;
    --git) USAR_GIT=1 ;;
    *) echo "Uso: $0 [--git]"; exit 1 ;;
esac

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
fallo() { log "ERROR: $*"; exit 1; }

# Todo lo que se muestra también queda guardado en el log
touch "$LOG" && chmod 640 "$LOG" || { echo "No se puede escribir en $LOG"; exit 1; }
exec > >(tee -a "$LOG") 2>&1

log "=== Inicio del despliegue (usuario: $(id -un)) ==="

# --- 1. Comprobaciones previas ---
[ "$(id -u)" -ne 0 ] || fallo "No ejecutar como root: usar un usuario normal con sudo."
[ -f "$ORIGEN/index.php" ] || fallo "No se encontró $ORIGEN/index.php"
[ -f "$ORIGEN/config/conexion.php" ] || fallo "No se encontró $ORIGEN/config/conexion.php"
command -v rsync > /dev/null || fallo "rsync no está instalado (sudo apt install rsync)"
sudo -v || fallo "No se pudo obtener permiso de sudo"
sudo test -f /etc/biblioteca/db.conf || log "AVISO: falta /etc/biblioteca/db.conf (la app no podrá conectarse a la base)"

# --- 2. Actualizar el código (opcional) ---
if [ "$USAR_GIT" -eq 1 ]; then
    [ -d "$ORIGEN/.git" ] || fallo "$ORIGEN no es un repositorio Git"
    if [ -n "$(git -C "$ORIGEN" status --porcelain)" ]; then
        fallo "Hay cambios sin guardar en $ORIGEN: hacer commit antes de usar --git"
    fi
    log "Actualizando desde Git..."
    git -C "$ORIGEN" pull --ff-only || fallo "git pull falló"
else
    log "Sin Git: se publica lo que hay en $ORIGEN"
fi

# --- 3. Copiar el código a la carpeta web ---
log "Copiando el código a $DESTINO (sin .git, BD ni uploads)..."
sudo install -d -o "$(id -un)" -g www-data -m 2750 "$DESTINO" || fallo "No se pudo preparar $DESTINO"
rsync -rlt --delete --exclude='.git' --exclude='BD' --exclude='uploads' "$ORIGEN"/ "$DESTINO"/ \
    || fallo "rsync falló"

# --- 4. Grupo y permisos (carpetas 2750, archivos 640) ---
log "Ajustando grupo y permisos..."
sudo find "$DESTINO" -path "$DESTINO/uploads" -prune -o -exec chgrp www-data {} + || fallo "chgrp falló"
sudo find "$DESTINO" -path "$DESTINO/uploads" -prune -o -type d -exec chmod 2750 {} + || fallo "chmod de carpetas falló"
sudo find "$DESTINO" -path "$DESTINO/uploads" -prune -o -type f -exec chmod 640 {} + || fallo "chmod de archivos falló"

# --- 5. uploads: Apache debe poder escribir ---
sudo install -d -o www-data -g www-data -m 775 "$DESTINO/uploads" || fallo "No se pudo preparar uploads"
for c in $CARPETAS_UPLOADS; do
    sudo install -d -o www-data -g www-data -m 775 "$DESTINO/uploads/$c" || fallo "No se pudo preparar uploads/$c"
done

# --- 6. Apache ---
log "Comprobando y recargando Apache..."
sudo apache2ctl configtest || fallo "La configuración de Apache tiene errores"
sudo systemctl reload apache2 || fallo "No se pudo recargar Apache"

# --- 7. Verificación ---
sleep 1
for url in $URLS_PRUEBA; do
    codigo="$(curl -s -o /dev/null -w '%{http_code}' "$url")"
    log "Prueba $url -> $codigo"
    [ "$codigo" = "200" ] || fallo "La prueba $url respondió $codigo (se esperaba 200)"
done

log "=== Despliegue finalizado con éxito ==="
