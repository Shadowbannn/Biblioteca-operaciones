# Ficha Técnica del Servidor - BiblioTech

Proyecto: BiblioTech (sistema de biblioteca) · Equipo: Quantum Dev · UTU - Administración de Sistemas Operativos · 2.ª entrega

Los datos de esta ficha fueron relevados directamente del servidor el 07/11/2026 (script de solo lectura `recopilar_ficha.sh`) y actualizados el 08/11/2026 con el registro de movimientos de la aplicación.

## 1. Identificación y red

| Dato | Valor |
|---|---|
| Sistema operativo | Ubuntu 26.04.1 LTS |
| Entorno | WSL2 (Windows Subsystem for Linux) |
| Kernel | 6.18.54.1-microsoft-standard-WSL2 |
| Arquitectura | x86_64 |
| Nombre del equipo | Thony |
| Recursos | 4 núcleos, 3,8 GiB de memoria, disco de 1007 GB (1 % usado) |
| Zona horaria | America/Montevideo |
| Dirección IP (eth0) | 172.27.155.100/20 (red interna de WSL2; la asigna Windows y puede cambiar al reiniciar) |
| Puerto SSH | 22/TCP |
| Puerto web | 80/TCP (HTTP) |
| Puerto base de datos | 3306/TCP, solo en 127.0.0.1 (no accesible desde la red) |

Acceso a la aplicación: `http://localhost/carpeta2/inicioo.php` desde Windows, o `http://172.27.155.100/carpeta2/inicioo.php` usando la IP actual de WSL2.

### Justificación del entorno y de la red

- **Máquina virtual:** WSL2 ejecuta un kernel Linux real dentro de una máquina virtual liviana de Windows (Hyper-V). Por eso el servidor se comporta como un Ubuntu Server: usa `systemd`, servicios, usuarios, permisos y cron reales. Elegimos WSL2 en lugar de VirtualBox porque ya viene integrado en Windows, arranca más rápido y consume menos recursos de las computadoras del equipo.
- **Red:** el modo de red es NAT. La máquina virtual recibe una IP privada (172.27.155.100) en un adaptador virtual de Windows, no es visible desde otras computadoras y Windows la alcanza por `localhost`. Para un servidor de pruebas y desarrollo esto es suficiente y más seguro que exponerlo a la red del centro.

## 2. Software instalado

| Componente | Versión |
|---|---|
| Apache HTTP Server | 2.4.66 (con `mod_php`) |
| PHP | 8.5.4 |
| MariaDB | 11.8.6 |
| OpenSSH | 10.2p1 (OpenSSL 3.5.5) |
| cron | 3.0pl1-200ubuntu1 |
| rsync | 3.4.1 |

## 3. Servicios activos y arranque

| Servicio | Estado | Habilitado al arranque |
|---|---|---|
| apache2 | activo | sí |
| mariadb | activo | sí |
| cron | activo | sí |
| ssh.socket | activo | sí (arranca `sshd` bajo demanda al recibir una conexión) |
| ssh (sshd) | activo | no directamente: lo inicia `ssh.socket`, que es el mecanismo por defecto de Ubuntu |

Comprobación: después de apagar y volver a encender el equipo, `apache2`, `mariadb`, `cron` y `ssh.socket` quedaron activos sin intervención manual, y la aplicación respondió HTTP 200.

## 4. Usuarios, grupos y roles

| Usuario | UID | Rol en el equipo | Grupos | Privilegios |
|---|---|---|---|---|
| thony | 1000 | Anthony Silva: desarrollo full stack y team leader | sudo, biblioteca-dev | Administrador (único miembro de `sudo`) |
| walter | 1001 | Walter Montejo: full stack y base de datos | biblioteca-dev, biblioteca-bd | Sin `sudo`; puede leer y escribir en `respaldos/` |
| jose | 1002 | Jose Palermo: full stack e interfaz | biblioteca-dev | Sin `sudo`; trabaja sobre código, datos, docs y scripts |
| www-data | 33 | Usuario del servicio web (Apache/PHP) | www-data | Sin shell de acceso (`nologin`) |
| root | 0 | Administración del sistema | root | Acceso por SSH deshabilitado |

Grupos del proyecto:

- `biblioteca-dev` (GID 1001): thony, walter, jose. Acceso de trabajo a la carpeta del proyecto y permiso de ingreso por SSH.
- `biblioteca-bd` (GID 1002): walter. Responsable de los respaldos de la base de datos.

