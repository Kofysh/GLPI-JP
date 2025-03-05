#!/bin/bash

set -e

# --- Configuration ---
DB_NAME="glpi_db"
DB_USER="glpi"
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c13)

GLPI_DIR="/opt/glpi"
GLPI_CONF_DIR="/etc/glpi"
GLPI_FILES_DIR="/var/lib/glpi"
GLPI_LOG_DIR="/var/log/glpi"

# --- Fonctions Utilitaires ---
msg_info() { echo -e "\e[94m[INFO]\e[0m $1"; }
msg_ok() { echo -e "\e[92m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[91m[ERREUR]\e[0m $1"; exit 1; }

run_cmd() {
    "$@"
    if [ $? -ne 0 ]; then
        msg_error "La commande suivante a échoué : $*"
    fi
}

cleanup() {
    rm -rf /opt/glpi-*.tgz
    apt-get -y autoremove
    apt-get -y autoclean
}

trap cleanup EXIT

# --- Installation des dépendances ---
msg_info "Installation des dépendances"
run_cmd apt-get update
run_cmd apt-get install -y curl git sudo mc apache2 \
    php8.2-{apcu,cli,common,curl,gd,imap,ldap,mysql,xmlrpc,xml,mbstring,bcmath,intl,zip,redis,bz2,soap} \
    php-cas libapache2-mod-php mariadb-server
msg_ok "Dépendances installées"

# --- Configuration de la base de données ---
msg_info "Configuration de la base de données"
mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql mysql
run_cmd mysql -u root -e "CREATE DATABASE $DB_NAME;"
run_cmd mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
run_cmd mysql -u root -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
run_cmd mysql -u root -e "GRANT SELECT ON \`mysql\`.\`time_zone_name\` TO '$DB_USER'@'localhost';"
run_cmd mysql -u root -e "FLUSH PRIVILEGES;"

cat <<EOF >~/glpi_db.creds
GLPI Database Credentials
Database: $DB_NAME
Username: $DB_USER
Password: $DB_PASS
EOF
chmod 600 ~/glpi_db.creds
msg_ok "Base de données configurée"

# --- Installation de GLPi ---
msg_info "Téléchargement et installation de GLPi"
cd /opt
RELEASE=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
wget -q "https://github.com/glpi-project/glpi/releases/download/${RELEASE}/glpi-${RELEASE}.tgz"
run_cmd tar -xzf glpi-${RELEASE}.tgz
cd $GLPI_DIR
run_cmd php bin/console db:install --db-name=$DB_NAME --db-user=$DB_USER --db-password=$DB_PASS --no-interaction
echo "$RELEASE" > /opt/glpi_version.txt
msg_ok "GLPi installé"

# --- Configuration Downstream ---
msg_info "Configuration downstream"
cat <<EOF >$GLPI_DIR/inc/downstream.php
<?php
define('GLPI_CONFIG_DIR', '/etc/glpi/');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
EOF

mv $GLPI_DIR/config $GLPI_CONF_DIR
mv $GLPI_DIR/files $GLPI_FILES_DIR
mv $GLPI_FILES_DIR/_log $GLPI_LOG_DIR

cat <<EOF >$GLPI_CONF_DIR/local_define.php
<?php
define('GLPI_VAR_DIR', '$GLPI_FILES_DIR');
define('GLPI_LOG_DIR', '$GLPI_LOG_DIR');
EOF
msg_ok "Fichiers de configuration déplacés"

# --- Permissions ---
msg_info "Mise à jour des permissions"
chown -R root:root $GLPI_DIR
chown -R www-data:www-data $GLPI_CONF_DIR $GLPI_FILES_DIR $GLPI_LOG_DIR
find $GLPI_DIR -type f -exec chmod 0644 {} \;
find $GLPI_DIR -type d -exec chmod 0755 {} \;
msg_ok "Permissions appliquées"

# --- Configuration Apache ---
msg_info "Configuration du site Apache"
cat <<EOF >/etc/apache2/sites-available/glpi.conf
<VirtualHost *:80>
    ServerName localhost
    DocumentRoot /opt/glpi/public

    <Directory /opt/glpi/public>
        Options -Indexes
        Require all granted
        RewriteEngine On
        RewriteCond %{HTTP:Authorization} ^(.+)$
        RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
EOF

run_cmd a2dissite 000-default.conf
run_cmd a2enmod rewrite
run_cmd a2ensite glpi.conf
systemctl reload apache2
msg_ok "Site Apache configuré"

# --- Configuration Cron ---
msg_info "Configuration du cron"
cat <<EOF >/etc/cron.d/glpi
* * * * * www-data php /opt/glpi/front/cron.php
EOF
chmod 644 /etc/cron.d/glpi
msg_ok "Cron configuré"

# --- Mise à jour des paramètres PHP ---
msg_info "Mise à jour des paramètres PHP"
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
PHP_INI="/etc/php/$PHP_VERSION/apache2/php.ini"

sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 20M/' $PHP_INI
sed -i 's/^post_max_size = .*/post_max_size = 20M/' $PHP_INI
sed -i 's/^max_execution_time = .*/max_execution_time = 60/' $PHP_INI
sed -i 's/^max_input_vars = .*/max_input_vars = 5000/' $PHP_INI
sed -i 's/^memory_limit = .*/memory_limit = 256M/' $PHP_INI
sed -i 's/^;\?session.cookie_httponly\s*=.*/session.cookie_httponly = On/' $PHP_INI

systemctl restart apache2
msg_ok "Paramètres PHP mis à jour"

msg_info "Nettoyage final"
cleanup
msg_ok "Installation terminée"

echo "GLPi est installé. Les identifiants de la base de données sont dans ~/glpi_db.creds"
