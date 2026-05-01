# serverwp

A Bash-based WordPress server bootstrap script for AlmaLinux, Ubuntu, and Debian.

Installs Apache, PHP, MariaDB, WP-CLI, WordPress, UpdraftPlus, optional DNS guidance, firewall setup, and Let's Encrypt SSL.


## Usage

Fresh server install:

```bash
sudo ./serverwp.sh
```

Add another isolated WordPress site to an existing serverwp server:

```bash
sudo ./serverwp.sh add-site
```

The add-site mode checks whether existing Apache virtual hosts are already using PHP-FPM. If not, it offers to migrate an existing serverwp site to an isolated PHP-FPM pool before adding the next site.


Remove a site created by serverwp:

```bash
sudo ./serverwp-remove-site.sh
```

The removal script asks for the site domain, detects the WordPress database credentials from `wp-config.php` when possible, and requires a typed confirmation before deleting files, the Apache vhost, PHP-FPM pool, Linux user, database, and database user.
