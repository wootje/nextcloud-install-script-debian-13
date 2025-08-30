#!/bin/sh
# POSIX /bin/sh script voor Debian 13 (Trixie) – Apache + PHP-FPM + MariaDB + Redis + APCu
set -eu

###############################################################################
# Config
###############################################################################
NC_WEBROOT="/var/www/nextcloud"
NC_DATA="/var/nc-data"               # buiten webroot
DB_NAME="nextcloud"
DB_USER="nc_user"
# simpele randoms zonder bashisms
DB_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
REDIS_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
PHP_VER="8.4"                         # Debian 13 standaard
DOMAIN="${DOMAIN:-}"                  # optioneel (HTTPS via Let's Encrypt)
EMAIL="${EMAIL:-}"                    # optioneel
APT_OPTS="-y -o Dpkg::Options::=--force-confnew"

###############################################################################
# Root check
###############################################################################
if [ "$(id -u)" -ne 0 ]; then
  echo "Run dit script als root (sudo)." >&2
  exit 1
fi

###############################################################################
# Pakketten
###############################################################################
apt update
apt install $APT_OPTS ca-certificates lsb-release gnupg curl unzip tar openssl \
  apache2 libapache2-mod-fcgid \
  mariadb-server \
  redis-server \
  php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-gd php${PHP_VER}-xml \
  php${PHP_VER}-zip php${PHP_VER}-curl php${PHP_VER}-mbstring php${PHP_VER}-intl \
  php${PHP_VER}-bz2 php${PHP_VER}-imagick php${PHP_VER}-gmp \
  php${PHP_VER}-mysql php${PHP_VER}-apcu php${PHP_VER}-redis \
  imagemagick ffmpeg

# Apache modules
a2enmod proxy proxy_fcgi setenvif rewrite headers env dir mime ssl http2 >/dev/null
a2enconf php${PHP_VER}-fpm >/dev/null || true

###############################################################################
# MariaDB – database & user
###############################################################################
systemctl enable --now mariadb
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

###############################################################################
# Redis hardenen
###############################################################################
REDIS_CONF="/etc/redis/redis.conf"
# supervised -> systemd
if grep -q '^#\? *supervised ' "$REDIS_CONF"; then
  sed -i 's/^#\? *supervised .*/supervised systemd/' "$REDIS_CONF"
else
  printf "\n%s\n" "supervised systemd" >> "$REDIS_CONF"
fi
# requirepass zetten
if grep -q '^requirepass ' "$REDIS_CONF"; then
  sed -i "s|^requirepass .*|requirepass ${REDIS_PASS}|" "$REDIS_CONF"
else
  printf "%s\n" "requirepass ${REDIS_PASS}" >> "$REDIS_CONF"
fi
systemctl enable --now redis-server

###############################################################################
# Nextcloud downloaden
###############################################################################
mkdir -p "$NC_WEBROOT" "$NC_DATA"
cd /tmp

NC_ZIP="nextcloud-latest.zip"
if ! curl -fsSL -o "$NC_ZIP" "https://download.nextcloud.com/server/releases/latest.zip"; then
  echo "latest.zip niet beschikbaar, val terug op 31.0.8"
  NC_ZIP="nextcloud-31.0.8.zip"
  curl -fsSL -o "$NC_ZIP" "https://download.nextcloud.com/server/releases/nextcloud-31.0.8.zip"
fi

unzip -q "$NC_ZIP"
# kopieer zonder rsync (breder aanwezig)
cp -a nextcloud/. "$NC_WEBROOT"/
chown -R www-data:www-data "$NC_WEBROOT" "$NC_DATA"

###############################################################################
# PHP tuning
###############################################################################
PHP_INI_FPM="/etc/php/${PHP_VER}/fpm/php.ini"
PHP_INI_CLI="/etc/php/${PHP_VER}/cli/php.ini"
for INI in "$PHP_INI_FPM" "$PHP_INI_CLI"; do
  sed -i 's/^;*memory_limit.*/memory_limit = 512M/' "$INI"
  sed -i 's/^;*upload_max_filesize.*/upload_max_filesize = 2G/' "$INI"
  sed -i 's/^;*post_max_size.*/post_max_size = 2G/' "$INI"
  sed -i 's|^;*opcache.enable=.*|opcache.enable=1|' "$INI"
  sed -i 's|^;*opcache.enable_cli=.*|opcache.enable_cli=1|' "$INI"
  sed -i 's|^;*opcache.interned_strings_buffer=.*|opcache.interned_strings_buffer=16|' "$INI"
  sed -i 's|^;*opcache.max_accelerated_files=.*|opcache.max_accelerated_files=10000|' "$INI"
  sed -i 's|^;*opcache.memory_consumption=.*|opcache.memory_consumption=256|' "$INI"
  sed -i 's|^;*opcache.save_comments=.*|opcache.save_comments=1|' "$INI"
