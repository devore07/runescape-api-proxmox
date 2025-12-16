#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# App metadata
APP="runescape-api-symfony"
APP_DISPLAY="RuneMetrics (runescape-api-symfony)"
REPO_URL="https://github.com/VincentPS/runescape-api-symfony.git"

# Default container settings (override via env vars like other scripts)
var_tags="${var_tags:-runescape,php,symfony}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"          # Debian 12 (Bookworm) is stable
var_unprivileged="${var_unprivileged:-1}"

# PHP version (configurable)
PHP_VERSION="${PHP_VERSION:-8.3}"

# Internal install paths
APP_DIR="/opt/runescape-api-symfony"
NGINX_SITE="/etc/nginx/sites-available/runescape-api-symfony"
PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"

header_info "$APP_DISPLAY"
variables
color
catch_errors

function update_script() {
  header_info
  msg_error "Update not implemented for this script yet."
  exit 1
}

function install_app() {
  msg_info "Updating OS packages"
  apt-get update -y
  apt-get upgrade -y
  msg_ok "Updated OS packages"

  msg_info "Adding Sury PHP repository"
  apt-get install -y ca-certificates curl gnupg lsb-release
  curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-sury.gpg
  echo "deb [signed-by=/usr/share/keyrings/php-sury.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php-sury.list
  apt-get update -y
  msg_ok "Added Sury PHP repository"

  msg_info "Installing dependencies"
  apt-get install -y \
    ca-certificates curl git unzip gnupg \
    nginx \
    postgresql postgresql-contrib \
    php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common \
    php${PHP_VERSION}-curl php${PHP_VERSION}-ftp php${PHP_VERSION}-intl \
    php${PHP_VERSION}-pgsql php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-zip \
    php${PHP_VERSION}-gd php${PHP_VERSION}-bcmath \
    nodejs npm
  msg_ok "Installed dependencies"

  # Composer (official installer)
  msg_info "Installing Composer"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || { msg_error "Failed to download Composer installer"; exit 1; }
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer || { msg_error "Failed to install Composer"; exit 1; }
  rm -f composer-setup.php
  msg_ok "Installed Composer"

  msg_info "Preparing PostgreSQL database"
  DB_NAME="app"
  DB_USER="app"
  DB_PASS="$(openssl rand -base64 24 | tr -d '=+/ ' | head -c 24)"
  # Detect PostgreSQL version
  PG_VERSION=$(sudo -u postgres psql -tAc "SELECT version();" | grep -oP 'PostgreSQL \K[0-9]+' || echo "15")

  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"

  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

  msg_ok "PostgreSQL database ready"

  msg_info "Cloning application repository"
  rm -rf "${APP_DIR}"
  git clone --depth 1 "${REPO_URL}" "${APP_DIR}" || { msg_error "Failed to clone repository"; exit 1; }
  msg_ok "Cloned repository"

  msg_info "Configuring Symfony environment"
  cd "${APP_DIR}" || { msg_error "Failed to enter ${APP_DIR}"; exit 1; }

  # Create .env.local (do not overwrite if user already created one)
  if [[ ! -f "${APP_DIR}/.env.local" ]]; then
    APP_SECRET="$(openssl rand -hex 32)"
    cat > "${APP_DIR}/.env.local" <<EOF
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=${APP_SECRET}

# Local PostgreSQL
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}?serverVersion=${PG_VERSION}&charset=utf8"
EOF
  fi
  msg_ok "Symfony environment configured"

  msg_info "Installing PHP dependencies (Composer)"
  composer install --no-dev --optimize-autoloader --no-interaction || { msg_error "Failed to install Composer dependencies"; exit 1; }
  msg_ok "Composer dependencies installed"

  msg_info "Running database migrations"
  php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration || true
  msg_ok "Migrations complete"

  msg_info "Building frontend assets"
  # Prefer deterministic installs if lock exists
  if [[ -f package-lock.json ]]; then
    npm ci --no-audit --no-fund || { msg_error "Failed to install npm dependencies"; exit 1; }
  else
    npm install --no-audit --no-fund || { msg_error "Failed to install npm dependencies"; exit 1; }
  fi

  # Try common production build script first; fall back to dev build if needed
  if npm run 2>&1 | grep -qE '\sbuild\s*$' || grep -q '"build"' package.json 2>/dev/null; then
    npm run build
    msg_ok "Assets built"
  elif npm run 2>&1 | grep -qE '\sdev\s*$' || grep -q '"dev"' package.json 2>/dev/null; then
    npm run dev
    msg_ok "Assets built"
  else
    msg_ok "No build script found, skipping asset build"
  fi

  msg_info "Setting permissions"
  chown -R www-data:www-data "${APP_DIR}/var" || true
  chmod -R 775 "${APP_DIR}/var" || true
  msg_ok "Permissions set"

  msg_info "Configuring Nginx"
  rm -f /etc/nginx/sites-enabled/default || true

  cat > "${NGINX_SITE}" <<'EOF_NGINX'
server {
  listen 80;
  server_name _;

  root ${APP_DIR}/public;
  index index.php;

  client_max_body_size 20M;

  location / {
    try_files $uri /index.php$is_args$args;
  }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${PHP_FPM_SOCK};
  }

  location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|webp|ttf|otf|woff|woff2)$ {
    expires 7d;
    access_log off;
    add_header Cache-Control "public";
    try_files $uri /index.php$is_args$args;
  }
}
EOF_NGINX
  
  # Replace variables in nginx config
  sed -i "s|\${APP_DIR}|${APP_DIR}|g" "${NGINX_SITE}"
  sed -i "s|\${PHP_FPM_SOCK}|${PHP_FPM_SOCK}|g" "${NGINX_SITE}"

  ln -sf "${NGINX_SITE}" /etc/nginx/sites-enabled/runescape-api-symfony

  nginx -t || { msg_error "Nginx configuration test failed"; exit 1; }
  systemctl enable --now php${PHP_VERSION}-fpm
  systemctl restart nginx
  msg_ok "Nginx configured and restarted"

  msg_info "Creating optional Symfony scheduler consumer service (disabled by default)"
  cat > /etc/systemd/system/symfony-scheduler-consumer.service <<EOF
[Unit]
Description=Symfony Messenger Consumer (scheduler_update_player_data)
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/php ${APP_DIR}/bin/console messenger:consume scheduler_update_player_data --time-limit=0 --memory-limit=256M
Restart=always
RestartSec=5
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  msg_ok "Optional service created (enable with: systemctl enable --now symfony-scheduler-consumer)"
  
  # Store credentials in root-only file for convenience
  cat > /root/"${APP}_db_credentials.txt" <<EOF
Database: ${DB_NAME}
User: ${DB_USER}
Password: ${DB_PASS}
DSN: postgresql://${DB_USER}:********@127.0.0.1:5432/${DB_NAME}?serverVersion=${PG_VERSION}&charset=utf8
EOF
  chmod 600 /root/"${APP}_db_credentials.txt"
}

start
build_container
description

msg_info "Installing ${APP_DISPLAY}"
install_app
msg_ok "Installed ${APP_DISPLAY}"

echo -e "\n${INFO}${YW}Access:${CL} http://${IP}/"
echo -e "${INFO}${YW}DB credentials:${CL} /root/${APP}_db_credentials.txt"
echo -e "${INFO}${YW}Optional scheduler consumer:${CL} systemctl enable --now symfony-scheduler-consumer\n"
