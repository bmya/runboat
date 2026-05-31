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
{ set +x; } 2>/dev/null
curl -sSL -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/${RUNBOAT_GIT_REPO}/tarball/${RUNBOAT_GIT_REF}" \
    | tar zxf - --strip-components=1
set -x

# Clone extra addons repos as dependencies for the build.
#
# Source of truth, in priority order:
#   1. aggregation.yml at repo root (OCA git-aggregator format): each entry's
#      `url` gives the org/repo and `branch` the ref to clone.
#   2. .gitmodules at repo root (client project layout): each [submodule "X"]
#      gives `url` and `branch`. The branch HEAD is fetched (NOT the gitlink
#      SHA pinned in the tree) so the build reflects the latest available
#      version of each dependency, matching what production picks up on
#      `git submodule update --remote`.
#
# ADDITIVE on top of 1/2 (not a fallback): RUNBOAT_EXTRA_ADDONS_REPOS env var,
# a comma-separated list of `org/repo` or `org/repo@branch`. Used to inject
# dependencies the repo itself does NOT declare — e.g. base Odoo + Enterprise +
# design-themes for client project repos, which keep their own addons as git
# submodules (so a developer's `git submodule add` is picked up automatically
# via .gitmodules) while Enterprise comes from the baked image in production.
# Pin with @branch (e.g. bmya/enterprise@18.0) since these live on the Odoo
# version branch, not the repo's prd/sta target branch. Defaults to
# RUNBOAT_GIT_TARGET_BRANCH when @branch is omitted.
#
# Each cloned repo lands in /mnt/data/extra-addons/<repo-name> and is appended
# to ADDONS_PATH. Missing branches are silently skipped (warning only).
EXTRA_ADDONS_SPECS=""
if [ -f "${ADDONS_DIR}/aggregation.yml" ]; then
    echo "Using ${ADDONS_DIR}/aggregation.yml as source of truth for extra-addons."
    # Minimal line-based parser (no PyYAML in the OCA CI image). Works with the
    # canonical format we emit: each entry has `- url: ...` followed by `branch: "..."`.
    EXTRA_ADDONS_SPECS=$(python3 <<PYEOF
import re
cur_url = None
default_branch = "${RUNBOAT_GIT_TARGET_BRANCH}"
try:
    with open("${ADDONS_DIR}/aggregation.yml") as f:
        lines = f.readlines()
except Exception as e:
    print(f"# aggregation.yml read error: {e}", flush=True)
    lines = []
for line in lines:
    m = re.match(r"^\s*-\s*url:\s*(.+?)\s*\$", line)
    if m:
        cur_url = m.group(1).strip().strip('"').strip("'")
        cur_branch = default_branch
        continue
    m = re.match(r"^\s+branch:\s*(.+?)\s*\$", line)
    if m and cur_url:
        cur_branch = m.group(1).strip().strip('"').strip("'")
        gm = re.search(r"github\.com/([^/]+/[^/.]+?)(?:\.git)?/?\$", cur_url)
        if gm:
            print(f"{gm.group(1)} {cur_branch}")
        cur_url = None
PYEOF
)
elif [ -f "${ADDONS_DIR}/.gitmodules" ]; then
    echo "No aggregation.yml; using ${ADDONS_DIR}/.gitmodules as source of truth for extra-addons."
    # Parse .gitmodules and fetch each submodule at the branch HEAD declared
    # in its entry. Supports both HTTPS (https://github.com/org/repo.git)
    # and SSH (git@github.com:org/repo.git) URL forms.
    EXTRA_ADDONS_SPECS=$(python3 <<PYEOF
import re
default_branch = "${RUNBOAT_GIT_TARGET_BRANCH}"
try:
    with open("${ADDONS_DIR}/.gitmodules") as f:
        text = f.read()
except Exception as e:
    print(f"# .gitmodules read error: {e}", flush=True)
    text = ""
# Split into per-submodule blocks: [submodule "X"] ... [submodule "Y"] ...
blocks = re.split(r"\[submodule\s+\"[^\"]+\"\]", text)[1:]
for block in blocks:
    url_m = re.search(r"^\s*url\s*=\s*(.+?)\s*\$", block, re.MULTILINE)
    if not url_m:
        continue
    url = url_m.group(1).strip()
    br_m = re.search(r"^\s*branch\s*=\s*(.+?)\s*\$", block, re.MULTILINE)
    branch = br_m.group(1).strip() if br_m else default_branch
    # Extract org/repo. https://github.com/org/repo(.git)? or git@github.com:org/repo(.git)?
    gm = re.search(r"github\.com[:/]([^/]+/[^/.]+?)(?:\.git)?/?\$", url)
    if gm:
        print(f"{gm.group(1)} {branch}")
PYEOF
)
fi

# Additive: append RUNBOAT_EXTRA_ADDONS_REPOS specs regardless of whether
# aggregation.yml or .gitmodules was the primary source. Each spec is
# `org/repo` (cloned at RUNBOAT_GIT_TARGET_BRANCH) or `org/repo@branch`.
if [ -n "${RUNBOAT_EXTRA_ADDONS_REPOS:-}" ]; then
    echo "Appending RUNBOAT_EXTRA_ADDONS_REPOS: ${RUNBOAT_EXTRA_ADDONS_REPOS}"
    for SPEC in $(echo "${RUNBOAT_EXTRA_ADDONS_REPOS}" | tr ',' ' '); do
        case "${SPEC}" in
            *@*) EXTRA_REPO="${SPEC%@*}"; EXTRA_BRANCH="${SPEC#*@}";;
            *)   EXTRA_REPO="${SPEC}";    EXTRA_BRANCH="${RUNBOAT_GIT_TARGET_BRANCH}";;
        esac
        EXTRA_ADDONS_SPECS+="${EXTRA_REPO} ${EXTRA_BRANCH}"$'\n'
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
        { set +x; } 2>/dev/null
        curl -sSL -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${REPO}/tarball/${BRANCH}" \
            | tar zxf - --strip-components=1 -C "${EXTRA_DIR}" \
            || echo "Warning: could not clone ${REPO}@${BRANCH}, skipping."
        set -x
        # Detect where the addons live: root, <dir>/addons (Odoo CE/EE fork
        # layout), or skip if neither has __manifest__.py files.
        if compgen -G "${EXTRA_DIR}/*/__manifest__.py" > /dev/null; then
            export ADDONS_PATH="${ADDONS_PATH},${EXTRA_DIR}"
        elif compgen -G "${EXTRA_DIR}/addons/*/__manifest__.py" > /dev/null; then
            export ADDONS_PATH="${ADDONS_PATH},${EXTRA_DIR}/addons"
        else
            echo "Warning: no addons found in ${EXTRA_DIR}, skipping ADDONS_PATH entry."
        fi
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