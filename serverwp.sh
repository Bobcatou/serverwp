#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="serverwp"
SCRIPT_VERSION="4.1.8"


SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS_FILE="${SCRIPT_DIR}/serverwp.defaults.sh"
[[ -f "${DEFAULTS_FILE}" ]] && . "${DEFAULTS_FILE}"

COMMAND="${1:-install}"
WP_CLI="${WP_CLI:-/usr/local/bin/wp}"


RED=$'[0;31m'
GREEN=$'[0;32m'
YELLOW=$'[1;33m'
BLUE=$'[0;34m'
NC=$'[0m'

INSTALL_ISSUES=()

record_issue() {
  INSTALL_ISSUES+=("$*")
  warn "$*"
}

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
note() { echo -e "${BLUE}[NOTE]${NC} $*"; }
die()  { err "$*"; exit 1; }

trap 'err "Script failed at line $LINENO"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage: $0 [install|add-site]

Commands:
  install    Prepare a fresh server and install the first WordPress site.
  add-site   Add another isolated WordPress site to an existing serverwp server.
EOF
}

validate_command() {
  case "${COMMAND}" in
    install|add-site) ;;
    --help|-h) usage; exit 0 ;;
    *) usage; die "Unknown command: ${COMMAND}" ;;
  esac
}

prompt_nonempty() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while true; do
    read -r -p "$prompt_text" value
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "This field cannot be empty."
  done
}

prompt_nonempty_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local value=""
  while true; do
    read -r -p "$prompt_text [default: $default_value] " value
    value="${value:-$default_value}"
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "This field cannot be empty."
  done
}

prompt_hidden_nonempty() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while true; do
    read -r -s -p "$prompt_text" value
    echo
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "This field cannot be empty."
  done
}

prompt_hidden_nonempty_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local value=""
  while true; do
    read -r -s -p "$prompt_text [default hidden, press Enter to use saved value]: " value
    echo
    value="${value:-$default_value}"
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "This field cannot be empty."
  done
}

prompt_yes_no() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while true; do
    read -r -p "$prompt_text [y/n]: " value
    case "${value,,}" in
      y|yes) printf -v "$var_name" 'yes'; return ;;
      n|no)  printf -v "$var_name" 'no';  return ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

validate_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

