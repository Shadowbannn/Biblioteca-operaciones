# Respuestas breves - 2.ª entrega

BiblioTech · Equipo Quantum Dev · Administración de Sistemas Operativos (UTU)

## 1. ¿Qué error encontramos y cómo lo depuramos?

**El error.** Al publicar la aplicación en Apache, la página respondía primero con un error 500 y después con un 403, aunque la configuración de Apache era correcta (`apache2ctl configtest` decía `Syntax OK`).

**Cómo lo depuramos.**

1. En vez de probar cambios al azar, leímos el log de errores de Apache (`/var/log/apache2/error.log`), que mostraba que PHP no podía abrir los archivos.
2. Con `ls -l` y `stat` comprobamos que los archivos copiados quedaban con el grupo `thony`, mientras que Apache corre como el usuario `www-data`, que no tenía permiso de lectura.
3. Pensamos en usar carpetas con el bit setgid para que los archivos nuevos heredaran el grupo `www-data`, pero el sistema quita ese bit cuando quien copia no pertenece al grupo. Por eso hubo que corregir el grupo explícitamente.
4. Solución: `chgrp -R www-data` y permisos 2750 en carpetas y 640 en archivos. Lo dejamos automatizado dentro de `desplegar.sh`, para que el problema no reaparezca en cada despliegue.

**Otros errores del mismo estilo.**

- Windows no distingue mayúsculas y minúsculas en los nombres de archivo y Linux sí. Al pasar el proyecto fallaban `require` como `formjuego.php` (el archivo real es `formJuego.php`), `views/Socios` (la carpeta es `socios`) y `models/Prestamo.php` (el archivo es `prestamo.php`). Los encontramos comparando cada `require` con los archivos reales y los corregimos en el código.
- El `respaldo.sh` original excluía carpetas con una ruta absoluta que nunca coincidía, y los respaldos terminaban incluyéndose a sí mismos. Se corrigió usando rutas relativas y se comprobó el contenido del archivo.
- `chequeo.sh` marcaba un error de permisos en un script que habíamos editado con `sed -i`: esa herramienta recrea el archivo y este quedaba con otro grupo. Lo resolvimos con carpetas setgid y ajustando el chequeo.

## 2. ¿Qué decisión de diseño tomamos y por qué?

**Decisión principal: la aplicación escribe su propio registro de movimientos.**

La tabla `prestamos` guarda solo el estado actual de cada préstamo, no su historia. Nuestra primera solución reconstruía los movimientos desde esa tabla, pero tenía que inventar las fechas (por ejemplo, la hora de una devolución). Preferimos que la aplicación agregue una línea al registro (`PRESTAMO`, `DEVOLUCION` o `RESERVA`) en el momento en que ocurre el hecho:

- La línea se escribe solo después de que la base de datos confirma el cambio, para que el registro nunca diga algo que no pasó.
- Si el registro no se puede escribir, la aplicación sigue funcionando y el problema queda en el log de errores de Apache.
- El archivo está fuera de la carpeta web, en `/var/log/biblioteca/movimientos.log`. La escribe solo `www-data` y puede leerlo el equipo (permisos 640, grupo `biblioteca-dev`).
- `exportar_datos.sh` lo copia a `datos/` validando el formato, y el analizador trabaja sobre esa copia.

**Otras decisiones.**

- Las contraseñas de la base de datos no están en el código: la aplicación las lee de `/etc/biblioteca/db.conf` (solo `root` y `www-data`).
- Dos cuentas de base de datos con el mínimo privilegio: la aplicación puede leer y modificar, y las tareas de respaldo y exportación solo pueden leer.
- El código se trabaja en una carpeta con Git y se publica en `/var/www/biblioteca` por copia (`desplegar.sh`), para que Apache no tenga acceso al repositorio ni al volcado de la base.

## 3. ¿Qué mejoraríamos con más tiempo?

- **Despliegue:** pasar a contenedores (Docker), con la configuración por variables de entorno y sin dependencia de que WSL esté abierto para que corra cron.
- **Seguridad:** permitir SSH solo con claves (hoy también acepta contraseña) y usar HTTPS.
- **Analizador:** conectarlo directamente a la base de datos y mostrar las alertas dentro de la aplicación para la bibliotecóloga. Hoy cada libro tiene un solo ejemplar en la base y, con la regla de 0 o 1 disponible, casi todo el catálogo queda en alerta; habría que cargar la cantidad real de ejemplares.
- **Calidad:** pruebas automáticas de los scripts y de la escritura del registro, y rotación de logs que no rompa el cálculo de stock, que necesita todo el historial.