## 5. Acceso remoto (SSH)

Configuración propia en `/etc/ssh/sshd_config.d/10-biblioteca.conf`. Valores efectivos verificados con `sshd -T`:

| Parámetro | Valor | Motivo |
|---|---|---|
| PermitRootLogin | no | root no puede entrar por SSH |
| AllowGroups | biblioteca-dev | solo el equipo del proyecto puede conectarse |
| MaxAuthTries | 3 | limita los intentos de autenticación |
| LoginGraceTime | 30 | tiempo máximo para autenticarse (segundos) |
| PermitEmptyPasswords | no | no se admiten contraseñas vacías |
| X11Forwarding | no | sin reenvío gráfico innecesario |
| ClientAliveInterval / CountMax | 300 / 2 | cierra sesiones inactivas |
| PubkeyAuthentication | yes | autenticación por clave habilitada |
| PasswordAuthentication | yes | habilitada por ahora (mejora pendiente: usar solo claves) |

Evidencia: el intento de ingreso de `root` por SSH fue rechazado (`Permission denied`, con tres `Failed password for root` registrados en `journalctl -u ssh`).

## 6. Servidor web y aplicación

- Aplicación desplegada en `/var/www/biblioteca`, publicada con `Alias /carpeta2` mediante `/etc/apache2/conf-available/carpeta2.conf` (habilitada).
- Se desactiva el listado de directorios (`Options -Indexes`) y `AllowOverride None`.
- La carpeta `uploads/` es escribible por `www-data`, pero no se permite ejecutar archivos `.php`, `.phtml` ni `.phar` dentro de ella.
- Las credenciales de la base de datos no están dentro de la aplicación web: se leen de `/etc/biblioteca/db.conf`.
- La aplicación registra cada movimiento de libros (préstamo, devolución, reserva) en `/var/log/biblioteca/movimientos.log`, mediante `includes/registro_movimientos.php`. Escribe solo después de que la base de datos confirma el cambio.
- Despliegue repetible con `scripts/desplegar.sh`: copia el código desde `codigo/` con `rsync` (sin `.git`, sin `BD/`, sin `uploads/`), ajusta permisos, valida la configuración de Apache, recarga el servicio y prueba las URL principales.

## 7. Base de datos

- Motor: MariaDB 11.8.6, escuchando solo en `127.0.0.1:3306`.
- Base de datos: `biblioteca2` (≈ 4,7 MB de datos e índices).
- Tablas: `libros`, `socios`, `usuarios`, `prestamos`, `juegos`, `proyectos`, `prestamosjuegos`, `prestamosproyecto`, `notificaciones`, `solicitudes_libros`, `solicitudes_juegos`, `solicitudes_proyectos`.
- Cantidad aproximada de filas al relevar: libros 9939, proyectos 159, juegos 82, notificaciones 15, préstamos 8, socios 5, usuarios 5. Las cifras son estimaciones del motor; el conteo exacto lo realiza `chequeo.sh`.

Cuentas de base de datos (principio de mínimo privilegio):

| Cuenta | Uso | Permisos sobre `biblioteca2` |
|---|---|---|
| biblioteca_app | la aplicación web | SELECT, INSERT, UPDATE, DELETE |
| biblioteca_respaldo | respaldo, exportación y chequeo | SELECT, LOCK TABLES, SHOW VIEW (solo lectura) |
| root | administración local | acceso solo desde el propio servidor |

## 8. Ubicación de componentes y permisos

| Ruta | Contenido | Propietario:grupo | Permisos |
|---|---|---|---|
| `/home/thony/Biblioteca/` | raíz del proyecto | thony:biblioteca-dev | 2750 |
| `.../codigo/` | copia de trabajo del código (con Git) | thony:biblioteca-dev | 2750 |
| `.../datos/` | `catalogo.csv`, `movimientos.log` (copias para el analizador) | thony:biblioteca-dev | 2750 (archivos 640) |
| `.../docs/` | documentación y evidencias | thony:biblioteca-dev | 2750 |
| `.../scripts/` | scripts de administración | thony:biblioteca-dev | 2750 (scripts 750) |
| `.../logs/` | registros de los scripts | thony:biblioteca-dev | 2750 (archivos 640) |
| `.../respaldos/` | respaldos `.tar.gz` y `.sha256` | thony:biblioteca-bd | 2770 (archivos 640) |
| `.../.respaldo.cnf` | credencial de solo lectura de la base | thony:biblioteca-bd | 640 |
| `/var/www/biblioteca/` | aplicación desplegada | thony:www-data | 2750 (archivos 640) |
| `/var/www/biblioteca/uploads/` | archivos subidos por usuarios | www-data:www-data | 775 |
| `/var/log/biblioteca/` | registro de movimientos de la aplicación | www-data:biblioteca-dev | 2750 |
| `/var/log/biblioteca/movimientos.log` | movimientos que escribe la aplicación | www-data:biblioteca-dev | 640 |
| `/etc/biblioteca/db.conf` | credenciales de la aplicación | root:www-data | 640 (carpeta 750) |