done
# APCu CLI
echo "apc.enable_cli=1" > /etc/php/${PHP_VER}/mods-available/apcu.ini
systemctl restart php${PHP_VER}-fpm

###############################################################################
# Apache vhost
###############################################################################
VHOST="/etc/apache2/sites-available/nextcloud.conf"
cat >"$VHOST" <<APACHE
<VirtualHost *:80>
    $( [ -n "$DOMAIN" ] && printf "ServerName %s\n" "$DOMAIN" || printf "%s\n" "# ServerName (vul domein in)" )
    DocumentRoot ${NC_WEBROOT}

    <Directory ${NC_WEBROOT}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-access.log combined

    <FilesMatch \\.php$>
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm.sock|fcgi://localhost/"
    </FilesMatch>
</VirtualHost>
APACHE

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite nextcloud >/dev/null
systemctl reload apache2

###############################################################################
# Nextcloud eerste config (occ)
###############################################################################
# kleine pauze zodat FPM/socket klaar is
sleep 2

ADMIN_PASS="$(openssl rand -base64 16 | tr -d '=+/')"
OCC="runuser -u www-data -- php${PHP_VER} ${NC_WEBROOT}/occ"

# Install
runuser -u www-data -- php${PHP_VER} "${NC_WEBROOT}/occ" maintenance:install \
  --database "mysql" --database-name "${DB_NAME}" \
  --database-user "${DB_USER}" --database-pass "${DB_PASS}" \
  --admin-user "ncadmin" --admin-pass "${ADMIN_PASS}" \
  --data-dir "${NC_DATA}"

# Aanbevolen settings via occ (geen PHP -r nodig)
$OCC config:system:set overwrite.cli.url --value "http://${DOMAIN:-localhost}"
$OCC config:system:set htaccess.RewriteBase --value "/"
$OCC config:system:set memcache.local --value "\\OC\\Memcache\\APCu"
$OCC config:system:set memcache.locking --value "\\OC\\Memcache\\Redis"
$OCC config:system:set redis host --value "127.0.0.1"
$OCC config:system:set redis port --value "6379" --type integer
$OCC config:system:set redis password --value "${REDIS_PASS}"
$OCC config:system:set redis timeout --value "1.5" --type float
$OCC maintenance:update:htaccess
$OCC background:cron

# Cron elke 5 minuten voor www-data
if crontab -u www-data -l >/dev/null 2>&1; then
  ( crontab -u www-data -l; echo "*/5 * * * * php -f ${NC_WEBROOT}/cron.php" ) | crontab -u www-data -
else
  echo "*/5 * * * * php -f ${NC_WEBROOT}/cron.php" | crontab -u www-data -
fi

###############################################################################
# Let's Encrypt (optioneel)
###############################################################################
if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
  apt install $APT_OPTS certbot python3-certbot-apache
  certbot --apache -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect || true
fi

###############################################################################
# Rechten en services
###############################################################################
find "$NC_WEBROOT" -type d -exec chmod 750 {} \;
find "$NC_WEBROOT" -type f -exec chmod 640 {} \;
chown -R www-data:www-data "$NC_WEBROOT" "$NC_DATA"

systemctl restart apache2
systemctl restart php${PHP_VER}-fpm
systemctl restart redis-server

###############################################################################
# Output
###############################################################################
cat <<INFO

==========================================================
Nextcloud installatie voltooid.

URL:  http://${DOMAIN:-<server-ip>}/
DB:
  name: ${DB_NAME}
  user: ${DB_USER}
  pass: ${DB_PASS}

Redis password: ${REDIS_PASS}

Nextcloud admin:
  user: ncadmin
  pass: ${ADMIN_PASS}

Data directory: ${NC_DATA}
(HTTPS via Let's Encrypt geconfigureerd als DOMAIN/EMAIL waren gezet.)
==========================================================
INFO
