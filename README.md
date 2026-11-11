# BiblioTech - Administración de Sistemas Operativos (2.ª entrega)

Sistema de biblioteca web (PHP + MariaDB, patrón MVC) desplegado en Apache sobre Ubuntu 26.04 (WSL2), con scripts de administración para despliegue, respaldo, chequeo, exportación de datos y análisis de stock.

Equipo Quantum Dev:

- Anthony Silva (`thony`): desarrollo full stack y team leader.
- Walter Montejo (`walter`): desarrollo full stack y base de datos.
- Jose Palermo (`jose`): desarrollo full stack e interfaz.

La descripción completa del servidor (versiones, usuarios, permisos, SSH, cron) está en `docs/ficha_tecnica.md`.

## Estructura del proyecto

```
Biblioteca/
├── codigo/          # Aplicación PHP (copia de trabajo, con Git)
├── datos/
│   ├── catalogo.csv       # Generado desde la base de datos
│   └── movimientos.log    # Copia del registro que escribe la aplicación
├── docs/            # Ficha técnica, evidencias, casos de error y respuestas breves
├── logs/            # Registros de los scripts
├── respaldos/       # Respaldos .tar.gz + .sha256
└── scripts/
    ├── desplegar.sh
    ├── respaldo.sh
    ├── chequeo.sh
    ├── exportar_datos.sh
    ├── analizador.sh
    ├── probar_restauracion.sh
    ├── evidencias.sh
    ├── casos_error.sh
    └── preparar_log_app.sh
```

La aplicación en producción vive en `/var/www/biblioteca` y se publica en `http://localhost/carpeta2/inicioo.php`.

## Usuarios y permisos

| Usuario | Grupos | Función |
|---|---|---|
| thony | sudo, biblioteca-dev | administración del servidor |
| walter | biblioteca-dev, biblioteca-bd | desarrollo y respaldos de la base de datos |
| jose | biblioteca-dev | desarrollo |

Carpetas con permisos 2750 (el `2` hace que los archivos nuevos hereden el grupo), `respaldos/` con 2770, scripts 750 y archivos de datos y logs 640.

Para reaplicar los permisos desde la raíz del proyecto:

```bash
cd ~/Biblioteca
chmod 750 scripts/*.sh
chmod 640 datos/* logs/*
```

## Cómo llegan los movimientos al analizador

```
Aplicación web ──escribe──> /var/log/biblioteca/movimientos.log
                                      │  (exportar_datos.sh, cron cada 30 min, valida el formato)
                                      ▼
                          datos/movimientos.log ──> analizador.sh ──> logs/alertas.log
Base de datos ──(exportar_datos.sh)──> datos/catalogo.csv ──────────┘
```

Cada vez que se registra un préstamo, una devolución o una reserva en el formulario de préstamos, `includes/registro_movimientos.php` agrega una línea al registro, solo después de que la base de datos confirma el cambio. Si el registro no se puede escribir, la aplicación sigue funcionando y el error queda en el log de Apache.

El registro se prepara una vez con `scripts/preparar_log_app.sh`: crea `/var/log/biblioteca/` (propietario `www-data`, grupo `biblioteca-dev`) y lo inicia con los movimientos reconstruidos de los préstamos existentes.

## Formato de los datos

`datos/catalogo.csv` (separador `;`):

```
id;titulo;autor;categoria;ejemplares
L00001;Título;Autor;Categoría;1
```

`datos/movimientos.log` (una línea por evento):

```
2026-11-07 21:15:00 PRESTAMO libro=L00001 usuario=A011
```

Los tipos de evento son `PRESTAMO`, `DEVOLUCION` y `RESERVA`. `chequeo.sh` valida el formato de ambos archivos.

## Uso de los scripts

Todos se ejecutan desde la raíz del proyecto (`cd ~/Biblioteca`) y escriben su registro en `logs/`.

### 1. Despliegue (`desplegar.sh`)

Copia `codigo/` a `/var/www/biblioteca`, ajusta permisos, valida Apache, lo recarga y prueba las URL principales.

```bash
./scripts/desplegar.sh          # despliega el código tal como está en codigo/
./scripts/desplegar.sh --git    # antes hace git pull (solo si no hay cambios locales sin guardar)
```

No debe ejecutarse como root: usa `sudo` solo en los pasos que lo requieren.

### 2. Respaldo (`respaldo.sh`)

```bash
./scripts/respaldo.sh
```

Genera `respaldos/respaldo_AAAA-MM-DD_HH-MM-SS.tar.gz` con el volcado de la base, código, datos, docs, scripts y `uploads/`, más su archivo `.sha256`. Verifica el archivo y conserva los últimos 7 respaldos.

Verificar un respaldo:

```bash
cd ~/Biblioteca/respaldos && sha256sum -c respaldo_*.tar.gz.sha256
```

### 3. Chequeo (`chequeo.sh`)

