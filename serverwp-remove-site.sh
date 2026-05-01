#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="serverwp-remove-site"
SCRIPT_VERSION="4.1.8"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
note() { echo -e "${BLUE}[NOTE]${NC} $*"; }
die()  { err "$*"; exit 1; }

trap 'err "Script failed at line $LINENO"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

validate_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

prompt_nonempty() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while true; do
    read -r -p "$prompt_text" value
    if [[ -n "${value}" ]]; then
      printf -v "${var_name}" '%s' "${value}"
      return
    fi
    warn "This field cannot be empty."
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
      DOCROOT_BASE="/var/www"
      PHP_FPM_SERVICE="php-fpm"
      PHP_FPM_POOL_DIR="/etc/php-fpm.d"
      PHP_FPM_SOCKET_DIR="/run/php-fpm"
      ;;
    ubuntu)
      [[ "${OS_VERSION_MAJOR}" == "22" || "${OS_VERSION_MAJOR}" == "24" ]] || die "This script supports Ubuntu 22.04 or 24.04."
      APACHE_SERVICE="apache2"
      APACHE_CONF_DIR="/etc/apache2/sites-available"
      DOCROOT_BASE="/var/www"
      PHP_FPM_SOCKET_DIR="/run/php"
      ;;
    debian)
      [[ "${OS_VERSION_MAJOR}" == "12" || "${OS_VERSION_MAJOR}" == "13" ]] || die "This script supports Debian 12 or 13."
      APACHE_SERVICE="apache2"
      APACHE_CONF_DIR="/etc/apache2/sites-available"
      DOCROOT_BASE="/var/www"
      PHP_FPM_SOCKET_DIR="/run/php"
      ;;
    *)
      die "Unsupported OS. Use AlmaLinux 9, Ubuntu 22.04/24.04, or Debian 12/13."
      ;;
  esac
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

set_site_paths() {
  SITE_ROOT="${DOCROOT_BASE}/${SITE_DOMAIN}"
  APACHE_SITE_CONF="${APACHE_CONF_DIR}/${SITE_DOMAIN}.conf"
  APACHE_SSL_SITE_CONF="${APACHE_CONF_DIR}/${SITE_DOMAIN}-le-ssl.conf"
  SITE_USER="$(sanitize_identifier "wp_" "${SITE_DOMAIN}" 32)"
  PHP_FPM_POOL_NAME="${SITE_USER}"
  PHP_FPM_POOL_CONF="${PHP_FPM_POOL_DIR}/${PHP_FPM_POOL_NAME}.conf"
  PHP_FPM_SOCKET="${PHP_FPM_SOCKET_DIR}/${SITE_USER}.sock"
}

detect_wp_db_credentials() {
  DB_NAME=""
  DB_USER=""

  local wp_config="${SITE_ROOT}/wp-config.php"
  [[ -f "${wp_config}" ]] || return 0

  DB_NAME="$(awk -F"'" '/DB_NAME/ {print $4; exit}' "${wp_config}" || true)"
  DB_USER="$(awk -F"'" '/DB_USER/ {print $4; exit}' "${wp_config}" || true)"
}

collect_answers() {
  while true; do
    prompt_nonempty SITE_DOMAIN "Site domain to remove (example.com): "
    SITE_DOMAIN="${SITE_DOMAIN,,}"
    validate_domain "${SITE_DOMAIN}" && break
    warn "Please enter a valid domain."
  done

  detect_php_fpm_runtime || true
  set_site_paths
  detect_wp_db_credentials

  if [[ -z "${DB_NAME}" ]]; then
    prompt_nonempty DB_NAME "MariaDB database name to remove: "
  fi
  if [[ -z "${DB_USER}" ]]; then
    prompt_nonempty DB_USER "MariaDB database user to remove: "
  fi

  echo
  echo "================ REMOVE SITE SUMMARY ================"
  echo "Domain:          ${SITE_DOMAIN}"
  echo "Web root:        ${SITE_ROOT}"
  echo "Apache vhost:    ${APACHE_SITE_CONF}"
  echo "Apache SSL vhost:${APACHE_SSL_SITE_CONF}"
  echo "Site user:       ${SITE_USER}"
  echo "PHP-FPM pool:    ${PHP_FPM_POOL_CONF}"
  echo "PHP-FPM socket:  ${PHP_FPM_SOCKET}"
  echo "Database:        ${DB_NAME}"
  echo "Database user:   ${DB_USER}"
  echo "====================================================="
  echo
  warn "This permanently deletes the site's files, Apache vhost, PHP-FPM pool, Linux user, database, and database user."
  warn "Make sure you have a backup before continuing."
  echo

  local confirmation=""
  read -r -p "TYPE \"REMOVE ${SITE_DOMAIN}\" TO CONTINUE: " confirmation
  [[ "${confirmation}" == "REMOVE ${SITE_DOMAIN}" ]] || die "Removal cancelled."
}

