#!/bin/bash

#
# Clone repo and install all addons in the test database.
#

set -ex

bash /runboat/runboat-clone-and-install.sh

oca_wait_for_postgres

# Drop database, in case we are reinitializing.
dropdb --if-exists ${PGDATABASE}
dropdb --if-exists ${PGDATABASE}-baseonly

ADDONS=$(manifestoo --select-addons-dir ${ADDONS_DIR} --select-include "${INCLUDE}" --select-exclude "${EXCLUDE}" list --separator=,)

if [ -n "${OCA_INSTALL_EXTRA_MODULES:-}" ]; then
    if [ -n "$ADDONS" ]; then
        ADDONS="${ADDONS},${OCA_INSTALL_EXTRA_MODULES}"
    else
        ADDONS="${OCA_INSTALL_EXTRA_MODULES}"
    fi
fi

# Language. Up to Odoo 19 it is loaded together with the install. From 20 on it
# is loaded in a second step, once the addons are installed: with demo data and
# a non-English language active during the install, Odoo 20.0 fails (verified
# 2026-09-24 up to odoo 72d9be2f10f) when `l10n_us_account` auto-installs.
# account/models/ir_module.py reloads that module's demo with force_update on
# demo invoices that are already posted, and in es_419 the values differ:
# "You cannot modify the following readonly fields on the posted move
# INV/2026/00010". Loading the language afterwards only installs translations
# (base.language.install), so it never goes through that reload.
# ODOO_VERSION comes from the oca-ci image.
ODOO_MAJOR=$(echo "${ODOO_VERSION:-}" | grep -oE '^[0-9]+' || true)
LOAD_LANG_AFTER_INSTALL=""
ODOO_INIT_EXTRA_ARGS=""
if [ -n "${RUNBOAT_LOAD_LANG:-}" ]; then
    if [ "${ODOO_MAJOR:-0}" -ge 20 ]; then
        LOAD_LANG_AFTER_INSTALL="${RUNBOAT_LOAD_LANG}"
    else
        ODOO_INIT_EXTRA_ARGS="${ODOO_INIT_EXTRA_ARGS} --load-language=${RUNBOAT_LOAD_LANG}"
    fi
fi

# In Odoo 19+, demo data is not loaded by default. We enable it via $ODOO_RC,
# because --with-demo does not exists in previous version and would error out,
# while unknown options in the configuration file are ignored.
echo "with_demo = True" >> $ODOO_RC

# Create the baseonly database if installation failed.
unbuffer $(which odoo || which openerp-server) \
  --data-dir=/mnt/data/odoo-data-dir \
  --db-template=template1 \
  -d ${PGDATABASE}-baseonly \
  -i base \
  --stop-after-init

# Install all addons in the main DB. If it fails, drop the DB and exit with error
# so the build is reported as failed (visible in GitHub PR status checks).
# The previous behaviour (exit 0 on failure to leave the build running on the
# 'baseonly' DB) is no longer useful: the db-filter is anchored, so 'baseonly'
# is filtered out anyway, leaving the user with nothing.
if ! unbuffer $(which odoo || which openerp-server) \
    --data-dir=/mnt/data/odoo-data-dir \
    --db-template=template1 \
    -d ${PGDATABASE} \
    -i ${ADDONS:-base} \
    ${ODOO_INIT_EXTRA_ARGS} \
    --stop-after-init; then
    echo "[runboat-init] Module installation FAILED; dropping main DB."
    dropdb --if-exists ${PGDATABASE}
    exit 1
fi

# Second step of the language (Odoo 20+, see above). As the one-step load did,
# the admin (uid 2, same assumption as runboat-test.sh) is left in it.
if [ -n "${LOAD_LANG_AFTER_INSTALL}" ]; then
    if ! unbuffer $(which odoo || which openerp-server) \
        --data-dir=/mnt/data/odoo-data-dir \
        -d ${PGDATABASE} \
        --load-language=${LOAD_LANG_AFTER_INSTALL} \
        --stop-after-init; then
        echo "[runboat-init] Loading language ${LOAD_LANG_AFTER_INSTALL} FAILED; dropping main DB."
        dropdb --if-exists ${PGDATABASE}
        exit 1
    fi
    psql -d "${PGDATABASE}" -c "UPDATE res_partner SET lang='${LOAD_LANG_AFTER_INSTALL}' WHERE id=(SELECT partner_id FROM res_users WHERE id=2);" > /dev/null
fi

# Save installed modules list so runboat-test.sh can use mode "all".
echo "${ADDONS:-base}" > /mnt/data/test-modules.txt