```bash
./scripts/chequeo.sh
```

Revisa estructura y permisos, formato de los datos, servicios (apache2, mariadb, ssh), respuesta web, base de datos, antigüedad e integridad del último respaldo y uso de disco. Muestra el resultado de cada control y un resumen final; termina con código 1 si encuentra errores.

### 4. Exportación de datos (`exportar_datos.sh`)

```bash
./scripts/exportar_datos.sh
```

Genera `datos/catalogo.csv` desde la base de datos y copia el registro de movimientos de la aplicación a `datos/movimientos.log`, con validación de formato y reemplazo atómico de los archivos. Para leer el registro hay que pertenecer al grupo `biblioteca-dev` (las tareas de cron ya lo hacen).

### 5. Analizador (`analizador.sh`)

Modo interactivo (menú):

```bash
./scripts/analizador.sh
```

Modo por argumentos: `analizador.sh MODO [catalogo] [movimientos]`

```bash
./scripts/analizador.sh stock       # libros con 0 o 1 ejemplar disponible (reposición)
./scripts/analizador.sh dormidos    # libros que nunca se prestaron
./scripts/analizador.sh ranking     # libros más prestados
./scripts/analizador.sh alertas     # todo lo anterior en formato alerta, en logs/alertas.log
./scripts/analizador.sh resumen     # resumen general
```

Cuenta clave del modo stock: `disponibles = ejemplares - (préstamos - devoluciones)`.

Variables opcionales:

- `UMBRAL_STOCK`: se alerta si quedan este número de ejemplares o menos (por defecto 1, es decir, con 0 o 1 disponible; con `UMBRAL_STOCK=0` solo se alerta a los libros sin ejemplares).
- `LIMITE`: cantidad de filas a mostrar de los listados de dormidos y ranking, y a registrar en `alertas`. Por defecto 20; 0 muestra todo.

El archivo `logs/alertas.log` se reescribe en cada ejecución del modo `alertas`, con líneas de tres tipos:

```
2026-11-08 13:09:47 - ALERTA STOCK: Libro L00003 (Título) stock disponible: 0
2026-11-08 13:09:47 - ALERTA DORMIDO: Libro L00001 (Título) nunca se prestó
2026-11-08 13:09:47 - ALERTA RANKING: Libro L00042 (Título) entre los más prestados: 3 préstamos (considerar comprar más ejemplares)
```

Los errores (archivo inexistente, modo inválido, umbral no numérico) se registran en `logs/errores.log` y el script termina con código 1.

## Tareas programadas (cron)

| Frecuencia | Tarea |
|---|---|
| cada 30 min (:00 y :30) | `exportar_datos.sh` |
| cada 30 min (:05 y :35) | `analizador.sh alertas` |
| todos los días, 02:00 | `respaldo.sh` |
| cada hora (:40) | `chequeo.sh` |

Ver la tabla instalada: `crontab -l`. La salida de todas las tareas se agrega a `logs/cron.log`.

Importante: en WSL2 cron solo corre mientras la instancia de Ubuntu esté abierta o activa.

## Verificación y evidencias

### 6. Prueba de restauración (`probar_restauracion.sh`)

```bash
./scripts/probar_restauracion.sh
```

Toma el último respaldo, verifica su SHA-256, lo extrae en una carpeta temporal y carga el volcado en una base temporal (`biblioteca_restore_test`). Compara la cantidad de filas de cada tabla con la base real y elimina todo lo temporal al terminar. No modifica `biblioteca2`; se aborta si el volcado intentara escribir sobre la base real.

### 7. Evidencias (`evidencias.sh`)

```bash
./scripts/evidencias.sh
```

Genera `docs/evidencias.txt` con la salida de los controles de cada objetivo: usuarios y grupos, permisos, SSH (incluido el rechazo de root), Apache, despliegue, respaldo, chequeo, registro de la aplicación, analizador y cron.

### 8. Casos de error (`casos_error.sh`)

```bash
./scripts/casos_error.sh
```

Provoca errores en `analizador.sh`, `exportar_datos.sh`, `respaldo.sh`, `chequeo.sh` y `desplegar.sh`, sobre copias en una carpeta temporal (no toca datos ni respaldos reales), y guarda los comandos, mensajes y códigos de salida en `docs/casos_error.txt`.

## Registros

| Archivo | Origen |
|---|---|
| `logs/despliegue.log` | despliegues |
| `logs/respaldo.log` | respaldos (ÉXITO / ERROR) |
| `logs/chequeo.log` | avisos, errores y resumen de cada chequeo |
| `logs/exportar.log` | exportaciones de datos |
| `logs/alertas.log` | alertas vigentes del analizador |
| `logs/errores.log` | errores del analizador |
| `logs/cron.log` | salida de las tareas programadas |
| `/var/log/biblioteca/movimientos.log` | movimientos que escribe la aplicación |
