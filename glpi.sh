#!/bin/bash

# --- Fonction d'affichage d'information ---
function info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

# --- Fonction de configuration de MariaDB ---
function mariadb_configure() {
    info "Configuration de MariaDB..."
    sleep 1

    SLQROOTPWD=$(openssl rand -base64 48 | cut -c1-12 )
    SQLGLPIPWD=$(openssl rand -base64 48 | cut -c1-12 )

    systemctl start mariadb
    sleep 1

    # Suppression des comptes anonymes
    mysql -e "DELETE FROM mysql.user WHERE User = ''"
    mysql -e "DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
    mysql -e "DROP DATABASE test"
    mysql -e "FLUSH PRIVILEGES"

    # Création de la base GLPI et de l'utilisateur
    mysql -e "CREATE DATABASE glpi"
    mysql -e "CREATE USER 'glpi_user'@'localhost' IDENTIFIED BY '$SQLGLPIPWD'"
    mysql -e "GRANT ALL PRIVILEGES ON glpi.* TO 'glpi_user'@'localhost'"
    mysql -e "FLUSH PRIVILEGES"

    # Initialisation des informations de fuseaux horaires
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql mysql

    # Configuration du fuseau horaire
    dpkg-reconfigure -f noninteractive tzdata

    systemctl restart mariadb
    sleep 1

    mysql -e "GRANT SELECT ON mysql.time_zone_name TO 'glpi_user'@'localhost'"
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$SLQROOTPWD'"

    info "MariaDB configuré avec succès !"
    info "Mot de passe root: $SLQROOTPWD"
    info "Mot de passe de l'utilisateur GLPI: $SQLGLPIPWD"

    echo "Root Password: $SLQROOTPWD" > /root/glpi_db_passwords.txt
    echo "GLPI User Password: $SQLGLPIPWD" >> /root/glpi_db_passwords.txt
    chmod 600 /root/glpi_db_passwords.txt

    info "Les mots de passe sont sauvegardés dans /root/glpi_db_passwords.txt"
}

# --- Fonction d'installation de GLPI ---
function install_glpi() {
    info "Téléchargement et installation de la dernière version de GLPI..."

    apt-get install -y jq

    DOWNLOADLINK=$(curl -s https://api.github.com/repos/glpi-project/glpi/releases/latest | jq -r '.assets[0].browser_download_url')

    wget -O /tmp/glpi-latest.tgz $DOWNLOADLINK
    tar xzf /tmp/glpi-latest.tgz -C /var/www/html/

    touch /var/www/html/glpi/files/_log/php-errors.log
    chown -R www-data:www-data /var/www/html/glpi
    chmod -R 775 /var/www/html/glpi

    cat > /etc/apache2/sites-available/000-default.conf << EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi/public
    <Directory /var/www/html/glpi/public>
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    LogLevel warn
    ErrorLog \${APACHE_LOG_DIR}/error-glpi.log
    CustomLog \${APACHE_LOG_DIR}/access-glpi.log combined
</VirtualHost>
EOF

    echo "ServerSignature Off" >> /etc/apache2/apache2.conf
    echo "ServerTokens Prod" >> /etc/apache2/apache2.conf

    echo "*/2 * * * * www-data /usr/bin/php /var/www/html/glpi/front/cron.php &>/dev/null" > /etc/cron.d/glpi

    a2enmod rewrite
    systemctl restart apache2

    info "GLPI est installé. Accédez à l'interface via http://<votre-ip-serveur>"
}

# --- Fonction principale ---
function main() {
    info "Début de l'installation automatique de GLPI..."
    
    mariadb_configure
    install_glpi

    info "Installation terminée ! Accédez à http://<votre-ip-serveur> pour terminer la configuration."
}

# --- Exécution du script ---
main