validate_email() {
  local e="$1"
  [[ "$e" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

prompt_ipv4() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while true; do
    read -r -p "$prompt_text" value
    if validate_ipv4 "$value"; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "Please enter a valid IPv4 address."
  done
}

prompt_ipv4_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local value=""
  while true; do
    read -r -p "$prompt_text [default: $default_value] " value
    value="${value:-$default_value}"
    if validate_ipv4 "$value"; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    warn "Please enter a valid IPv4 address."
  done
}

sanitize_identifier() {
  local prefix="$1"
  local value="$2"
  local max_len="$3"
  local clean=""
  clean="$(printf '%s' "${value,,}" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  [[ -n "${clean}" ]] || clean="site"
  local result="${prefix}${clean}"
  if (( ${#result} > max_len )); then
    local checksum=""
    checksum="$(printf '%s' "${value}" | cksum | awk '{print $1}')"
    local keep=$(( max_len - ${#prefix} - ${#checksum} - 1 ))
    (( keep < 1 )) && keep=1
    result="${prefix}${clean:0:keep}_${checksum}"
  fi
  printf '%s' "${result}"
}

set_site_paths() {
  SITE_ROOT="${DOCROOT_BASE}/${SITE_DOMAIN}"
  WEB_ROOT="${SITE_ROOT}"
  APACHE_SITE_CONF="${APACHE_CONF_DIR}/${SITE_DOMAIN}.conf"
  SITE_USER="$(sanitize_identifier "wp_" "${SITE_DOMAIN}" 32)"
  SITE_GROUP="${SITE_USER}"
  PHP_FPM_POOL_NAME="${SITE_USER}"
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET_DIR}/${SITE_USER}.sock"
  if [[ -n "${PHP_FPM_POOL_DIR:-}" ]]; then
    PHP_FPM_POOL_CONF="${PHP_FPM_POOL_DIR}/${PHP_FPM_POOL_NAME}.conf"
  else
    PHP_FPM_POOL_CONF=""
  fi
}

set_db_defaults_for_domain() {
  DEFAULT_GENERATED_DB_NAME="$(sanitize_identifier "wp_" "${SITE_DOMAIN}" 64)"
  DEFAULT_GENERATED_DB_USER="$(sanitize_identifier "wp_" "${SITE_DOMAIN}" 32)"
}

run_step() {
  local description="$1"
  shift
  log "$description"
  "$@"
}

detect_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS."
  . /etc/os-release

  OS_ID="${ID}"
  OS_VERSION_ID="${VERSION_ID}"
  OS_VERSION_MAJOR="${VERSION_ID%%.*}"

  case "${OS_ID}" in
    almalinux)
      [[ "${OS_VERSION_MAJOR}" == "9" ]] || die "This script supports AlmaLinux 9."
      APACHE_SERVICE="httpd"
      APACHE_CONF_DIR="/etc/httpd/conf.d"
      APACHE_LOG_DIR="/var/log/httpd"
      APACHE_USER="apache"
      APACHE_GROUP="apache"
      DOCROOT_BASE="/var/www"
      DB_SERVICE="mariadb"
      FIREWALL_KIND="firewalld"
      BIND_SERVICE="named"
      PHP_FPM_PACKAGE="php-fpm"
      PHP_FPM_SERVICE="php-fpm"
      PHP_FPM_POOL_DIR="/etc/php-fpm.d"
      PHP_FPM_SOCKET_DIR="/run/php-fpm"
      ;;
    ubuntu)
      [[ "${OS_VERSION_MAJOR}" == "22" || "${OS_VERSION_MAJOR}" == "24" ]] || die "This script supports Ubuntu 22.04 or 24.04."
      APACHE_SERVICE="apache2"
      APACHE_CONF_DIR="/etc/apache2/sites-available"
      APACHE_LOG_DIR="/var/log/apache2"
      APACHE_USER="www-data"
      APACHE_GROUP="www-data"
      DOCROOT_BASE="/var/www"
      DB_SERVICE="mariadb"
      FIREWALL_KIND="ufw"
      BIND_SERVICE="bind9"
      PHP_FPM_PACKAGE="php-fpm"
      PHP_FPM_SOCKET_DIR="/run/php"
      ;;
debian)
  [[ "${OS_VERSION_MAJOR}" == "12" || "${OS_VERSION_MAJOR}" == "13" ]] || die "This script supports Debian 12 or 13."
  APACHE_SERVICE="apache2"
  APACHE_CONF_DIR="/etc/apache2/sites-available"
  APACHE_LOG_DIR="/var/log/apache2"
  APACHE_USER="www-data"
  APACHE_GROUP="www-data"
  DOCROOT_BASE="/var/www"
  DB_SERVICE="mariadb"
  FIREWALL_KIND="ufw"
  BIND_SERVICE="bind9"
  PHP_FPM_PACKAGE="php-fpm"
  PHP_FPM_SOCKET_DIR="/run/php"
  ;;
    *)
      die "Unsupported OS. Use AlmaLinux 9, Ubuntu 22.04/24.04, or Debian 12/13."
      ;;
  esac
}

show_banner() {
  echo
  echo "===================================================="
  echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  echo "OS: ${OS_ID} ${OS_VERSION_ID}"
  echo "===================================================="
  echo
}


show_intro() {
  echo
  echo -e "${GREEN}====================================================${NC}"
  echo -e "${GREEN}Welcome to serverwp v${SCRIPT_VERSION}${NC}"
  echo -e "${GREEN}====================================================${NC}"
  if [[ "${COMMAND}" == "add-site" ]]; then
    echo -e "${BLUE}This mode adds another isolated WordPress site to an existing serverwp server.${NC}"
  else
    echo -e "${BLUE}This installer will prepare a fresh Linux server to host WordPress.${NC}"
  fi
  echo
  if [[ "${COMMAND}" == "add-site" ]]; then
    echo -e "${YELLOW}It will configure:${NC}"
    echo -e "  - A dedicated Linux user for the new site"
    echo -e "  - A dedicated PHP-FPM pool and socket"
    echo -e "  - A separate MariaDB database and database user"
    echo -e "  - A separate Apache virtual host"
    echo -e "  - WordPress, UpdraftPlus, and optional Let's Encrypt SSL"
  else
    echo -e "${YELLOW}It will install and configure:${NC}"
    echo -e "  - Apache web server"
    echo -e "  - PHP-FPM with essential WordPress modules"
    echo -e "  - MariaDB database server"
    echo -e "  - WP-CLI"
    echo -e "  - The latest version of WordPress"
    echo -e "  - UpdraftPlus backup plugin"
    echo -e "  - Optional Cloudflare guidance, BIND DNS, firewall, and Let's Encrypt SSL"
  fi
  echo
  echo -e "${BLUE}Supported systems:${NC} AlmaLinux 9, Ubuntu 22.04/24.04, Debian 12/13"
  echo -e "${GREEN}====================================================${NC}"
  echo
}

collect_answers() {
  while true; do
    if [[ -n "${DEFAULT_SITE_DOMAIN:-}" ]]; then
    prompt_nonempty_default SITE_DOMAIN "Domain (example.com):" "${DEFAULT_SITE_DOMAIN}"
  else
    prompt_nonempty SITE_DOMAIN "Domain (example.com): "
  fi
    SITE_DOMAIN="${SITE_DOMAIN,,}"
    validate_domain "${SITE_DOMAIN}" && break
    warn "Please enter a valid domain."
  done

  if [[ -n "${DEFAULT_SITE_TITLE:-}" ]]; then
    prompt_nonempty_default SITE_TITLE "WordPress site title:" "${DEFAULT_SITE_TITLE}"
  else
    prompt_nonempty SITE_TITLE "WordPress site title: "
  fi
  if [[ -n "${DEFAULT_ADMIN_USER:-}" ]]; then
    prompt_nonempty_default ADMIN_USER "WordPress admin username:" "${DEFAULT_ADMIN_USER}"
  else
    prompt_nonempty ADMIN_USER "WordPress admin username: "
  fi
  if [[ -n "${DEFAULT_ADMIN_PASS:-}" ]]; then
    prompt_hidden_nonempty_default ADMIN_PASS "WordPress admin password" "${DEFAULT_ADMIN_PASS}"
  else
    prompt_hidden_nonempty ADMIN_PASS "WordPress admin password: "
  fi

  while true; do
    if [[ -n "${DEFAULT_ADMIN_EMAIL:-}" ]]; then
      prompt_nonempty_default ADMIN_EMAIL "WordPress admin email:" "${DEFAULT_ADMIN_EMAIL}"
    else
      prompt_nonempty ADMIN_EMAIL "WordPress admin email: "
    fi
    validate_email "${ADMIN_EMAIL}" && break
    warn "Please enter a valid email address."
  done

  if [[ -n "${DEFAULT_DB_NAME:-}" ]]; then
    prompt_nonempty_default DB_NAME "MariaDB database name:" "${DEFAULT_DB_NAME}"
  else
    prompt_nonempty DB_NAME "MariaDB database name: "
  fi
  if [[ -n "${DEFAULT_DB_USER:-}" ]]; then
    prompt_nonempty_default DB_USER "MariaDB database username:" "${DEFAULT_DB_USER}"
  else
    prompt_nonempty DB_USER "MariaDB database username: "
  fi
  if [[ -n "${DEFAULT_DB_PASS:-}" ]]; then
    prompt_hidden_nonempty_default DB_PASS "MariaDB database password" "${DEFAULT_DB_PASS}"
  else
    prompt_hidden_nonempty DB_PASS "MariaDB database password: "
  fi

  if [[ -n "${DEFAULT_SERVER_PUBLIC_IP:-}" ]]; then
    prompt_ipv4_default SERVER_PUBLIC_IP "Public server IPv4 address:" "${DEFAULT_SERVER_PUBLIC_IP}"
  else
    prompt_ipv4 SERVER_PUBLIC_IP "Public server IPv4 address: "
  fi

  if [[ "${OS_ID}" == "almalinux" ]]; then
    while true; do
      local php_default="${DEFAULT_PHP_VERSION:-8.3}"
      read -r -p "PHP version for AlmaLinux (8.2 / 8.3 / 8.4) [default: ${php_default}]: " PHP_VERSION
      PHP_VERSION="${PHP_VERSION:-$php_default}"
      [[ "${PHP_VERSION}" =~ ^8\.(2|3|4)$ ]] && break
      warn "Choose 8.2, 8.3, or 8.4."
    done
  else
    PHP_VERSION="default"
  fi

  prompt_yes_no WANT_WWW "Also configure www.${SITE_DOMAIN}?"

  echo
  note "Recommended: use Cloudflare nameservers and skip self-hosted BIND unless you specifically want your own nameserver."
  prompt_yes_no WANT_CLOUDFLARE "Use Cloudflare as your DNS provider?"

  if [[ "${WANT_CLOUDFLARE}" == "yes" ]]; then
    INSTALL_BIND="no"
  else
    prompt_yes_no INSTALL_BIND "Install and configure self-hosted BIND/named on this server?"
    if [[ "${INSTALL_BIND}" == "yes" ]]; then
      local ns1_default="${DEFAULT_NS1_HOST:-ns1.${SITE_DOMAIN}}"
      local ns2_default="${DEFAULT_NS2_HOST:-ns2.${SITE_DOMAIN}}"
      read -r -p "Primary nameserver host [default: ${ns1_default}]: " NS1_HOST
      NS1_HOST="${NS1_HOST:-$ns1_default}"
      read -r -p "Secondary nameserver host [default: ${ns2_default}]: " NS2_HOST
      NS2_HOST="${NS2_HOST:-$ns2_default}"
      prompt_ipv4_default NS1_IP "IP for ${NS1_HOST}:" "${DEFAULT_NS1_IP:-${SERVER_PUBLIC_IP}}"
      prompt_ipv4_default NS2_IP "IP for ${NS2_HOST}:" "${DEFAULT_NS2_IP:-${SERVER_PUBLIC_IP}}"
    else
      INSTALL_BIND="no"
    fi
  fi

  prompt_yes_no WANT_SSL "Create Let's Encrypt certificate when DNS is ready?"
  if [[ "${WANT_SSL}" == "yes" ]]; then
    while true; do
      if [[ -n "${DEFAULT_LE_EMAIL:-}" ]]; then
      prompt_nonempty_default LE_EMAIL "Let's Encrypt email:" "${DEFAULT_LE_EMAIL}"
    else
      prompt_nonempty LE_EMAIL "Let's Encrypt email: "
    fi
      validate_email "${LE_EMAIL}" && break
      warn "Please enter a valid email address."
    done
  fi

  prompt_yes_no CONFIGURE_FIREWALL "Configure firewall automatically?"
  prompt_yes_no FORCE_HTTPS "Redirect HTTP to HTTPS after certificate is installed?"

  set_site_paths

  echo
  echo "================= SUMMARY ================="
  echo "Domain:            ${SITE_DOMAIN}"
  echo "Server IP:         ${SERVER_PUBLIC_IP}"
  echo "Cloudflare:        ${WANT_CLOUDFLARE}"
  echo "Self-hosted BIND:  ${INSTALL_BIND}"
  echo "Let's Encrypt:     ${WANT_SSL}"
  echo "WWW Alias:         ${WANT_WWW}"
  echo "Web root:          ${WEB_ROOT}"
  echo "==========================================="
  echo

  if [[ "${WANT_CLOUDFLARE}" == "yes" ]]; then
    echo "Cloudflare setup steps:"
    echo "1. Add ${SITE_DOMAIN} to Cloudflare."
    echo "2. Create DNS records in Cloudflare:"
    echo "   - A @ -> ${SERVER_PUBLIC_IP}"
    if [[ "${WANT_WWW}" == "yes" ]]; then
      echo "   - CNAME www -> ${SITE_DOMAIN}"
      echo "     or A www -> ${SERVER_PUBLIC_IP}"
    fi
    echo "3. Change your registrar nameservers to the two nameservers Cloudflare assigns."
    echo "4. For the first Let's Encrypt run, keep @ and www as DNS only / grey cloud."
    echo
    while true; do
      read -r -p "Are Cloudflare DNS and registrar nameservers fully set up and ready? [y/n]: " CF_READY
      case "${CF_READY,,}" in
        y|yes) break ;;
        n|no) die "Finish Cloudflare and registrar DNS setup first, then rerun the script." ;;
        *) warn "Please answer y or n." ;;
      esac
    done
  fi

  if [[ "${INSTALL_BIND}" == "yes" ]]; then
    echo
    echo "Self-hosted nameserver setup:"
    echo "Create these glue/host records at your registrar first:"
    echo "  ${NS1_HOST} -> ${NS1_IP}"
    echo "  ${NS2_HOST} -> ${NS2_IP}"
    echo
    while true; do
      read -r -p "Have you already created those glue records? [y/n]: " GLUE_READY
      case "${GLUE_READY,,}" in
        y|yes) break ;;
        n|no) die "Create the glue records first, then rerun the script." ;;
        *) warn "Please answer y or n." ;;
      esac
    done
  fi

  while true; do
    read -r -p "Proceed with installation? [y/n]: " GO_AHEAD
    case "${GO_AHEAD,,}" in
      y|yes) break ;;
      n|no) die "Installation cancelled." ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

