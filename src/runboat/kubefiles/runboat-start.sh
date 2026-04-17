#!/bin/bash

#
# Start Odoo
#

set -ex

if [ ! -f /mnt/data/initialized ] ; then
    echo "Build is not initialized. Cannot start."
    exit 1
fi

# show what is installed (the venv in /opt/odoo-venv has been mounted)
pip list

# Make sure users cannot create databases.
echo "admin_passwd=$(python3 -c 'import secrets; print(secrets.token_hex())')" >> ${ODOO_RC}

# Add extra addons repos (cloned during init) to ADDONS_PATH.
# The init job exported ADDONS_PATH but that change is not persisted across pods,
# so we reconstruct it here by scanning /mnt/data/extra-addons/.
if [ -d /mnt/data/extra-addons ]; then
    for dir in /mnt/data/extra-addons/*/; do
        [ -d "$dir" ] && ADDONS_PATH="${ADDONS_PATH},${dir%/}"
    done
fi

# Add ADDONS_DIR to addons_path (because that oca_install_addons did,
# but $ODOO_RC is not on a persistent volume, so it is lost when we
# start in another container).
echo "addons_path=${ADDONS_PATH},${ADDONS_DIR}" >> ${ODOO_RC}
cat ${ODOO_RC}

# Install 'deb' external dependencies of all Odoo addons found in path.
# This is also something oca_install_addons did, but that is not persisted
# when we start in another container.
deb_deps=$(oca_list_external_dependencies deb)
if [ -n "$deb_deps" ]; then
    apt-get update -qq
    # Install 'deb' external dependencies of all Odoo addons found in path.
    DEBIAN_FRONTEND=noninteractive apt-get install -qq --no-install-recommends ${deb_deps}
fi

oca_wait_for_postgres

# --db_user is necessary for Odoo <= 10
ODOO_EXTRA_ARGS=""
if [ -n "${RUNBOAT_LOAD_LANG:-}" ]; then
    ODOO_EXTRA_ARGS="${ODOO_EXTRA_ARGS} --load-language=${RUNBOAT_LOAD_LANG}"
fi

unbuffer $(which odoo || which openerp-server) \
  --data-dir=/mnt/data/odoo-data-dir \
  --db-filter=^${PGDATABASE} \
  --db_user=${PGUSER} \
  --smtp=localhost \
  --smtp-port=1025 \
  ${ODOO_EXTRA_ARGS}