Notas: el bit `s` (setgid, valor 2 en 2750/2770) hace que los archivos nuevos hereden el grupo de la carpeta. `/home/thony` tiene 750 y una ACL que da solo permiso de paso (`--x`) al grupo `biblioteca-dev`, para que el equipo llegue a la carpeta del proyecto sin listar el resto del home.

## 9. Tareas programadas (cron del usuario thony)

| Frecuencia | Tarea | Descripción |
|---|---|---|
| cada 30 min (:00 y :30) | `exportar_datos.sh` | genera `datos/catalogo.csv` desde la base de datos y copia el registro de la aplicación a `datos/movimientos.log` |
| cada 30 min (:05 y :35) | `analizador.sh alertas` | actualiza `logs/alertas.log` con alertas de stock, libros dormidos y más prestados |
| diaria, 02:00 | `respaldo.sh` | respaldo completo con verificación y rotación |
| cada hora (:40) | `chequeo.sh` | verificación integral del servidor y la aplicación |

Todas se ejecutan con `umask 027` y su salida se agrega a `logs/cron.log`.

## 10. Política de respaldos

- Contenido: volcado de la base de datos (`bd/biblioteca2.sql`), código (sin `.git`), datos, documentación, scripts y `uploads/`.
- Formato: `respaldos/respaldo_AAAA-MM-DD_HH-MM-SS.tar.gz` más su suma de control `.sha256`.
- Verificación: integridad de gzip/tar y comprobación SHA-256 en cada ejecución; el chequeo horario controla que el último respaldo tenga menos de 26 horas.
- Restauración probada: `scripts/probar_restauracion.sh` carga el último respaldo en una base temporal y compara los datos con la base real (libros, socios, usuarios, préstamos, juegos, proyectos y cantidad de tablas).
- Retención: se conservan los últimos 7 respaldos.
- Tamaño del último respaldo relevado: 43 MB.

## 11. Registros (logs)

En `/home/thony/Biblioteca/logs/`: `desplegar.log`, `respaldo.log`, `chequeo.log`, `exportar.log`, `errores.log` (errores del analizador), `alertas.log` y `cron.log`. El registro de movimientos de la aplicación está en `/var/log/biblioteca/movimientos.log`. Además, el intento de acceso de root por SSH y la actividad de cron quedan en el diario del sistema (`journalctl -u ssh`, `journalctl -u cron`).

Formato del registro de movimientos (una línea por evento): `2026-11-08 04:21:17 PRESTAMO libro=L04216 usuario=A011`.

## 12. Limitaciones conocidas

- Al ser WSL2, el servidor está activo solo mientras la instancia de WSL esté en ejecución. Si Windows cierra la instancia por inactividad, cron no se ejecuta hasta que se vuelva a abrir una terminal de Ubuntu.
- La IP 172.27.155.100 pertenece a la red virtual de WSL2 y puede cambiar; por eso se recomienda acceder desde Windows por `localhost`.
- El registro de movimientos de la aplicación comenzó con los 9 movimientos reconstruidos una única vez desde los préstamos existentes (la tabla `prestamos` guarda solo el estado actual). Desde entonces, cada movimiento lo escribe la aplicación al guardar un préstamo en el formulario de préstamos.
- Cada libro de la base tiene un solo ejemplar. Con la regla de la consigna (alerta con 0 o 1 ejemplar disponible, `UMBRAL_STOCK=1` por defecto), casi todo el catálogo queda en alerta de stock; `UMBRAL_STOCK=0` limita la alerta a los libros sin ejemplares.
- El acceso SSH por contraseña sigue habilitado; como mejora se propone pasar a autenticación solo por clave.
