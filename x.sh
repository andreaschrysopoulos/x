#!/bin/sh
#
# Server management script for containerized WordPress stacks (nginx, mariadb, php-fpm)
# behind a containerized reverse proxy (nginx)
# v0.1 : 26/08/2025
#
# Prerequisites:
#  - Docker installed
#  - Acme.sh is installed on root


set -e

# ---- args & directive -------------------------------------------------------

if [ "$#" -ne 2 ]; then
  printf '%s\n' "Invalid arguments." >&2
  printf '%s\n' "Usage: x [up|down|new|rm|export-core|export-content|export-db|export|purge-cache] [website.com]" >&2
  exit 1
fi

case "$1" in
  up|down|new|rm|export-content|export-core|export-db|export|purge-cache) ;;
  *)
    printf 'Invalid directive: %s\n' "$1" >&2
    exit 1
    ;;
esac

DIRECTIVE=$1

# Convert CLI website token to a safe folder/service name.
# Replace '-' with '--' and '.' with '-' (reverse mapping possible if needed).
cli_to_dir() {
  # POSIX: no 'local'
  input=$1
  out=$(printf '%s' "$input" \
        | sed -e 's/-/--/g' \
              -e 's/\./-/g')
  printf '%s\n' "$out"
}

WEBSITE_URL=$2
WEBSITE_FOLDER=$(cli_to_dir "$WEBSITE_URL")
WEBSITE_NGINX_CONF="${WEBSITE_FOLDER}/nginx/conf.d/default.conf"
GATEWAY_NETWORK="${WEBSITE_FOLDER}_gateway-nginx"
GATEWAY_NGINX_CONF="gateway/conf.d/${WEBSITE_FOLDER}.conf"

# ---- directive: up ----------------------------------------------------------

