#!/bin/bash
#apt update && sudo apt install -y bash

#set -euo pipefail
set -e

##############################!/usr/bin/env bash

# Config – you can use custom values
#############################
NC_WEBROOT="/var/www/nextcloud"
NC_DATA="/var/nc-data"                 # buiten webroot
DB_NAME="nextcloud"
DB_USER="nc_user"
DB_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
REDIS_PASS="$(openssl rand -base64 24 | tr -d '=+/')"
PHP_VER="8.4"                          # Debian 13 standaard
DOMAIN="${DOMAIN:-}"                   # optioneel voor Let's Encrypt
EMAIL="${EMAIL:-}"                     # optioneel voor Let's Encrypt
APT_OPTS="-y -o Dpkg::Options::=--force-confnew"

#############################
# Root check
#############################
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)."; exit 1
fi

#############################
# Systeem packages
#############################
apt update
apt install $APT_OPTS ca-certificates lsb-release gnupg curl unzip tar \
  apache2 libapache2-mod-fcgid \
  mariadb-server \
  redis-server \
  php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-gd php${PHP_VER}-xml \
  php${PHP_VER}-zip php${PHP_VER}-curl php${PHP_VER}-mbstring php${PHP_VER}-intl \
  php${PHP_VER}-bz2 php${PHP_VER}-imagick php${PHP_VER}-gmp \
  php${PHP_VER}-mysql php${PHP_VER}-apcu php${PHP_VER}-redis \
  imagemagick ffmpeg

# Apache modules
a2enmod proxy proxy_fcgi setenvif rewrite headers env dir mime ssl http2
a2enconf php${PHP_VER}-fpm

#############################
# MariaDB – database & user
#############################
systemctl enable --now mariadb
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

#############################
# Redis hardenen
#############################
sed -i 's/^#* *supervised .*/supervised systemd/' /etc/redis/redis.conf
if ! grep -q '^requirepass ' /etc/redis/redis.conf; then
  echo "requirepass ${REDIS_PASS}" >> /etc/redis/redis.conf
else
  sed -i "s|^requirepass .*|requirepass ${REDIS_PASS}|" /etc/redis/redis.conf
fi
systemctl enable --now redis-server

#############################
# Nextcloud downloaden
#############################
mkdir -p "$NC_WEBROOT" "$NC_DATA"
cd /tmp

# Probeer latest.zip (kan soms niet beschikbaar zijn), anders val terug op 31.0.8
NC_ZIP="nextcloud-latest.zip"
if ! curl -fsSL -o "$NC_ZIP" "https://download.nextcloud.com/server/releases/latest.zip"; then
  echo "latest.zip niet beschikbaar, val terug op 31.0.8"
  NC_ZIP="nextcloud-31.0.8.zip"
  curl -fsSL -o "$NC_ZIP" "https://download.nextcloud.com/server/releases/nextcloud-31.0.8.zip"
fi

unzip -q "$NC_ZIP"
rsync -a nextcloud/ "$NC_WEBROOT"/
chown -R www-data:www-data "$NC_WEBROOT" "$NC_DATA"

#############################
# PHP tuning (FPM + CLI)
#############################
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

# APCu on (CLI optioneel)
echo "apc.enable_cli=1" > /etc/php/${PHP_VER}/mods-available/apcu.ini

systemctl restart php${PHP_VER}-fpm

#############################
# Apache vhost
#############################
cat >/etc/apache2/sites-available/nextcloud.conf <<'APACHE'
<VirtualHost *:80>
    ServerName _DEFAULT_
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud-access.log combined

    # PHP-FPM via proxy_fcgi
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.4-fpm.sock|fcgi://localhost/"
    </FilesMatch>
</VirtualHost>
APACHE

# ServerName invullen (of placeholder laten)
if [[ -n "${DOMAIN}" ]]; then
  sed -i "s/ServerName _DEFAULT_/ServerName ${DOMAIN}/" /etc/apache2/sites-available/nextcloud.conf
else
  sed -i "s/ServerName _DEFAULT_/# ServerName (vul domein in)/" /etc/apache2/sites-available/nextcloud.conf
fi

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite nextcloud
systemctl reload apache2

#############################
# Nextcloud eerste config (occ)
#############################
# Wacht tot FPM/socket klaar is
sleep 2

# Initial install via occ (command line installer)
sudo -u www-data php${PHP_VER} "${NC_WEBROOT}/occ" maintenance:install \
  --database "mysql" --database-name "${DB_NAME}" \
  --database-user "${DB_USER}" --database-pass "${DB_PASS}" \
  --admin-user "ncadmin" --admin-pass "$(openssl rand -base64 16)" \
  --data-dir "${NC_DATA}"

# Betere defaults: pretty URLs, caching, Redis, background jobs
NC_CONF="${NC_WEBROOT}/config/config.php"
sudo -u www-data php${PHP_VER} -r "
\$f='$NC_CONF';
\$cfg = include(\$f);
\$cfg['overwrite.cli.url'] = 'http://${DOMAIN:-localhost}';
\$cfg['htaccess.RewriteBase'] = '/';
\$cfg['memcache.local'] = '\\\\OC\\\\Memcache\\\\APCu';
\$cfg['memcache.locking'] = '\\\\OC\\\\Memcache\\\\Redis';
\$cfg['redis'] = ['host' => '127.0.0.1', 'port' => 6379, 'password' => '${REDIS_PASS}', 'timeout' => 1.5];
file_put_contents(\$f, \"<?php\\n\\nreturn \".var_export(\$cfg, true).\";\\n\");
"
sudo -u www-data php${PHP_VER} "${NC_WEBROOT}/occ" maintenance:update:htaccess
sudo -u www-data php${PHP_VER} "${NC_WEBROOT}/occ" background:cron

# Cron every 5 minutes for www-data
if ! crontab -u www-data -l >/dev/null 2>&1; then
  echo "no crontab for www-data yet"
fi
( crontab -u www-data -l 2>/dev/null || true; echo "*/5 * * * * php -f ${NC_WEBROOT}/cron.php" ) | crontab -u www-data -

#############################
# Let’s Encrypt (optioneel)
#############################
if [[ -n "${DOMAIN}" && -n "${EMAIL}" ]]; then
  apt install $APT_OPTS certbot python3-certbot-apache
  certbot --apache -d "${DOMAIN}" -m "${EMAIL}" --agree-tos --non-interactive --redirect
  # HTTP/2 al actief; OCSP stap overslaan
fi

#############################
# Permissions & restart
#############################
find "$NC_WEBROOT" -type d -exec chmod 750 {} \;
find "$NC_WEBROOT" -type f -exec chmod 640 {} \;
chown -R www-data:www-data "$NC_WEBROOT" "$NC_DATA"

systemctl restart apache2
systemctl restart php${PHP_VER}-fpm
systemctl restart redis-server

#############################
# Output
#############################
cat <<INFO

==========================================================
Nextcloud install .

URL:  http://${DOMAIN:-<server-ip>}/
DB:   ${DB_NAME}
User: ${DB_USER}
Pass: ${DB_PASS}

Redis password: ${REDIS_PASS}
Admin user: 'ncadmin' (wachtwoord staat in Nextcloud config: ${NC_WEBROOT}/config/config.php)
Data directory: ${NC_DATA}

If you added a domain & e-mail, then a Let's Encrypt certificate will be created & HTTPS wil be available.
==========================================================
INFO