install_base_packages_alma() {
  dnf -y update
  dnf -y install epel-release dnf-plugins-core curl wget unzip tar bind-utils nano
}

install_base_packages_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl wget unzip tar ca-certificates gnupg lsb-release bind9-dnsutils snapd nano
  systemctl enable --now snapd >/dev/null 2>&1 || true
}

install_base_packages() {
  case "${OS_ID}" in
    almalinux) install_base_packages_alma ;;
    ubuntu|debian) install_base_packages_deb ;;
  esac
}

install_apache_php_alma() {
  dnf -y install https://rpms.remirepo.net/enterprise/remi-release-9.rpm
  dnf -y module reset php
  dnf -y module install "php:remi-${PHP_VERSION}"
  dnf -y install httpd php php-cli php-common php-mysqlnd php-gd php-mbstring php-xml php-curl php-zip php-intl php-soap php-bcmath php-opcache php-pecl-imagick mod_ssl php-fpm
  systemctl enable --now httpd
  systemctl enable --now php-fpm
}

install_apache_php_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y apache2 php php-fpm php-cli php-common php-mysql php-gd php-mbstring php-xml php-curl php-zip php-intl php-soap php-bcmath
  a2enmod rewrite headers ssl proxy_fcgi setenvif >/dev/null 2>&1 || true
  systemctl enable --now apache2
  detect_php_fpm_runtime || die "Could not detect PHP-FPM runtime after installing PHP-FPM."
  systemctl enable --now "${PHP_FPM_SERVICE}"
}

install_apache_php() {
  case "${OS_ID}" in
    almalinux) install_apache_php_alma ;;
    ubuntu|debian) install_apache_php_deb ;;
  esac
}

tune_php() {
  local php_ini=""
  if [[ "${OS_ID}" == "almalinux" ]]; then
    php_ini="/etc/php.ini"
  else
    php_ini="$(php -i 2>/dev/null | awk -F'=> ' '/Loaded Configuration File/ {print $2}' | head -n1)"
  fi
  [[ -f "${php_ini}" ]] || return 0

  sed -i 's/^memory_limit = .*/memory_limit = 256M/' "${php_ini}" || true
  sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 50M/' "${php_ini}" || true
  sed -i 's/^post_max_size = .*/post_max_size = 64M/' "${php_ini}" || true
  sed -i 's/^max_execution_time = .*/max_execution_time = 300/' "${php_ini}" || true
  sed -i 's/^max_input_time = .*/max_input_time = 300/' "${php_ini}" || true
  sed -i 's/^max_input_vars = .*/max_input_vars = 5000/' "${php_ini}" || true

  systemctl restart php-fpm >/dev/null 2>&1 || true
  systemctl restart "${APACHE_SERVICE}" >/dev/null 2>&1 || true
}


detect_php_fpm_runtime() {
  if [[ "${OS_ID}" == "almalinux" ]]; then
    PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-php-fpm}"
    PHP_FPM_POOL_DIR="${PHP_FPM_POOL_DIR:-/etc/php-fpm.d}"
    PHP_FPM_SOCKET_DIR="${PHP_FPM_SOCKET_DIR:-/run/php-fpm}"
    return 0
  fi

  local version=""
  version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  if [[ -z "${version}" ]]; then
    version="$(php -v 2>/dev/null | awk 'NR==1 {split($2,a,"."); print a[1]"."a[2]}')"
  fi
  [[ -n "${version}" ]] || return 1
  PHP_FPM_VERSION="${version}"
  PHP_FPM_SERVICE="php${PHP_FPM_VERSION}-fpm"
  PHP_FPM_POOL_DIR="/etc/php/${PHP_FPM_VERSION}/fpm/pool.d"
  PHP_FPM_SOCKET_DIR="/run/php"
}

