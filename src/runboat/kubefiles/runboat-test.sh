#!/bin/bash

#
# Run Odoo tests on the already-initialized build database.
# Triggered by POST /builds/{name}/test via @robbmya {all-test|repo-test|pr-test}.
#
# TEST_MODULES (env var):
#   "all"           — all modules installed during init (read from /mnt/data/test-modules.txt)
#   "repo"          — only modules in the repo under test (ADDONS_DIR, via manifestoo)
#   "mod1,mod2,..." — explicit comma-separated list (pr-test)
#

set -ex

# Reconstruct ADDONS_PATH from cloned extra-addons, same logic as start.sh.
if [ -d /mnt/data/extra-addons ]; then
    for dir in /mnt/data/extra-addons/*/; do
        [ -d "$dir" ] || continue
        dir="${dir%/}"
        if compgen -G "${dir}/*/__manifest__.py" > /dev/null; then
            ADDONS_PATH="${ADDONS_PATH},${dir}"
        elif compgen -G "${dir}/addons/*/__manifest__.py" > /dev/null; then
            ADDONS_PATH="${ADDONS_PATH},${dir}/addons"
        fi
    done
fi

echo "addons_path=${ADDONS_PATH},${ADDONS_DIR}" >> $ODOO_RC

oca_wait_for_postgres

if [ "${TEST_MODULES:-}" = "all" ]; then
    TEST_MODULES=$(cat /mnt/data/test-modules.txt 2>/dev/null || echo "base")
elif [ "${TEST_MODULES:-}" = "repo" ]; then
    TEST_MODULES=$(manifestoo --select-addons-dir "${ADDONS_DIR}" list --separator=, 2>/dev/null || echo "base")
fi

echo "Running tests for modules: ${TEST_MODULES:-base}"

unbuffer $(which odoo || which openerp-server) \
  --data-dir=/mnt/data/odoo-data-dir \
  --db-filter=^${PGDATABASE}$ \
  -d ${PGDATABASE} \
  -u ${TEST_MODULES:-base} \
  --test-enable \
  --stop-after-init \
  --log-level=test