remove_certbot_certificate() {
  if ! command -v certbot >/dev/null 2>&1; then
    return 0
  fi
  if [[ -d "/etc/letsencrypt/live/${SITE_DOMAIN}" ]]; then
    log "Removing Let's Encrypt certificate for ${SITE_DOMAIN}..."
    certbot delete --cert-name "${SITE_DOMAIN}" --non-interactive || warn "Could not remove certificate ${SITE_DOMAIN}; continuing."
  fi
}

remove_apache_vhost() {
  if [[ "${OS_ID}" == "ubuntu" || "${OS_ID}" == "debian" ]]; then
    a2dissite "${SITE_DOMAIN}.conf" >/dev/null 2>&1 || true
    a2dissite "${SITE_DOMAIN}-le-ssl.conf" >/dev/null 2>&1 || true
  fi

  if [[ -f "${APACHE_SITE_CONF}" ]]; then
    log "Removing Apache vhost ${APACHE_SITE_CONF}..."
    rm -f "${APACHE_SITE_CONF}"
  else
    warn "Apache vhost not found: ${APACHE_SITE_CONF}"
  fi

  if [[ -f "${APACHE_SSL_SITE_CONF}" ]]; then
    log "Removing Apache SSL vhost ${APACHE_SSL_SITE_CONF}..."
    rm -f "${APACHE_SSL_SITE_CONF}"
  else
    warn "Apache SSL vhost not found: ${APACHE_SSL_SITE_CONF}"
  fi
}

remove_php_fpm_pool() {
  if [[ -f "${PHP_FPM_POOL_CONF}" ]]; then
    log "Removing PHP-FPM pool ${PHP_FPM_POOL_CONF}..."
    rm -f "${PHP_FPM_POOL_CONF}"
  else
    warn "PHP-FPM pool not found: ${PHP_FPM_POOL_CONF}"
  fi

  if [[ -S "${PHP_FPM_SOCKET}" || -e "${PHP_FPM_SOCKET}" ]]; then
    rm -f "${PHP_FPM_SOCKET}"
  fi
}

remove_database() {
  local db_client=""
  if command -v mariadb >/dev/null 2>&1; then
    db_client="mariadb"
  elif command -v mysql >/dev/null 2>&1; then
    db_client="mysql"
  else
    die "Neither mariadb nor mysql client was found."
  fi

  log "Removing MariaDB database and user..."
  "${db_client}" -uroot <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

remove_site_files() {
  if [[ -d "${SITE_ROOT}" ]]; then
    log "Removing site files ${SITE_ROOT}..."
    rm -rf "${SITE_ROOT}"
  else
    warn "Site root not found: ${SITE_ROOT}"
  fi
}

remove_site_user() {
  if id "${SITE_USER}" >/dev/null 2>&1; then
    log "Removing Linux user ${SITE_USER}..."
    userdel "${SITE_USER}" || warn "Could not remove user ${SITE_USER}; continuing."
  else
    warn "Linux user not found: ${SITE_USER}"
  fi
}

restart_services() {
  log "Validating Apache configuration..."
  if [[ "${OS_ID}" == "almalinux" ]]; then
    httpd -t
  else
    apache2ctl configtest
  fi

  log "Restarting services..."
  systemctl restart "${PHP_FPM_SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${APACHE_SERVICE}"
}

main() {
  require_root
  detect_os
  echo
  echo "===================================================="
  echo "${SCRIPT_NAME} v${SCRIPT_VERSION}"
  echo "OS: ${OS_ID} ${OS_VERSION_ID}"
  echo "===================================================="
  collect_answers
  remove_certbot_certificate
  remove_apache_vhost
  remove_php_fpm_pool
  remove_database
  remove_site_files
  remove_site_user
  restart_services
  log "Removed ${SITE_DOMAIN}."
}

main "$@"