php_fpm_available() {
  detect_php_fpm_runtime || return 1
  [[ -d "${PHP_FPM_POOL_DIR}" ]] && systemctl list-unit-files "${PHP_FPM_SERVICE}.service" >/dev/null 2>&1
}

site_uses_php_fpm() {
  local conf="${1:-${APACHE_SITE_CONF:-}}"
  [[ -n "${conf}" && -f "${conf}" ]] || return 1
  grep -Eq 'proxy:unix:|SetHandler "proxy:' "${conf}"
}

ensure_php_fpm_stack() {
  if php_fpm_available; then
    return 0
  fi

  log "Installing PHP-FPM support..."
  case "${OS_ID}" in
    almalinux)
      dnf -y install php-fpm
      systemctl enable --now php-fpm
      ;;
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y php-fpm
      a2enmod proxy_fcgi setenvif rewrite headers ssl >/dev/null 2>&1 || true
      detect_php_fpm_runtime || die "Could not detect PHP-FPM runtime after installing PHP-FPM."
      systemctl enable --now "${PHP_FPM_SERVICE}"
      ;;
  esac
}

disable_mod_php_if_present() {
  [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]] || return 0
  local mod=""
  for mod in /etc/apache2/mods-enabled/php*.load; do
    [[ -e "${mod}" ]] || continue
    a2dismod "$(basename "${mod}" .load)" >/dev/null 2>&1 || true
  done
}

create_site_user() {
  if id "${SITE_USER}" >/dev/null 2>&1; then
    return 0
  fi
  useradd --system --user-group --home-dir "${SITE_ROOT}" --shell /usr/sbin/nologin "${SITE_USER}"
}

write_php_fpm_pool() {
  mkdir -p "${PHP_FPM_POOL_DIR}" "${PHP_FPM_SOCKET_DIR}"
  cat > "${PHP_FPM_POOL_CONF}" <<EOF
[${PHP_FPM_POOL_NAME}]
user = ${SITE_USER}
group = ${SITE_GROUP}
listen = ${PHP_FPM_SOCKET}
listen.owner = ${APACHE_USER}
listen.group = ${APACHE_GROUP}
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 20s
pm.max_requests = 500
php_admin_value[open_basedir] = ${WEB_ROOT}:/tmp
php_admin_value[upload_tmp_dir] = /tmp
php_admin_value[session.save_path] = /tmp
php_admin_flag[log_errors] = on
EOF
}

restart_php_fpm_checked() {
  detect_php_fpm_runtime || die "Could not detect PHP-FPM runtime."
  if [[ "${OS_ID}" == "almalinux" ]]; then
    php-fpm -t
  else
    php-fpm"${PHP_FPM_VERSION}" -t
  fi
  systemctl restart "${PHP_FPM_SERVICE}"
}

configure_php_fpm_site() {
  ensure_php_fpm_stack
  set_site_paths
  create_site_user
  write_php_fpm_pool
  disable_mod_php_if_present
  restart_php_fpm_checked
}

install_mariadb_alma() {
  curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash
  dnf -y install MariaDB-server MariaDB-client
  systemctl enable --now mariadb
}

install_mariadb_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y mariadb-server mariadb-client
  systemctl enable --now mariadb
}

install_mariadb() {
  case "${OS_ID}" in
    almalinux) install_mariadb_alma ;;
    ubuntu|debian) install_mariadb_deb ;;
  esac
}

configure_mariadb() {
  mysql -uroot <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

install_wp_cli() {
  curl -fsSL -o "${WP_CLI}" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x "${WP_CLI}"
  "${WP_CLI}" --info --allow-root >/dev/null
}

ensure_wp_cli() {
  if [[ -x "${WP_CLI}" ]]; then
    "${WP_CLI}" --info --allow-root >/dev/null
    return 0
  fi
  if have_cmd wp; then
    WP_CLI="$(command -v wp)"
    "${WP_CLI}" --info --allow-root >/dev/null
    return 0
  fi
  install_wp_cli
}

install_wordpress() {
  mkdir -p "${WEB_ROOT}"
  "${WP_CLI}" core download --path="${WEB_ROOT}" --allow-root
  "${WP_CLI}" config create     --path="${WEB_ROOT}"     --dbname="${DB_NAME}"     --dbuser="${DB_USER}"     --dbpass="${DB_PASS}"     --dbhost="localhost"     --dbcharset="utf8mb4"     --dbprefix="wp_"     --skip-check     --allow-root
  "${WP_CLI}" core install     --path="${WEB_ROOT}"     --url="http://${SITE_DOMAIN}"     --title="${SITE_TITLE}"     --admin_user="${ADMIN_USER}"     --admin_password="${ADMIN_PASS}"     --admin_email="${ADMIN_EMAIL}"     --skip-email     --allow-root
  chown -R "${SITE_USER}:${SITE_GROUP}" "${SITE_ROOT}"
  find "${SITE_ROOT}" -type d -exec chmod 755 {} \;
  find "${SITE_ROOT}" -type f -exec chmod 644 {} \;
}


install_updraftplus() {
  "${WP_CLI}" plugin install updraftplus --activate --path="${WEB_ROOT}" --allow-root
}


set_wordpress_permissions() {
  log "Setting recommended WordPress ownership and permissions..."

  mkdir -p "${WEB_ROOT}/wp-content"
  mkdir -p "${WEB_ROOT}/wp-content/uploads"
  mkdir -p "${WEB_ROOT}/wp-content/upgrade"
  mkdir -p "${WEB_ROOT}/wp-content/plugins"
  mkdir -p "${WEB_ROOT}/wp-content/themes"

  chown -R "${SITE_USER}:${SITE_GROUP}" "${SITE_ROOT}"

  find "${SITE_ROOT}" -type d -exec chmod 755 {} \;
  find "${SITE_ROOT}" -type f -exec chmod 644 {} \;

  if [[ -f "${WEB_ROOT}/wp-config.php" ]]; then
    chmod 640 "${WEB_ROOT}/wp-config.php" || true
  fi

  chmod 755 "${WEB_ROOT}/wp-content" || true
  chmod 755 "${WEB_ROOT}/wp-content/uploads" || true
  chmod 755 "${WEB_ROOT}/wp-content/upgrade" || true
  chmod 755 "${WEB_ROOT}/wp-content/plugins" || true
  chmod 755 "${WEB_ROOT}/wp-content/themes" || true

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RFv "${SITE_ROOT}" >/dev/null 2>&1 || true
  fi

  if command -v chcon >/dev/null 2>&1; then
    chcon -R -t httpd_sys_rw_content_t "${WEB_ROOT}/wp-content" >/dev/null 2>&1 || true
  fi
}


disable_default_apache_configs() {
  case "${OS_ID}" in
    almalinux)
      rm -f /etc/httpd/conf.d/welcome.conf || true
      if [[ -f /etc/httpd/conf.d/ssl.conf ]]; then
        mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.disabled
      fi
      ;;
    ubuntu|debian)
      a2dissite 000-default.conf >/dev/null 2>&1 || true
      a2dissite default-ssl.conf >/dev/null 2>&1 || true
      ;;
  esac
}