if [ "$DIRECTIVE" = 'up' ]; then

  # Check project folder exists (gateway handled below)
  if [ "$WEBSITE_FOLDER" != "gateway" ] && [ ! -d "$WEBSITE_FOLDER" ]; then
    printf 'Can'\''t find %s/\n' "$WEBSITE_FOLDER"
    exit 1
  fi

  # Bring up gateway itself
  if [ "$WEBSITE_FOLDER" = "gateway" ]; then
    printf '%s\n' "Bringing up gateway..."
    yamls="-f gateway/compose.yaml"
    # Include all extra YAMLs if any
    for y in gateway/*.yaml; do
      [ -e "$y" ] || continue
      printf 'Using YAML: %s\n' "$y"
      yamls="$yamls -f $y"
    done
    if ! docker compose $yamls up -d >/dev/null; then
      printf '%s\n' "Failed to bring up gateway ❌" >&2
      exit 1
    fi
    exit 0
  fi

  # Ensure a gateway project exists
  if [ ! -d "gateway" ]; then
    printf '%s\n' "Gateway not found. Creating new gateway..."
    x new gateway
  fi

  # Ensure SSL certs exist, otherwise re-issue them
  if [ ! -e "/srv/ssl/$WEBSITE_URL/fullchain.crt" ] || [ ! -e "/srv/ssl/$WEBSITE_URL/private.key" ]; then

    printf '%s\n' "SSL certificates not found. Issuing new certificates..."

    # Nuke project SSL cert directory to clean up
    sudo rm -rf -- "/srv/ssl/$WEBSITE_URL"

    # Make sure gateway is up to serve the challenge
    printf '%s\n' "Making sure gateway is up..."
    x up gateway

    # Recreate project SSL cert directory
    sudo mkdir "/srv/ssl/$WEBSITE_URL"

    # Issue new SSL certificates
    printf '%s\n' "Issuing and installing SSL certificates..."
    sudo su - root -c "
      WEBSITE_URL='$WEBSITE_URL'
      /root/.acme.sh/acme.sh --issue -d \"\$WEBSITE_URL\" -w /srv/acme --force &&
      /root/.acme.sh/acme.sh --install-cert -d \"\$WEBSITE_URL\" \
        --fullchain-file \"/srv/ssl/\$WEBSITE_URL/fullchain.crt\" \
        --key-file       \"/srv/ssl/\$WEBSITE_URL/private.key\" \
        --reloadcmd      'docker exec gateway nginx -s reload'
    "

  fi

  # Create/ensure gateway override YAML for unique network
  if [ -f "gateway/${WEBSITE_FOLDER}.yaml" ]; then
    printf '%s\n' "Override YAML already exists."
  else
    printf '%s\n' "Adding override YAML to gateway..."
    cat <<EOF > "gateway/${WEBSITE_FOLDER}.yaml"
  services:
    gateway:
      networks:
        - ${GATEWAY_NETWORK}
  networks:
    ${GATEWAY_NETWORK}:
      external: true
EOF
  fi

  # Create gateway server config if missing
  if [ -f "$GATEWAY_NGINX_CONF" ]; then
    printf 'Config for %s already exists.\n' "$WEBSITE_FOLDER"
  else
    printf '%s\n' "Creating project config file..."
    cat <<EOF > "$GATEWAY_NGINX_CONF"
server {
  listen 443 ssl;
  listen [::]:443 ssl;

  server_name $WEBSITE_URL;

  ssl_certificate     /etc/nginx/ssl/$WEBSITE_URL/fullchain.crt;
  ssl_certificate_key /etc/nginx/ssl/$WEBSITE_URL/private.key;

  location / {
    proxy_pass http://${WEBSITE_FOLDER}_nginx;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  fi

  # Ensure unique gateway network exists
  if docker network inspect "$GATEWAY_NETWORK" >/dev/null 2>&1; then
    printf '%s\n' "Unique gateway network already exists."
  else
    printf '%s\n' "Creating unique gateway network..."
    if ! docker network create "$GATEWAY_NETWORK" >/dev/null; then
      printf '%s\n' "Failed to create gateway network ❌" >&2
      exit 1
    fi
  fi

  # Compose up the project
  printf '%s\n' "Bringing up project..."
  if ! docker compose -f "${WEBSITE_FOLDER}/compose.yaml" up -d >/dev/null; then
    printf '%s\n' "Failed to bring up project ❌" >&2
    exit 1
  fi

  # If gateway is running: attach network & reload nginx
  if [ "$(docker inspect -f '{{.State.Status}}' gateway 2>/dev/null)" = "running" ]; then
    printf '%s\n' "Gateway is running. Ensuring unique network is attached and reloading nginx..."
    if ! docker inspect -f '{{json .NetworkSettings.Networks}}' gateway 2>/dev/null | grep -q "\"$GATEWAY_NETWORK\""; then
      if ! docker network connect "$GATEWAY_NETWORK" gateway >/dev/null; then
        printf '%s\n' "Failed to attach network ❌" >&2
        exit 1
      fi
    fi
    if ! docker exec gateway nginx -s reload; then
      printf '%s\n' "Failed to reload nginx ❌" >&2
      exit 1
    fi
  fi

# ---- directive: down ---------------------------------------------------------

elif [ "$DIRECTIVE" = 'down' ]; then

  if [ "$WEBSITE_FOLDER" != "gateway" ] && [ ! -d "$WEBSITE_FOLDER" ]; then
    printf 'Can'\''t find %s/\n' "$WEBSITE_FOLDER"
    exit 1
  fi

  # Bring down gateway itself
  if [ "$WEBSITE_FOLDER" = "gateway" ]; then
    printf '%s\n' "Bringing down gateway..."
    if ! docker compose -f gateway/compose.yaml down; then
      printf '%s\n' "Failed to bring down gateway ❌" >&2
      exit 1
    fi
    exit 0
  fi

  # Detach gateway network if attached
  if [ "$(docker inspect -f '{{.State.Status}}' gateway 2>/dev/null)" = "running" ] &&
     docker inspect -f '{{json .NetworkSettings.Networks}}' gateway 2>/dev/null | grep -q "\"$GATEWAY_NETWORK\""
  then
    printf '%s\n' "Detaching unique network from gateway..."
    if ! docker network disconnect "$GATEWAY_NETWORK" gateway; then
      printf '%s\n' "Failed to detach unique network ❌" >&2
      exit 1
    fi
  fi

  # Compose down the project
  printf '%s\n' "Bringing down project..."
  if ! docker compose -f "${WEBSITE_FOLDER}/compose.yaml" down; then
    printf '%s\n' "Failed to bring down project ❌" >&2
    exit 1
  fi

  # Remove unique gateway network
  if docker network inspect "$GATEWAY_NETWORK" >/dev/null 2>&1; then
    printf '%s\n' "Removing unique gateway network..."
    if ! docker network rm "$GATEWAY_NETWORK" >/dev/null; then
      printf '%s\n' "Failed to remove unique gateway network ❌" >&2
      exit 1
    fi
  else
    printf '%s\n' "No unique gateway network to remove."
  fi

  # Remove gateway server config
  if [ -f "$GATEWAY_NGINX_CONF" ]; then
    printf '%s\n' "Removing project config file..."
    rm -f -- "$GATEWAY_NGINX_CONF"
  else
    printf '%s\n' "No project config file to remove."
  fi

  # Remove override YAML
  if [ -f "gateway/${WEBSITE_FOLDER}.yaml" ]; then
    printf '%s\n' "Removing override YAML file from gateway..."
    rm -f -- "gateway/${WEBSITE_FOLDER}.yaml"
  else
    printf '%s\n' "No override YAML to remove from gateway."
  fi

# ---- directive: new ----------------------------------------------------------

elif [ "$DIRECTIVE" = 'new' ]; then

  if [ -d "$WEBSITE_FOLDER" ]; then
    printf 'Directory %s/ already exists.\n' "$WEBSITE_FOLDER"
    exit 1
  fi

  # Setup new gateway
  if [ "$WEBSITE_FOLDER" = "gateway" ]; then
    if [ ! -d "/srv/acme" ]; then
      printf '%s\n' "Creating /srv/acme..."
      sudo mkdir /srv/acme
      sudo chown root:root /srv/acme
      sudo chmod 755 /srv/acme
    fi
    if [ ! -d "/srv/ssl" ]; then
      printf '%s\n' "Creating /srv/ssl..."
      sudo mkdir /srv/ssl
      sudo chown root:root /srv/ssl
      sudo chmod 755 /srv/ssl
    fi

    printf '%s\n' "Creating gateway directories..."
    mkdir -p "$WEBSITE_FOLDER/conf.d"

    printf '%s\n' "Creating gateway nginx config..."
    cat > "$WEBSITE_FOLDER/conf.d/default.conf" << 'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;

  # Serve challenge files
  location ^~ /.well-known/acme-challenge {
    root /var/www/acme-challenge;
    default_type "text/plain";
    try_files $uri =404;
  }

  # Redirect all other requests to https
  location / {
    return 302 https://$host$request_uri;
  }
}

server {
  listen 443 ssl default_server;
  listen [::]:443 ssl default_server;

  # If the request doesn't match any other server block, reject it.
  ssl_reject_handshake on;
}
EOF

    printf '%s\n' "Creating gateway compose file..."
    cat > "$WEBSITE_FOLDER/compose.yaml" << 'EOF'
services:
  gateway:
    image: nginx:1.29-alpine
    restart: unless-stopped
    container_name: gateway
    ports:
      - '80:80'
      - '443:443'
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - /srv/acme:/var/www/acme-challenge:ro
      - /srv/ssl:/etc/nginx/ssl:ro
EOF
    exit 0
  fi

  # Standard project scaffold
  printf '%s\n' "Creating project directories..."
  mkdir -p "$WEBSITE_FOLDER/nginx/conf.d"

  printf '%s\n' "Creating project nginx config file..."
  cat > "$WEBSITE_NGINX_CONF" <<EOF
fastcgi_cache_path /var/cache/nginx levels=1:2 keys_zone=WORDPRESS:10m inactive=60m use_temp_path=off;
fastcgi_cache_key "$scheme$request_method$host$request_uri";

server {
  listen 80;
  server_name $WEBSITE_URL;

  root /var/www/html;
  index index.php index.html index.htm;

  set \$skip_cache 0;
  if (\$request_method = POST) { set \$skip_cache 1; }
  if (\$query_string ~* "preview=true|s=") { set \$skip_cache 1; }
  if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_logged_in") { set \$skip_cache 1; }

  location / {
    try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    include fastcgi_params;
    fastcgi_index index.php;
    fastcgi_pass wp:9000;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_read_timeout 300;
    fastcgi_cache WORDPRESS;
    fastcgi_cache_valid 200 301 302 1h;
    fastcgi_cache_use_stale error timeout invalid_header updating http_500 http_503;
    fastcgi_cache_bypass \$skip_cache;
    fastcgi_no_cache \$skip_cache;
    add_header X-FastCGI-Cache \$upstream_cache_status;
  }
}
EOF

  printf '%s\n' "Creating project compose file..."
  cat > "$WEBSITE_FOLDER/compose.yaml" <<EOF
services:

  ## NGINX
  nginx:
    container_name: ${WEBSITE_FOLDER}_nginx
    image: nginx:1.29-alpine
    restart: unless-stopped
    depends_on:
      - wp
    networks:
      ${GATEWAY_NETWORK}:
      nginx-wp:
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - wp-content:/var/www/html/wp-content:ro
      - wp-core:/var/www/html:ro
      - nginx-cache:/var/cache/nginx

  ## WORDPRESS
  wp:
    container_name: ${WEBSITE_FOLDER}_wp
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    depends_on:
      - db
      - redis
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_USER: \${DB_USER}
      WORDPRESS_DB_PASSWORD: \${DB_PASSWORD}
      WORDPRESS_DB_NAME: \${DB_NAME}
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PORT', 6379);
        define('WP_CACHE_KEY_SALT', '$WEBSITE_URL');
    networks:
      - nginx-wp
      - wp-db
    volumes:
      - wp-core:/var/www/html
      - wp-content:/var/www/html/wp-content

  ## REDIS
  redis:
    container_name: ${WEBSITE_FOLDER}_redis
    image: redis:7-alpine
    restart: unless-stopped
    networks:
      - nginx-wp
    volumes:
      - redis-data:/data

  ## DATABASE
  db:
    container_name: ${WEBSITE_FOLDER}_db
    image: mariadb:12.0
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: \${DB_ROOT_PASSWORD}
      MARIADB_DATABASE: \${DB_NAME}
      MARIADB_USER: \${DB_USER}
      MARIADB_PASSWORD: \${DB_PASSWORD}
    networks:
      - wp-db
    volumes:
      - db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--su-mysql", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

## NETWORKS
networks:
  ${GATEWAY_NETWORK}:
    external: true
  nginx-wp:
  wp-db:

## VOLUMES
volumes:
  wp-content:
  wp-core:
  db:
  nginx-cache:
  redis-data:
EOF

  printf '%s\n' "Creating project .env file..."
  DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  DB_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)

  cat > "$WEBSITE_FOLDER/.env" <<EOF
DB_NAME=wordpress
DB_USER=wpuser
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
EOF

  printf '%s\n' "Creating project Dockerfile..."
  cat > "$WEBSITE_FOLDER/Dockerfile" <<'EOF'
FROM wordpress:6.8.3-php8.4-fpm-alpine

# Remove stock plugins
RUN rm -rf /usr/src/wordpress/wp-content/plugins/*

# Install redis PHP extension for object caching
RUN set -eux; \
  apk add --no-cache --virtual .build-deps $PHPIZE_DEPS; \
  pecl install redis; \
  docker-php-ext-enable redis; \
  apk del .build-deps

# Remove all themes except twentytwentyfive
RUN find /usr/src/wordpress/wp-content/themes/ -mindepth 1 -maxdepth 1 ! -name 'twentytwentyfive' -exec rm -rf {} +
EOF

# ---- directive: rm -----------------------------------------------------------

elif [ "$DIRECTIVE" = 'rm' ]; then

  if [ -d "$WEBSITE_FOLDER" ]; then
    x down "$WEBSITE_URL"

    if docker volume ls --format '{{.Name}}' | grep -q -- "$WEBSITE_FOLDER"; then
      printf '%s\n' "Erasing volumes..."
      docker volume ls --format '{{.Name}}' | grep -- "$WEBSITE_FOLDER" | xargs -r docker volume rm -f
    else
      printf '%s\n' "No attached volumes to erase."
    fi

    printf '%s\n' "Erasing files..."
    rm -rf -- "$WEBSITE_FOLDER"
  else
    printf '%s/\n' "$WEBSITE_FOLDER" | sed 's/$/ not found./'
    exit 1
  fi


# ---- directive: export-wp-content -----------------------------------------------------------

elif [ "$DIRECTIVE" = 'export-content' ]; then

DOCKER_VOLUME="${WEBSITE_FOLDER}_wp-content"
EXPORT_FOLDER="$PWD/export/$WEBSITE_FOLDER"
ARCHIVE_NAME="${WEBSITE_FOLDER}_wp-content_$(date +%F_%H%M%S).tar.gz"

if [ -d "$WEBSITE_FOLDER" ]; then
  if docker volume inspect "$DOCKER_VOLUME" >/dev/null 2>&1; then
    mkdir -p "$EXPORT_FOLDER"
    docker run --rm -v "$DOCKER_VOLUME":/data:ro -v "$EXPORT_FOLDER":/backup alpine \
      sh -c "tar -czf /backup/${ARCHIVE_NAME} -C /data ."
    sudo chown $USER:$USER "$EXPORT_FOLDER/$ARCHIVE_NAME"
    sudo chmod 600 "$EXPORT_FOLDER/$ARCHIVE_NAME"
    printf 'Exported %s\n' "$ARCHIVE_NAME"
  else
    printf '%s volume not found.\n' "$DOCKER_VOLUME"
    exit 1
  fi
else
  printf 'Project not found.\n'
  exit 1
fi


elif [ "$DIRECTIVE" = 'export-core' ]; then

DOCKER_VOLUME="${WEBSITE_FOLDER}_wp-core"
EXPORT_FOLDER="$PWD/export/$WEBSITE_FOLDER"
ARCHIVE_NAME="${WEBSITE_FOLDER}_wp-core_$(date +%F_%H%M%S).tar.gz"

if [ -d "$WEBSITE_FOLDER" ]; then
  if docker volume inspect "$DOCKER_VOLUME" >/dev/null 2>&1; then
    mkdir -p "$EXPORT_FOLDER"
    docker run --rm -v "$DOCKER_VOLUME":/data:ro -v "$EXPORT_FOLDER":/backup alpine \
      sh -c "tar -czf /backup/${ARCHIVE_NAME} -C /data ."
    sudo chown $USER:$USER "$EXPORT_FOLDER/$ARCHIVE_NAME"
    sudo chmod 600 "$EXPORT_FOLDER/$ARCHIVE_NAME"
    printf 'Exported %s\n' "$ARCHIVE_NAME"
  else
    printf '%s volume not found.\n' "$DOCKER_VOLUME"
    exit 1
  fi
else
  printf 'Project not found.\n'
  exit 1
fi

elif [ "$DIRECTIVE" = 'export-db' ]; then

  # Load project env
  set -a; . "$WEBSITE_FOLDER/.env"; set +a

  DB_CONTAINER="${WEBSITE_FOLDER}_db"   # container name (matches your screenshot)
  DB_VOLUME="${WEBSITE_FOLDER}_db"      # volume name (same string, different object)
  EXPORT_FOLDER="${PWD}/export/${WEBSITE_FOLDER}"
  TS="$(date +%F_%H%M%S)"
  ARCHIVE_NAME="${WEBSITE_FOLDER}_db_${TS}.sql.gz"

  # 1) Sanity checks
  [ -d "$WEBSITE_FOLDER" ] || { printf 'Project not found: %s\n' "$WEBSITE_FOLDER" >&2; exit 1; }
  docker volume inspect "$DB_VOLUME" >/dev/null 2>&1 || { printf 'Volume not found: %s\n' "$DB_VOLUME" >&2; exit 1; }

  mkdir -p "$EXPORT_FOLDER"

  # 2) Ensure DB container is running
  if ! docker ps --format '{{.Names}}' | grep -qw "^${DB_CONTAINER}$"; then
    printf 'DB container not running. Starting stack...\n'
    x up $WEBSITE_URL
    sleep 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qw "^${DB_CONTAINER}$"; then
    printf 'Failed to start DB container: %s\n' "$DB_CONTAINER" >&2
    exit 1
  fi

  docker exec -i "$DB_CONTAINER" \
    mariadb-dump -u root -p"$DB_ROOT_PASSWORD" --databases "$DB_NAME" \
      --single-transaction --quick --routines --triggers \
      --default-character-set=utf8mb4 \
  | gzip > "$EXPORT_FOLDER/$ARCHIVE_NAME" && printf 'Export complete: %s\n' "$EXPORT_FOLDER/$ARCHIVE_NAME" && exit 0

  printf "Error exporting.\n"
  exit 1

# ---- directive: purge-cache ----------------------------------------------------

elif [ "$DIRECTIVE" = 'purge-cache' ]; then

  if [ ! -d "$WEBSITE_FOLDER" ]; then
    printf '%s/\n' "$WEBSITE_FOLDER" | sed 's/$/ not found./'
    exit 1
  fi

  NGINX_CONTAINER="${WEBSITE_FOLDER}_nginx"
  REDIS_CONTAINER="${WEBSITE_FOLDER}_redis"

  printf '%s\n' "Ensuring nginx and redis are running..."
  (cd "$WEBSITE_FOLDER" && docker compose up -d nginx redis >/dev/null)

  if docker ps --format '{{.Names}}' | grep -qw "^${REDIS_CONTAINER}$"; then
    printf '%s\n' "Flushing Redis object cache..."
    if docker exec "$REDIS_CONTAINER" redis-cli FLUSHALL >/dev/null; then
      printf '%s\n' "Redis cache purged."
    else
      printf '%s\n' "Failed to purge Redis cache." >&2
    fi
  else
    printf '%s\n' "Redis container not running; skipping Redis purge." >&2
  fi

  if docker ps --format '{{.Names}}' | grep -qw "^${NGINX_CONTAINER}$"; then
    printf '%s\n' "Clearing FastCGI cache directory..."
    if docker exec "$NGINX_CONTAINER" sh -c 'rm -rf /var/cache/nginx/*' >/dev/null; then
      printf '%s\n' "FastCGI cache purged."
    else
      printf '%s\n' "Failed to purge FastCGI cache." >&2
    fi
  else
    printf '%s\n' "Nginx container not running; skipping FastCGI purge." >&2
  fi
fi