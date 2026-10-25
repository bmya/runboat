#!/bin/bash

#
# Download the code of the build into the data volume: the repo under test into
# $ADDONS_DIR and its extra addons repos into /mnt/data/extra-addons/<name>.
#
# Runs in the fetch job, the only pod with GITHUB_TOKEN. It never runs the code
# it downloads: runboat-clone-and-install.sh does that in the initialize job,
# which has no token and waits for the sentinel written at the end of this
# script. The sentinel carries RUNBOAT_INIT_NONCE, so a reinitialization never
# takes the data of a previous fetch for its own.
#

set -exo pipefail

FETCH_DONE=/mnt/data/.runboat-fetch-done
FETCH_FAILED=/mnt/data/.runboat-fetch-failed

trap 'echo "${RUNBOAT_INIT_NONCE} fetch failed at line ${LINENO}, see the fetch job log" > ${FETCH_FAILED}' ERR

# A repo or branch name taken from aggregation.yml, .gitmodules or the
# configuration ends up in a GitHub API URL sent with the token: anything else
# than plain names is refused.
valid_repo() { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$1" != *..* ]]; }
valid_ref() { [[ "$1" =~ ^[A-Za-z0-9_./-]+$ ]] && [[ "$1" != *..* ]]; }

# Remove initialization sentinel and data, in case we are reinitializing.
# The glob skips dotfiles: the fetch sentinels go explicitly.
rm -fr /mnt/data/* ${FETCH_DONE} ${FETCH_FAILED}

# Remove addons dir, in case we are reinitializing after a previously
# failed installation.
rm -fr $ADDONS_DIR
# Download the repository at git reference into $ADDONS_DIR.
# We use curl instead of git clone because the git clone method used more than 1GB RAM,
# which exceeded the default pod memory limit.
valid_repo "${RUNBOAT_GIT_REPO}"
valid_ref "${RUNBOAT_GIT_REF}"
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
# Isolated builds (RUNBOAT_ISOLATED=1, code written outside BMyA) take their
# dependencies only from RUNBOAT_EXTRA_ADDONS_REPOS, which BMyA configures. Their
# own aggregation.yml or .gitmodules could name any repo the token can read, and
# whatever is downloaded here is readable by the code under test.
EXTRA_ADDONS_SPECS=""
if [ "${RUNBOAT_ISOLATED:-0}" = "1" ]; then
    echo "Isolated build: ignoring the repo's aggregation.yml and .gitmodules."
elif [ -f "${ADDONS_DIR}/aggregation.yml" ]; then
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
# $(...) above drops the trailing newline: without putting it back, the first
# appended spec ends up glued to the last line of aggregation.yml/.gitmodules
# and neither repo is downloaded.
if [ -n "${EXTRA_ADDONS_SPECS}" ]; then
    EXTRA_ADDONS_SPECS+=$'\n'
fi
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
        if ! valid_repo "${REPO}" || ! valid_ref "${BRANCH}"; then
            echo "Warning: refusing extra repo spec '${REPO} ${BRANCH}'."
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
            echo "${EXTRA_DIR}" >> /mnt/data/extra-addons-paths
        elif compgen -G "${EXTRA_DIR}/addons/*/__manifest__.py" > /dev/null; then
            echo "${EXTRA_DIR}/addons" >> /mnt/data/extra-addons-paths
        else
            echo "Warning: no addons found in ${EXTRA_DIR}, skipping ADDONS_PATH entry."
        fi
    done <<< "${EXTRA_ADDONS_SPECS}"
fi

touch /mnt/data/extra-addons-paths
echo "${RUNBOAT_INIT_NONCE}" > ${FETCH_DONE}