write_apache_vhost_alma() {
  cat > "${APACHE_SITE_CONF}" <<EOF
<VirtualHost *:80>
    ServerName ${SITE_DOMAIN}
EOF
  if [[ "${WANT_WWW}" == "yes" ]]; then
    cat >> "${APACHE_SITE_CONF}" <<EOF
    ServerAlias www.${SITE_DOMAIN}
EOF
  fi
  cat >> "${APACHE_SITE_CONF}" <<EOF

    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
        Options FollowSymLinks
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${PHP_FPM_SOCKET}|fcgi://localhost/"
    </FilesMatch>

    ErrorLog ${APACHE_LOG_DIR}/${SITE_DOMAIN}-error.log
    CustomLog ${APACHE_LOG_DIR}/${SITE_DOMAIN}-access.log combined
</VirtualHost>
EOF
}

write_apache_vhost_deb() {
  cat > "${APACHE_SITE_CONF}" <<EOF
<VirtualHost *:80>
    ServerName ${SITE_DOMAIN}
EOF
  if [[ "${WANT_WWW}" == "yes" ]]; then
    cat >> "${APACHE_SITE_CONF}" <<EOF
    ServerAlias www.${SITE_DOMAIN}
EOF
  fi
  cat >> "${APACHE_SITE_CONF}" <<EOF

    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        AllowOverride All
        Require all granted
        DirectoryIndex index.php index.html
        Options FollowSymLinks
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:${PHP_FPM_SOCKET}|fcgi://localhost/"
    </FilesMatch>

    ErrorLog ${APACHE_LOG_DIR}/${SITE_DOMAIN}-error.log
    CustomLog ${APACHE_LOG_DIR}/${SITE_DOMAIN}-access.log combined
</VirtualHost>
EOF
  a2ensite "${SITE_DOMAIN}.conf" >/dev/null 2>&1
}

print_apache_diagnostics() {
  err "Apache diagnostics:"
  systemctl status "${APACHE_SERVICE}" --no-pager -l || true
  journalctl -xeu "${APACHE_SERVICE}" --no-pager | tail -50 || true
  if [[ "${OS_ID}" == "almalinux" ]]; then
    httpd -t || true
    httpd -S || true
  else
    apache2ctl configtest || true
    apache2ctl -S || true
  fi
  if [[ -n "${APACHE_SITE_CONF:-}" && -f "${APACHE_SITE_CONF}" ]]; then
    echo "----- ${APACHE_SITE_CONF} -----"
    cat "${APACHE_SITE_CONF}" || true
  fi
}

restart_apache_checked() {
  log "Validating Apache configuration..."
  if [[ "${OS_ID}" == "almalinux" ]]; then
    if ! httpd -t; then
      err "Apache configuration test failed."
      print_apache_diagnostics
      exit 1
    fi
  else
    if ! apache2ctl configtest; then
      err "Apache configuration test failed."
      print_apache_diagnostics
      exit 1
    fi
  fi
  log "Restarting Apache..."
  if ! systemctl restart "${APACHE_SERVICE}"; then
    err "Apache failed to restart."
    print_apache_diagnostics
    exit 1
  fi
  log "Apache restarted successfully."
}

configure_apache_vhost() {
  if [[ "${COMMAND}" == "install" ]]; then
    disable_default_apache_configs
  fi
  case "${OS_ID}" in
    almalinux) write_apache_vhost_alma ;;
    ubuntu|debian) write_apache_vhost_deb ;;
  esac
  restart_apache_checked
}

configure_bind_alma() {
  dnf -y install bind bind-utils
  cp -a /etc/named.conf /etc/named.conf.bak.$(date +%Y%m%d%H%M%S)
  python3 - <<PY
from pathlib import Path
p = Path("/etc/named.conf")
text = p.read_text()
text = text.replace('listen-on port 53 { 127.0.0.1; };', 'listen-on port 53 { any; };')
text = text.replace('listen-on-v6 port 53 { ::1; };', 'listen-on-v6 port 53 { any; };')
text = text.replace('allow-query     { localhost; };', 'allow-query     { any; };')
text = text.replace('recursion yes;', 'recursion no;')
p.write_text(text)
PY
  ZONE_FILE="/var/named/${SITE_DOMAIN}.zone"
  if ! grep -q "zone \"${SITE_DOMAIN}\"" /etc/named.conf; then
    cat >> /etc/named.conf <<EOF

zone "${SITE_DOMAIN}" IN {
        type master;
        file "${ZONE_FILE}";
        allow-update { none; };
};
EOF
  fi
  cat > "${ZONE_FILE}" <<EOF
\$TTL 86400
@   IN  SOA ${NS1_HOST}. admin.${SITE_DOMAIN}. (
        $(date +%Y%m%d01) ; Serial
        3600             ; Refresh
        1800             ; Retry
        1209600          ; Expire
        86400 )          ; Minimum TTL

@       IN  NS      ${NS1_HOST}.
@       IN  NS      ${NS2_HOST}.

@       IN  A       ${SERVER_PUBLIC_IP}
EOF
  if [[ "${WANT_WWW}" == "yes" ]]; then
    cat >> "${ZONE_FILE}" <<EOF
www     IN  CNAME   ${SITE_DOMAIN}.
EOF
  fi
  cat >> "${ZONE_FILE}" <<EOF
ns1     IN  A       ${NS1_IP}
ns2     IN  A       ${NS2_IP}
EOF
  chown root:named "${ZONE_FILE}"
  chmod 640 "${ZONE_FILE}"
  restorecon -v "${ZONE_FILE}" >/dev/null 2>&1 || true
  named-checkzone "${SITE_DOMAIN}" "${ZONE_FILE}"
  named-checkconf
  systemctl enable --now named
  systemctl restart named
  dig @127.0.0.1 "${SITE_DOMAIN}" +short >/dev/null || die "Local BIND test failed."
}

configure_bind_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y bind9 bind9-utils
  cp -a /etc/bind/named.conf.options /etc/bind/named.conf.options.bak.$(date +%Y%m%d%H%M%S)
  cat > /etc/bind/named.conf.options <<EOF
options {
        directory "/var/cache/bind";
        listen-on { any; };
        listen-on-v6 { any; };
        allow-query { any; };
        recursion no;
        dnssec-validation auto;
};
EOF
  ZONE_FILE="/etc/bind/db.${SITE_DOMAIN}"
  if ! grep -q "zone \"${SITE_DOMAIN}\"" /etc/bind/named.conf.local; then
    cat >> /etc/bind/named.conf.local <<EOF

zone "${SITE_DOMAIN}" {
    type master;
    file "${ZONE_FILE}";
};
EOF
  fi
  cat > "${ZONE_FILE}" <<EOF
