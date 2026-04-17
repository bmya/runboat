#!/bin/bash

set -exo pipefail

# Remove initialization sentinel and data, in case we are reinitializing.
rm -fr /mnt/data/*

# Remove addons dir, in case we are reinitializing after a previously
# failed installation.
rm -fr $ADDONS_DIR
# Download the repository at git reference into $ADDONS_DIR.
# We use curl instead of git clone because the git clone method used more than 1GB RAM,
# which exceeded the default pod memory limit.
mkdir -p $ADDONS_DIR
cd $ADDONS_DIR
curl -sSL "https://${GITHUB_TOKEN}@github.com/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}" | tar zxf - --strip-components=1

# Clone extra addons repos (e.g. bmya/odoo, bmya/enterprise, bmya/design-themes).
# Repos are specified as a comma-separated list in RUNBOAT_EXTRA_ADDONS_REPOS.
# Each repo is cloned at the same branch as the tested repo (RUNBOAT_GIT_TARGET_BRANCH),
# with a silent fallback if the branch does not exist in that repo.
# Cloned repos are placed in /mnt/data/extra-addons/<repo-name> and appended to ADDONS_PATH.
if [ -n "${RUNBOAT_EXTRA_ADDONS_REPOS:-}" ]; then
    for REPO in $(echo "${RUNBOAT_EXTRA_ADDONS_REPOS}" | tr ',' ' '); do
        # Skip if this extra-addons repo is the same one being tested — it's
        # already cloned into $ADDONS_DIR and re-cloning would duplicate it
        # in ADDONS_PATH and cause module-definition conflicts.
        if [ "${REPO}" = "${RUNBOAT_GIT_REPO}" ]; then
            echo "Skipping extra repo ${REPO}: same as repo under test."
            continue
        fi
        REPO_NAME=$(basename "${REPO}")
        EXTRA_DIR="/mnt/data/extra-addons/${REPO_NAME}"
        mkdir -p "${EXTRA_DIR}"
        echo "Cloning extra repo ${REPO}@${RUNBOAT_GIT_TARGET_BRANCH} into ${EXTRA_DIR}"
        curl -sSL "https://${GITHUB_TOKEN}@github.com/${REPO}/tarball/${RUNBOAT_GIT_TARGET_BRANCH}" \
            | tar zxf - --strip-components=1 -C "${EXTRA_DIR}" \
            || echo "Warning: could not clone ${REPO}@${RUNBOAT_GIT_TARGET_BRANCH}, skipping."
        export ADDONS_PATH="${ADDONS_PATH},${EXTRA_DIR}"
    done
fi

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