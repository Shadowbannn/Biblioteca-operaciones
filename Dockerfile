FROM php:8.5-apache

# Extensiones de la app (PDO/MySQL), PHP de producción, zona horaria y apache
RUN docker-php-ext-install pdo_mysql mysqli \
 && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && echo "date.timezone=America/Montevideo" > "$PHP_INI_DIR/conf.d/zz-zona-horaria.ini" \
 && echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \
 && echo "RedirectMatch ^/$ /carpeta2/inicioo.php" > /etc/apache2/conf-available/raiz.conf \
 && a2enconf servername raiz

# La app se publica en /carpeta2 porque las vistas usan esa ruta
COPY codigo/ /var/www/html/carpeta2/

# Permisos como en el servidor: carpetas 2750, archivos 640, grupo www-data.
# uploads/ y el registro de movimientos son escribibles por Apache y van en volúmenes.
RUN chown -R root:www-data /var/www/html/carpeta2 \
 && find /var/www/html/carpeta2 -type d -exec chmod 2750 {} + \
 && find /var/www/html/carpeta2 -type f -exec chmod 640 {} + \
 && mkdir -p /var/www/html/carpeta2/uploads /var/log/biblioteca \
 && chown www-data:www-data /var/www/html/carpeta2/uploads /var/log/biblioteca \
 && chmod 2770 /var/www/html/carpeta2/uploads \
 && chmod 750 /var/log/biblioteca

EXPOSE 80