\$TTL 86400
@   IN  SOA ${NS1_HOST}. admin.${SITE_DOMAIN}. (
        $(date +%Y%m%d01) ; Serial
        3600             ; Refresh
        1800             ; Retry
        1209600          ; Expire
        86400 )          ; Minimum TTL

@       IN  NS      ${NS1_HOST}.
@       IN  NS      ${NS2_HOST}.

@       IN  A       ${SERVER_PUBLIC_IP}
EOF
  if [[ "${WANT_WWW}" == "yes" ]]; then
    cat >> "${ZONE_FILE}" <<EOF
www     IN  CNAME   ${SITE_DOMAIN}.
EOF
  fi
  cat >> "${ZONE_FILE}" <<EOF
ns1     IN  A       ${NS1_IP}
ns2     IN  A       ${NS2_IP}
EOF
  named-checkzone "${SITE_DOMAIN}" "${ZONE_FILE}"
  named-checkconf
  systemctl enable --now bind9
  systemctl restart bind9
  dig @127.0.0.1 "${SITE_DOMAIN}" +short >/dev/null || die "Local BIND test failed."
}

configure_bind() {
  [[ "${INSTALL_BIND}" == "yes" ]] || return 0
  log "Installing and configuring BIND..."
  case "${OS_ID}" in
    almalinux) configure_bind_alma ;;
    ubuntu|debian) configure_bind_deb ;;
  esac
}

configure_firewall_alma() {
  dnf -y install firewalld
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  [[ "${INSTALL_BIND}" == "yes" ]] && firewall-cmd --permanent --add-service=dns
  firewall-cmd --reload
}

configure_firewall_deb() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ufw
  ufw allow OpenSSH
  ufw allow 'Apache Full'
  if [[ "${INSTALL_BIND}" == "yes" ]]; then
    ufw allow 53/tcp
    ufw allow 53/udp
  fi
  ufw --force enable
}

configure_firewall() {
  [[ "${CONFIGURE_FIREWALL}" == "yes" ]] || return 0
  log "Configuring firewall..."
  case "${FIREWALL_KIND}" in
    firewalld) configure_firewall_alma ;;
    ufw) configure_firewall_deb ;;
  esac
}

public_dns_points_here() {
  local host="$1"
  local expected="$2"
  local a1=""
  local a2=""
  a1="$(dig +short "${host}" @1.1.1.1 A | tail -n1 || true)"
  a2="$(dig +short "${host}" @8.8.8.8 A | tail -n1 || true)"
  [[ "${a1}" == "${expected}" || "${a2}" == "${expected}" ]]
}

install_certbot_any() {
  if have_cmd certbot; then
    return 0
  fi

  case "${OS_ID}" in
    almalinux)
      dnf -y install epel-release
      if dnf -y install certbot python3-certbot-apache; then
        have_cmd certbot && return 0
      fi
      dnf -y install snapd || return 1
      systemctl enable --now snapd.socket
      ;;
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      if apt-get install -y certbot python3-certbot-apache; then
        have_cmd certbot && return 0
      fi
      systemctl enable --now snapd >/dev/null 2>&1 || true
      ;;
  esac

  ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
  snap install core || return 1
  snap refresh core || true
  snap install --classic certbot || return 1
  ln -sf /snap/bin/certbot /usr/local/bin/certbot
  have_cmd certbot
}

certbot_preflight_checks() {
  log "Running Apache/HTTP checks before Let's Encrypt..."

  if ! systemctl is-active --quiet "${APACHE_SERVICE}"; then
    record_issue "${APACHE_SERVICE} is not active. Let's Encrypt was skipped."
    systemctl status "${APACHE_SERVICE}" --no-pager || true
    return 1
  fi

  if ! ss -ltn | awk '{print $1, $4}' | grep -Eq '^LISTEN .*(^|:|\\*)80$|^LISTEN .*:80$'; then
    record_issue "Nothing appears to be listening on port 80. Let's Encrypt was skipped."
    ss -tulnp | grep -E ':80|:443' || true
    return 1
  fi

  if [[ "${OS_ID}" == "almalinux" ]]; then
    if ! httpd -S >/tmp/serverwp-httpd-S.txt 2>&1; then
      record_issue "Apache vhost check failed. Let's Encrypt was skipped."
      cat /tmp/serverwp-httpd-S.txt || true
      return 1
    fi
  else
    if ! apache2ctl -S >/tmp/serverwp-apache2-S.txt 2>&1; then
      record_issue "Apache vhost check failed. Let's Encrypt was skipped."
      cat /tmp/serverwp-apache2-S.txt || true
      return 1
    fi
  fi

  local host=""
  local failed="no"
  for host in "${SITE_DOMAIN}" $( [[ "${WANT_WWW}" == "yes" ]] && echo "www.${SITE_DOMAIN}" ); do
    echo -e "${BLUE}[CHECK]${NC} http://${host}"
    local curl_out="/tmp/serverwp-curl-${host//[^A-Za-z0-9]/_}.txt"
    if ! curl -I --max-time 20 --connect-timeout 10 "http://${host}" >"${curl_out}" 2>&1; then
      record_issue "HTTP check failed for http://${host}. Let's Encrypt may fail until DNS, firewall, Cloudflare proxy, or Apache vhost routing is fixed."
      cat "${curl_out}" || true
      failed="yes"
    else
      head -n 5 "${curl_out}" || true
    fi
  done

  [[ "${failed}" == "no" ]]
}

