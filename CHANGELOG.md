# Changelog

All notable changes to serverwp will be documented in this file.

## v4.1.9

- Added `add-site` mode for adding isolated WordPress sites to an existing serverwp server.
- Added per-site PHP-FPM pool support with dedicated Linux users, sockets, and Apache vhost routing.
- Added an optional migration prompt for existing non-FPM serverwp sites before adding more sites.
- Improved Certbot installation for AlmaLinux and made SSL setup failures non-fatal after site creation.
- Added `serverwp-remove-site.sh` for deliberately removing a serverwp-created site, including files, vhost, PHP-FPM pool, Linux user, database, and database user.

## v4.1.8

First stable release.

- Provides a Bash-based WordPress server bootstrap workflow for AlmaLinux, Ubuntu, and Debian.
- Installs and configures Apache, PHP, MariaDB, WP-CLI, WordPress, and UpdraftPlus.
- Includes firewall setup, optional DNS guidance, and Let's Encrypt SSL support.
