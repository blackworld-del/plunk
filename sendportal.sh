#!/bin/bash

# Exit on any error
set -e

# Variables (modify these as needed)
DOMAIN="93.185.106.224"  # Replace with your domain or server IP (e.g., 192.168.1.100)
APP_DIR="/var/www/sendportal"
DB_NAME="sendportal"
DB_USER="sendportal_user"
DB_PASSWORD="sendportal"  # Replace with a secure password
ADMIN_EMAIL="admin@example.com"
ADMIN_PASSWORD="sendportal"  # Replace with a secure password

# Log file
LOG_FILE="/tmp/sendportal_install.log"
echo "Logging installation to $LOG_FILE"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    log "This script must be run as root or with sudo."
    exit 1
fi

# Update system
log "Updating system..."
apt update && apt upgrade -y >> "$LOG_FILE" 2>&1

# Install dependencies
log "Installing dependencies..."
apt install -y php php-cli php-fpm php-mysql php-pgsql php-sqlite3 php-gd php-curl php-mbstring php-xml php-zip php-bcmath unzip git nginx curl mysql-server nodejs npm redis-server supervisor >> "$LOG_FILE" 2>&1

# Install Composer
log "Installing Composer..."
curl -sS https://getcomposer.org/installer | php >> "$LOG_FILE" 2>&1
mv composer.phar /usr/local/bin/composer

# Secure MySQL installation (non-interactive)
log "Securing MySQL..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';" >> "$LOG_FILE" 2>&1
mysql -e "DELETE FROM mysql.user WHERE User='';" >> "$LOG_FILE" 2>&1
mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" >> "$LOG_FILE" 2>&1
mysql -e "DROP DATABASE IF EXISTS test;" >> "$LOG_FILE" 2>&1
mysql -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1

# Create database and user
log "Creating MySQL database and user..."
mysql -e "CREATE DATABASE $DB_NAME;" >> "$LOG_FILE" 2>&1
mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" >> "$LOG_FILE" 2>&1
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" >> "$LOG_FILE" 2>&1
mysql -e "FLUSH PRIVILEGES;" >> "$LOG_FILE" 2>&1

# Clone SendPortal repository
log "Cloning SendPortal repository..."
cd /var/www
git clone https://github.com/mettle/sendportal.git >> "$LOG_FILE" 2>&1
chown -R $USER:$USER sendportal
cd sendportal
git checkout v2 >> "$LOG_FILE" 2>&1

# Install PHP dependencies
log "Installing PHP dependencies..."
composer install --no-dev --optimize-autoloader >> "$LOG_FILE" 2>&1

# Configure environment file
log "Configuring .env file..."
cp .env.example .env
sed -i "s|APP_URL=.*|APP_URL=http://$DOMAIN|" .env
sed -i "s|DB_DATABASE=.*|DB_DATABASE=$DB_NAME|" .env
sed -i "s|DB_USERNAME=.*|DB_USERNAME=$DB_USER|" .env
sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|" .env
sed -i "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env

# Generate application key
log "Generating application key..."
php artisan key:generate >> "$LOG_FILE" 2>&1

# Run database migrations and seed
log "Running database migrations..."
php artisan migrate --force >> "$LOG_FILE" 2>&1

# Create admin user (non-interactive)
log "Creating admin user..."
php artisan sp:setup --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD" --no-interaction >> "$LOG_FILE" 2>&1

# Install frontend dependencies
log "Installing frontend dependencies..."
npm install >> "$LOG_FILE" 2>&1
npm run prod >> "$LOG_FILE" 2>&1

# Configure Nginx
log "Configuring Nginx..."
cat > /etc/nginx/sites-available/sendportal <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    root $APP_DIR/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

ln -s /etc/nginx/sites-available/sendportal /etc/nginx/sites-enabled/ >> "$LOG_FILE" 2>&1
nginx -t >> "$LOG_FILE" 2>&1
systemctl restart nginx >> "$LOG_FILE" 2>&1

# Set permissions
log "Setting file permissions..."
chown -R www-data:www-data $APP_DIR
chmod -R 775 $APP_DIR/storage
chmod -R 775 $APP_DIR/bootstrap/cache

# Configure Laravel scheduler
log "Configuring Laravel scheduler..."
(crontab -l 2>/dev/null; echo "* * * * * cd $APP_DIR && php artisan schedule:run >> /dev/null 2>&1") | crontab -

# Configure Horizon for queue processing
log "Configuring Horizon..."
php artisan horizon:install >> "$LOG_FILE" 2>&1
cat > /etc/supervisor/conf.d/horizon.conf <<EOL
[program:horizon]
process_name=%(program_name)s
command=php $APP_DIR/artisan horizon
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=$APP_DIR/storage/logs/horizon.log
EOL

supervisorctl reread >> "$LOG_FILE" 2>&1
supervisorctl update >> "$LOG_FILE" 2>&1
supervisorctl start horizon >> "$LOG_FILE" 2>&1

# Final message
log "Installation complete!"
echo "SendPortal is installed at http://$DOMAIN"
echo "Admin login: $ADMIN_EMAIL / $ADMIN_PASSWORD"
echo "Next steps:"
echo "1. Configure email service in $APP_DIR/.env (e.g., SES, Mailgun)."
echo "2. Set up HTTPS with Let's Encrypt (e.g., sudo apt install certbot python3-certbot-nginx)."
echo "3. Check logs in $LOG_FILE for errors."