request_ssl_if_ready() {
  [[ "${WANT_SSL}" == "yes" ]] || return 0
  log "Checking public DNS before Let's Encrypt..."
  local root_ready="no"
  local www_ready="no"
  public_dns_points_here "${SITE_DOMAIN}" "${SERVER_PUBLIC_IP}" && root_ready="yes"
  if [[ "${WANT_WWW}" == "yes" ]]; then
    public_dns_points_here "www.${SITE_DOMAIN}" "${SERVER_PUBLIC_IP}" && www_ready="yes"
  fi
  if [[ "${root_ready}" != "yes" ]]; then
    record_issue "Public DNS for ${SITE_DOMAIN} is not yet resolving to ${SERVER_PUBLIC_IP}. Certificate request skipped."
    return 0
  fi
  if [[ "${WANT_WWW}" == "yes" && "${www_ready}" != "yes" ]]; then
    record_issue "Public DNS for www.${SITE_DOMAIN} is not yet resolving to ${SERVER_PUBLIC_IP}. The certificate will be requested for ${SITE_DOMAIN} only."
  fi

  if ! certbot_preflight_checks; then
    record_issue "Preflight checks did not pass. Let's Encrypt was skipped so the site can still be reached over HTTP."
    return 0
  fi

  log "Installing Certbot..."
  if ! install_certbot_any; then
    record_issue "Certbot could not be installed automatically. The site is ready over HTTP; install certbot and request SSL manually."
    return 0
  fi
  log "Requesting Let's Encrypt certificate..."
  if [[ "${WANT_WWW}" == "yes" && "${www_ready}" == "yes" ]]; then
    if ! certbot --apache --non-interactive --agree-tos -m "${LE_EMAIL}" $( [[ "${FORCE_HTTPS}" == "yes" ]] && echo "--redirect" ) -d "${SITE_DOMAIN}" -d "www.${SITE_DOMAIN}"; then
      record_issue "Let's Encrypt request failed. Retry later once DNS/HTTP is fully ready."
      return 0
    fi
  else
    if ! certbot --apache --non-interactive --agree-tos -m "${LE_EMAIL}" $( [[ "${FORCE_HTTPS}" == "yes" ]] && echo "--redirect" ) -d "${SITE_DOMAIN}"; then
      record_issue "Let's Encrypt request failed. Retry later once DNS/HTTP is fully ready."
      return 0
    fi
  fi
  if [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" ]]; then
    log "Certificate installed successfully."
    "${WP_CLI}" option update home "https://${SITE_DOMAIN}" --path="${WEB_ROOT}" --allow-root
    "${WP_CLI}" option update siteurl "https://${SITE_DOMAIN}" --path="${WEB_ROOT}" --allow-root
  else
    record_issue "Certbot ran, but expected certificate files were not found."
  fi
}

final_checks() {
  log "Running final checks..."
  if [[ "${OS_ID}" == "almalinux" ]]; then
    httpd -t >/dev/null 2>&1 || die "Apache config validation failed."
  else
    apache2ctl configtest >/dev/null 2>&1 || die "Apache config validation failed."
  fi
  systemctl is-active --quiet "${APACHE_SERVICE}" || die "${APACHE_SERVICE} is not active."
  systemctl is-active --quiet "${DB_SERVICE}" || die "${DB_SERVICE} is not active."
  [[ -f "${WEB_ROOT}/wp-config.php" ]] || die "wp-config.php is missing."
}

print_summary() {
  local detected_php_version=""
  local detected_mariadb_version=""
  local detected_server_type=""

  detected_php_version="$(php -v 2>/dev/null | head -n1 | sed 's/^PHP //')"
  detected_mariadb_version="$(mysql --version 2>/dev/null | sed 's/^mysql  Ver //')"
  detected_server_type="${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"

  echo
  echo -e "${GREEN}====================================================${NC}"
  if [[ "${COMMAND}" == "add-site" ]]; then
    echo -e "${GREEN}Add-site complete. Your isolated WordPress site is ready.${NC}"
  else
    echo -e "${GREEN}Install complete. Your WordPress server is ready.${NC}"
  fi
  echo -e "${GREEN}====================================================${NC}"
  echo -e "${BLUE}Server Type:${NC}             ${detected_server_type}"
  echo -e "${BLUE}PHP Version:${NC}             ${detected_php_version:-Unknown}"
  echo -e "${BLUE}MariaDB Version:${NC}         ${detected_mariadb_version:-Unknown}"
  echo -e "${BLUE}Domain Name:${NC}             ${SITE_DOMAIN}"
  echo -e "${BLUE}WordPress Site Title:${NC}    ${SITE_TITLE}"
  echo -e "${BLUE}WordPress User Login:${NC}    ${ADMIN_USER}"
  echo -e "${BLUE}WordPress User Password:${NC} ${ADMIN_PASS}"
  echo -e "${GREEN}====================================================${NC}"
  echo -e "${YELLOW}Site URL:${NC}                http://${SITE_DOMAIN}"
  if [[ -f "/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem" ]]; then
    echo -e "${YELLOW}HTTPS URL:${NC}               https://${SITE_DOMAIN}"
  fi
  echo -e "${YELLOW}Web Root:${NC}                ${WEB_ROOT}"
  echo -e "${GREEN}====================================================${NC}"
  if (( ${#INSTALL_ISSUES[@]} > 0 )); then
    echo -e "${RED}Items that need attention:${NC}"
    local item=""
    for item in "${INSTALL_ISSUES[@]}"; do
      echo -e "${RED}- ${item}${NC}"
    done
    echo -e "${YELLOW}The install may have completed, but address the items above before considering the site fully ready.${NC}"
  else
    echo -e "${GREEN}No errors or skipped critical checks were recorded.${NC}"
  fi
  echo -e "${GREEN}====================================================${NC}"
}



collect_add_site_answers() {
  while true; do
    prompt_nonempty SITE_DOMAIN "New site domain (example.com): "
    SITE_DOMAIN="${SITE_DOMAIN,,}"
    validate_domain "${SITE_DOMAIN}" && break
    warn "Please enter a valid domain."
  done

  set_db_defaults_for_domain

  if [[ -e "${DOCROOT_BASE}/${SITE_DOMAIN}" ]]; then
    die "${DOCROOT_BASE}/${SITE_DOMAIN} already exists."
  fi
  if [[ -f "${APACHE_CONF_DIR}/${SITE_DOMAIN}.conf" ]]; then
    die "${APACHE_CONF_DIR}/${SITE_DOMAIN}.conf already exists."
  fi

  prompt_nonempty SITE_TITLE "WordPress site title: "
  prompt_nonempty ADMIN_USER "WordPress admin username: "
  prompt_hidden_nonempty ADMIN_PASS "WordPress admin password: "

  while true; do
    prompt_nonempty ADMIN_EMAIL "WordPress admin email: "
    validate_email "${ADMIN_EMAIL}" && break
    warn "Please enter a valid email address."
  done

  prompt_nonempty_default DB_NAME "MariaDB database name:" "${DEFAULT_GENERATED_DB_NAME}"
  prompt_nonempty_default DB_USER "MariaDB database username:" "${DEFAULT_GENERATED_DB_USER}"
  prompt_hidden_nonempty DB_PASS "MariaDB database password: "

  if [[ -n "${DEFAULT_SERVER_PUBLIC_IP:-}" ]]; then
    prompt_ipv4_default SERVER_PUBLIC_IP "Public server IPv4 address:" "${DEFAULT_SERVER_PUBLIC_IP}"
  else
    prompt_ipv4 SERVER_PUBLIC_IP "Public server IPv4 address: "
  fi

  prompt_yes_no WANT_WWW "Also configure www.${SITE_DOMAIN}?"
  prompt_yes_no WANT_SSL "Create Let's Encrypt certificate when DNS is ready?"
  if [[ "${WANT_SSL}" == "yes" ]]; then
    while true; do
      if [[ -n "${DEFAULT_LE_EMAIL:-}" ]]; then
        prompt_nonempty_default LE_EMAIL "Let's Encrypt email:" "${DEFAULT_LE_EMAIL}"
      else
        prompt_nonempty LE_EMAIL "Let's Encrypt email: "
      fi
      validate_email "${LE_EMAIL}" && break
      warn "Please enter a valid email address."
    done
  fi
  prompt_yes_no FORCE_HTTPS "Redirect HTTP to HTTPS after certificate is installed?"

  WANT_CLOUDFLARE="yes"
  INSTALL_BIND="no"
  CONFIGURE_FIREWALL="no"
  set_site_paths

  echo
  echo "================= ADD SITE SUMMARY ================="
  echo "Domain:         ${SITE_DOMAIN}"
  echo "WWW Alias:      ${WANT_WWW}"
  echo "Web root:       ${WEB_ROOT}"
  echo "Site user:      ${SITE_USER}"
  echo "PHP-FPM pool:   ${PHP_FPM_POOL_NAME}"
  echo "PHP-FPM socket: ${PHP_FPM_SOCKET}"
  echo "Database:       ${DB_NAME}"
  echo "Let's Encrypt:  ${WANT_SSL}"
  echo "===================================================="
  echo
  echo "Create DNS records before requesting SSL:"
  echo "  - A @ -> ${SERVER_PUBLIC_IP}"
  if [[ "${WANT_WWW}" == "yes" ]]; then
    echo "  - CNAME www -> ${SITE_DOMAIN}"
    echo "    or A www -> ${SERVER_PUBLIC_IP}"
  fi
  echo

  while true; do
    read -r -p "Proceed with adding this isolated site? [y/n]: " GO_AHEAD
    case "${GO_AHEAD,,}" in
      y|yes) break ;;
      n|no) die "Add-site cancelled." ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

collect_existing_site_for_migration() {
  while true; do
    prompt_nonempty EXISTING_SITE_DOMAIN "Existing site domain to migrate (example.com): "
    EXISTING_SITE_DOMAIN="${EXISTING_SITE_DOMAIN,,}"
    validate_domain "${EXISTING_SITE_DOMAIN}" && break
    warn "Please enter a valid domain."
  done
  EXISTING_SITE_ROOT="${DOCROOT_BASE}/${EXISTING_SITE_DOMAIN}"
  EXISTING_APACHE_SITE_CONF="${APACHE_CONF_DIR}/${EXISTING_SITE_DOMAIN}.conf"

  if [[ ! -d "${EXISTING_SITE_ROOT}" ]]; then
    die "Existing site root was not found: ${EXISTING_SITE_ROOT}"
  fi
  if [[ ! -f "${EXISTING_APACHE_SITE_CONF}" ]]; then
    die "Existing Apache vhost was not found: ${EXISTING_APACHE_SITE_CONF}"
  fi
}

migrate_existing_site_to_php_fpm() {
  local saved_domain="${SITE_DOMAIN:-}"
  SITE_DOMAIN="${EXISTING_SITE_DOMAIN}"
  set_site_paths
  WEB_ROOT="${EXISTING_SITE_ROOT}"
  SITE_ROOT="${EXISTING_SITE_ROOT}"
  APACHE_SITE_CONF="${EXISTING_APACHE_SITE_CONF}"
  PHP_FPM_POOL_CONF="${PHP_FPM_POOL_DIR}/${PHP_FPM_POOL_NAME}.conf"
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET_DIR}/${SITE_USER}.sock"

  if site_uses_php_fpm "${APACHE_SITE_CONF}"; then
    log "${SITE_DOMAIN} already appears to use PHP-FPM."
    SITE_DOMAIN="${saved_domain}"
    return 0
  fi

  configure_php_fpm_site
  chown -R "${SITE_USER}:${SITE_GROUP}" "${SITE_ROOT}"
  find "${SITE_ROOT}" -type d -exec chmod 755 {} \;
  find "${SITE_ROOT}" -type f -exec chmod 644 {} \;
  [[ -f "${WEB_ROOT}/wp-config.php" ]] && chmod 640 "${WEB_ROOT}/wp-config.php" || true

  cp -a "${APACHE_SITE_CONF}" "${APACHE_SITE_CONF}.pre-fpm.$(date +%Y%m%d%H%M%S)"
  if ! grep -q 'SetHandler "proxy:unix:' "${APACHE_SITE_CONF}"; then
    sed -i '/<\/Directory>/a\\\n    <FilesMatch \\.php$>\\\n        SetHandler "proxy:unix:'"${PHP_FPM_SOCKET}"'|fcgi://localhost/"\\\n    </FilesMatch>' "${APACHE_SITE_CONF}"
  fi
  restart_apache_checked
  SITE_DOMAIN="${saved_domain}"
}

offer_existing_site_migration() {
  if find "${APACHE_CONF_DIR}" -maxdepth 1 -name '*.conf' -type f -exec grep -Eq 'proxy:unix:|SetHandler "proxy:' {} \; -print -quit | grep -q .; then
    log "PHP-FPM Apache vhost mode already appears to be in use."
    return 0
  fi

  warn "No existing Apache vhost using PHP-FPM was detected."
  note "For better isolation, migrate the existing WordPress site before adding more sites."
  prompt_yes_no MIGRATE_EXISTING_SITE "Migrate an existing serverwp site to isolated PHP-FPM now?"
  [[ "${MIGRATE_EXISTING_SITE}" == "yes" ]] || return 0
  collect_existing_site_for_migration
  migrate_existing_site_to_php_fpm
}

add_site_main() {
  require_root
  detect_os
  detect_php_fpm_runtime || true
  show_banner
  show_intro
  run_step "Installing base tools..." install_base_packages
  run_step "Checking PHP-FPM isolation mode..." offer_existing_site_migration
  collect_add_site_answers
  run_step "Configuring isolated PHP-FPM site user and pool..." configure_php_fpm_site
  run_step "Configuring MariaDB database and user..." configure_mariadb
  run_step "Checking WP-CLI..." ensure_wp_cli
  run_step "Installing WordPress..." install_wordpress
  run_step "Installing UpdraftPlus..." install_updraftplus
  run_step "Setting WordPress file permissions..." set_wordpress_permissions
  run_step "Creating Apache vhost..." configure_apache_vhost
  if [[ "${WANT_SSL}" == "yes" ]]; then
    run_step "Attempting Let's Encrypt setup..." request_ssl_if_ready
  fi
  run_step "Running final checks..." final_checks
  print_summary
}

main() {
  validate_command
  if [[ "${COMMAND}" == "add-site" ]]; then
    add_site_main
    return
  fi
  require_root
  detect_os
  show_banner
  show_intro
  collect_answers
  run_step "Installing base packages..." install_base_packages
  run_step "Installing Apache and PHP-FPM..." install_apache_php
  run_step "Applying PHP tuning..." tune_php
  run_step "Configuring isolated PHP-FPM site user and pool..." configure_php_fpm_site
  run_step "Installing MariaDB..." install_mariadb
  run_step "Configuring MariaDB..." configure_mariadb
  run_step "Installing WP-CLI..." install_wp_cli
  run_step "Installing WordPress..." install_wordpress
  run_step "Installing UpdraftPlus..." install_updraftplus
  run_step "Setting WordPress file permissions..." set_wordpress_permissions
  run_step "Creating Apache vhost..." configure_apache_vhost
  if [[ "${INSTALL_BIND}" == "yes" ]]; then
    run_step "Configuring BIND..." configure_bind
  fi
  if [[ "${CONFIGURE_FIREWALL}" == "yes" ]]; then
    run_step "Configuring firewall..." configure_firewall
  fi
  if [[ "${WANT_SSL}" == "yes" ]]; then
    run_step "Attempting Let's Encrypt setup..." request_ssl_if_ready
  fi
  run_step "Running final checks..." final_checks
  print_summary
}

main "$@"
