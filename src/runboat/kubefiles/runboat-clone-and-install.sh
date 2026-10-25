#!/bin/bash

set -exo pipefail

# The code is downloaded by the fetch job (runboat-fetch.sh), which has the
# GitHub token; this job has none and runs the code. Wait for the fetch job of
# this same initialization: its sentinel carries our RUNBOAT_INIT_NONCE.
FETCH_DONE=/mnt/data/.runboat-fetch-done
FETCH_FAILED=/mnt/data/.runboat-fetch-failed
for i in $(seq 1 450); do
    if [ "$(cat ${FETCH_FAILED} 2>/dev/null | cut -d' ' -f1)" = "${RUNBOAT_INIT_NONCE}" ]; then
        cat ${FETCH_FAILED}
        exit 1
    fi
    if [ "$(cat ${FETCH_DONE} 2>/dev/null)" = "${RUNBOAT_INIT_NONCE}" ]; then
        break
    fi
    if [ "$i" = 450 ]; then
        echo "The fetch job did not finish in 15 minutes."
        exit 1
    fi
    sleep 2
done

# Extra addons repos, in the order the fetch job resolved them.
while read -r EXTRA_PATH; do
    if [ -n "${EXTRA_PATH}" ]; then
        export ADDONS_PATH="${ADDONS_PATH},${EXTRA_PATH}"
    fi
done < /mnt/data/extra-addons-paths

cd $ADDONS_DIR

# Install.
INSTALL_METHOD=${INSTALL_METHOD:-oca_install_addons}
if [[ "${INSTALL_METHOD}" == "oca_install_addons" ]] ; then
    oca_install_addons
elif [[ "${INSTALL_METHOD}" == "editable_pip_install" ]] ; then
    pip install -e .
else
    echo "Unsupported INSTALL_METHOD: '${INSTALL_METHOD}'"
    exit 1
fi

# Keep a copy of the venv that we can re-use for shorter startup time.
cp -ar /opt/odoo-venv/ /mnt/data/odoo-venv

touch /mnt/data/initialized