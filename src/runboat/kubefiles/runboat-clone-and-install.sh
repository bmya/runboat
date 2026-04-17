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

# Clone extra addons repos as dependencies for the build.
#
# Source of truth, in priority order:
#   1. aggregation.yml at repo root (OCA git-aggregator format): each entry's
#      `url` gives the org/repo and `branch` the ref to clone.
#   2. Fallback: RUNBOAT_EXTRA_ADDONS_REPOS env var (comma-separated org/repo list),
#      cloned at RUNBOAT_GIT_TARGET_BRANCH.
#
# Each cloned repo lands in /mnt/data/extra-addons/<repo-name> and is appended
# to ADDONS_PATH. Missing branches are silently skipped (warning only).
EXTRA_ADDONS_SPECS=""
if [ -f "${ADDONS_DIR}/aggregation.yml" ]; then
    echo "Using ${ADDONS_DIR}/aggregation.yml as source of truth for extra-addons."
    EXTRA_ADDONS_SPECS=$(python3 <<PYEOF
import re, yaml
try:
    data = yaml.safe_load(open("${ADDONS_DIR}/aggregation.yml")) or []
except Exception as e:
    print(f"# aggregation.yml parse error: {e}", flush=True)
    data = []
for e in data:
    if not isinstance(e, dict):
        continue
    url = str(e.get("url", "")).strip()
    branch = e.get("branch") or "${RUNBOAT_GIT_TARGET_BRANCH}"
    m = re.search(r"github\.com/([^/]+/[^/.]+?)(?:\.git)?/?\$", url)
    if m:
        print(f"{m.group(1)} {branch}")
PYEOF
)
elif [ -n "${RUNBOAT_EXTRA_ADDONS_REPOS:-}" ]; then
    echo "No aggregation.yml; using RUNBOAT_EXTRA_ADDONS_REPOS env var."
    for REPO in $(echo "${RUNBOAT_EXTRA_ADDONS_REPOS}" | tr ',' ' '); do
        EXTRA_ADDONS_SPECS+="${REPO} ${RUNBOAT_GIT_TARGET_BRANCH}"$'\n'
    done
fi

if [ -n "${EXTRA_ADDONS_SPECS}" ]; then
    while IFS=' ' read -r REPO BRANCH; do
        [ -z "${REPO}" ] && continue
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
        echo "Cloning extra repo ${REPO}@${BRANCH} into ${EXTRA_DIR}"
        curl -sSL "https://${GITHUB_TOKEN}@github.com/${REPO}/tarball/${BRANCH}" \
            | tar zxf - --strip-components=1 -C "${EXTRA_DIR}" \
            || echo "Warning: could not clone ${REPO}@${BRANCH}, skipping."
        export ADDONS_PATH="${ADDONS_PATH},${EXTRA_DIR}"
    done <<< "${EXTRA_ADDONS_SPECS}"
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