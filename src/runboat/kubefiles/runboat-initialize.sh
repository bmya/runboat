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

ODOO_INIT_EXTRA_ARGS=""
if [ -n "${RUNBOAT_LOAD_LANG:-}" ]; then
    ODOO_INIT_EXTRA_ARGS="${ODOO_INIT_EXTRA_ARGS} --load-language=${RUNBOAT_LOAD_LANG}"
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

# Save installed modules list so runboat-test.sh can use mode "all".
echo "${ADDONS:-base}" > /mnt/data/test-modules.txt
