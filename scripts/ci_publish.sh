#!/bin/bash

# CI-specific multi-suite APT repository publisher
# Builds a complete reprepro repository containing ALL suites:
# the newly-built suite from fresh .deb artifacts AND the other
# suites' packages imported from the live GitHub Pages repository.

# Abort on Error
set -euo pipefail

# Determine toolpath if not set already
relativepath="../" # Define relative path to go from this script to the root level of the tool
if [[ ! -v toolpath ]]; then scriptpath=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd ); toolpath=$(realpath --canonicalize-missing ${scriptpath}/${relativepath}); fi

# Load Configuration
source "${toolpath}/config.sh"

# Load Functions
source "${toolpath}/functions.sh"

# Set error trap AFTER sourcing
trap 'error_handler $? $LINENO "$BASH_SOURCE"' ERR

# ============================================
# Usage and Argument Parsing
# ============================================

usage() {
    echo "Usage: $(basename "$0") <suite> <deb-directory> <repo-url> <output-directory>"
    echo ""
    echo "  suite            Target suite being published: 'stable', 'edge', or 'nightly'"
    echo "  deb-directory    Path containing freshly built .deb files for this suite"
    echo "  repo-url         Live repository URL (e.g., https://slazarov.github.io/podman-debian)"
    echo "  output-directory Where to create the final multi-suite repository"
    echo ""
    echo "Environment variables:"
    echo "  GPG_PRIVATE_KEY  If set, imports this GPG key before signing (for CI)"
    echo ""
    echo "This script:"
    echo "  1. Builds the current suite using repo_manage.sh"
    echo "  2. Downloads the other suites' packages from the live repository"
    echo "  3. Adds the other suites' packages via reprepro includedeb"
    echo "  4. Produces a complete repository with all suites"
    exit 1
}

if [[ $# -lt 4 ]]; then
    usage
fi

SUITE="$1"
DEB_DIR="$2"
REPO_URL="$3"
OUTPUT_DIR="$4"

REPO_CONF="${toolpath}/packaging/repo"

# ============================================
# Validate Arguments
# ============================================

echo ""
echo "========================================"
echo ">>> CI Multi-Suite Repository Publisher"
echo "========================================"
echo ""

# Validate suite name
if [[ "${SUITE}" != "stable" && "${SUITE}" != "edge" && "${SUITE}" != "nightly" ]]; then
    echo "ERROR: Invalid suite '${SUITE}'. Must be 'stable', 'edge', or 'nightly'." >&2
    exit 1
fi

# Validate deb directory exists
if [[ ! -d "${DEB_DIR}" ]]; then
    echo "ERROR: deb-directory does not exist: ${DEB_DIR}" >&2
    exit 1
fi

# Validate deb directory contains .deb files
deb_count=$(find "${DEB_DIR}" -maxdepth 1 -name "*.deb" -type f | wc -l)
if [[ "${deb_count}" -eq 0 ]]; then
    echo "ERROR: No .deb files found in: ${DEB_DIR}" >&2
    exit 1
fi

# ============================================
# Step 1: Determine the OTHER suites
# ============================================

ALL_SUITES=(stable edge nightly)
OTHER_SUITES=()
for s in "${ALL_SUITES[@]}"; do
    if [[ "$s" != "${SUITE}" ]]; then
        OTHER_SUITES+=("$s")
    fi
done

echo "Current suite:  ${SUITE} (${deb_count} new packages)"
echo "Other suites:   ${OTHER_SUITES[*]} (will import from live repo)"
echo "Live repo:      ${REPO_URL}"
echo "Output dir:     ${OUTPUT_DIR}"
echo ""

# ============================================
# Step 2: Download other suites' .deb files from live repo
# ============================================

declare -A OTHER_SUITE_DEBS_DIRS
declare -A OTHER_SUITE_COUNTS
total_other_count=0

for other_suite in "${OTHER_SUITES[@]}"; do
    echo ">>> Downloading existing packages for '${other_suite}' suite..."
    other_dir=$(mktemp -d)
    OTHER_SUITE_DEBS_DIRS["${other_suite}"]="${other_dir}"
    suite_count=0

    for arch in amd64 arm64; do
        packages_url="${REPO_URL}/dists/${other_suite}/main/binary-${arch}/Packages"
        echo "  Fetching: ${packages_url}"

        packages_content=$(curl -sfL "${packages_url}" 2>/dev/null || true)

        if [[ -z "${packages_content}" ]]; then
            echo "  No Packages file for ${other_suite}/binary-${arch} (first deploy or not published)"
            continue
        fi

        # Parse Filename: lines from the Packages index
        while IFS= read -r filename; do
            if [[ -n "${filename}" ]]; then
                deb_url="${REPO_URL}/${filename}"
                deb_basename=$(basename "${filename}")

                # Skip if already downloaded (same package may appear in both arch indices)
                if [[ -f "${other_dir}/${deb_basename}" ]]; then
                    continue
                fi

                echo "  Downloading: ${deb_basename}"
                if curl -sfL -o "${other_dir}/${deb_basename}" "${deb_url}"; then
                    suite_count=$((suite_count + 1))
                else
                    echo "  WARNING: Failed to download ${deb_basename}, skipping" >&2
                    rm -f "${other_dir}/${deb_basename}"
                fi
            fi
        done <<< "$(echo "${packages_content}" | grep "^Filename:" | sed 's/^Filename: *//')"
    done

    OTHER_SUITE_COUNTS["${other_suite}"]=${suite_count}
    total_other_count=$((total_other_count + suite_count))
    echo ">>> Downloaded ${suite_count} packages for '${other_suite}' suite"
    echo ""
done

# ============================================
# Step 3: Build current suite with repo_manage.sh
# ============================================

echo ">>> Building '${SUITE}' suite with repo_manage.sh..."
echo ""

"${toolpath}/scripts/repo_manage.sh" "${SUITE}" "${DEB_DIR}" "${OUTPUT_DIR}"

echo ""

# ============================================
# Step 4: Add other suites' packages (if any were downloaded)
# ============================================

if [[ ${total_other_count} -gt 0 ]]; then
    echo ">>> Adding other suites' packages to repository..."
    echo ""

    # Rebuild conf/ (repo_manage.sh cleans it up after running)
    mkdir -p "${OUTPUT_DIR}/conf"
    cp "${REPO_CONF}/conf/distributions" "${OUTPUT_DIR}/conf/"
    cp "${REPO_CONF}/conf/options" "${OUTPUT_DIR}/conf/"

    for other_suite in "${OTHER_SUITES[@]}"; do
        suite_count=${OTHER_SUITE_COUNTS["${other_suite}"]}
        if [[ ${suite_count} -eq 0 ]]; then
            echo ">>> No packages for '${other_suite}' suite (first deploy or not published)"
            continue
        fi

        echo ">>> Adding '${other_suite}' suite packages..."
        other_added=0
        for deb_file in "${OTHER_SUITE_DEBS_DIRS["${other_suite}"]}"/*.deb; do
            if [[ -f "${deb_file}" ]]; then
                echo "  Adding: $(basename "${deb_file}")"
                reprepro -Vb "${OUTPUT_DIR}" includedeb "${other_suite}" "${deb_file}"
                other_added=$((other_added + 1))
            fi
        done
        echo ">>> Added ${other_added} packages to '${other_suite}' suite"

        # Export only this suite (not all — exporting all would clobber the current
        # suite's Packages file since the fresh db doesn't know about it)
        echo ">>> Exporting metadata for '${other_suite}' suite..."
        reprepro -b "${OUTPUT_DIR}" export "${other_suite}"
        echo ""
    done

    # Clean up reprepro internals
    rm -rf "${OUTPUT_DIR}/db" "${OUTPUT_DIR}/conf"
    echo ">>> Cleaned up reprepro internals"
    echo ""
else
    echo ">>> No packages for other suites (first deploy or no live repo)"
    echo ">>> Only '${SUITE}' suite will be published"
    echo ""
fi

# Clean up all temp dirs
for other_suite in "${OTHER_SUITES[@]}"; do
    rm -rf "${OTHER_SUITE_DEBS_DIRS["${other_suite}"]}"
done

# ============================================
# Step 5: Generate index.html landing page
# ============================================

echo ">>> Generating index.html landing page..."

# Collect available suites
available_suites=()
for s in stable edge nightly; do
    if [[ -d "${OUTPUT_DIR}/dists/${s}" ]]; then
        available_suites+=("${s}")
    fi
done

cat > "${OUTPUT_DIR}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Podman for Debian — APT Repository</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; color: #1a1a1a; line-height: 1.6; }
h1 { border-bottom: 2px solid #333; padding-bottom: 0.5rem; }
code, pre { background: #f4f4f4; border-radius: 4px; }
code { padding: 0.15em 0.4em; font-size: 0.9em; }
pre { padding: 1rem; overflow-x: auto; }
.tracks { display: flex; gap: 1rem; margin: 1.5rem 0; flex-wrap: wrap; }
.track { flex: 1; min-width: 280px; padding: 1rem; border: 1px solid #ddd; border-radius: 6px; }
.track h3 { margin-top: 0; }
.track.recommended { border-color: #2ea44f; }
.track.recommended h3::after { content: " (recommended)"; font-size: 0.8em; color: #2ea44f; font-weight: normal; }
.tab-group { margin: 1.5rem 0; }
.tab-buttons { display: flex; gap: 0; }
.tab-btn { padding: 0.5rem 1.5rem; border: 1px solid #ddd; background: #f4f4f4; cursor: pointer; font-size: 0.95em; }
.tab-btn:first-child { border-radius: 6px 0 0 0; }
.tab-btn:last-child { border-radius: 0 6px 0 0; }
.tab-btn.active { background: #fff; border-bottom-color: #fff; font-weight: 600; }
.tab-content { display: none; border: 1px solid #ddd; border-top: none; border-radius: 0 0 6px 6px; padding: 1rem; }
.tab-content.active { display: block; }
a { color: #0366d6; }
table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1.5rem; }
th, td { text-align: left; padding: 0.4rem 0.8rem; border: 1px solid #ddd; font-size: 0.9em; }
th { background: #f4f4f4; }
</style>
</head>
<body>
<h1>Podman for Debian — APT Repository</h1>
<p>Pre-built <code>.deb</code> packages for Podman and its dependencies on Debian (amd64 &amp; arm64).</p>

<h2>Choose a Track</h2>
<div class="tracks">
  <div class="track recommended">
    <h3>stable</h3>
    <p>Pinned, tested versions. Best for production and daily use.</p>
  </div>
  <div class="track">
    <h3>edge</h3>
    <p>Latest upstream tags. For testing new features before they reach stable.</p>
  </div>
  <div class="track">
    <h3>nightly</h3>
    <p>Built from upstream main branch HEAD daily. Bleeding-edge, may break.</p>
  </div>
</div>

<h2>Setup</h2>

<p>1. Import the signing key:</p>
<pre><code>curl -fsSL https://REPO_URL_PLACEHOLDER/podman-debian.gpg \
  | sudo tee /usr/share/keyrings/podman-debian.gpg > /dev/null</code></pre>

<p>2. Add the repository — pick your track:</p>
<div class="tab-group">
  <div class="tab-buttons">
    <button class="tab-btn active" onclick="showTab('stable')">stable</button>
    <button class="tab-btn" onclick="showTab('edge')">edge</button>
    <button class="tab-btn" onclick="showTab('nightly')">nightly</button>
  </div>
  <div id="tab-stable" class="tab-content active">
    <pre><code>echo "deb [signed-by=/usr/share/keyrings/podman-debian.gpg] https://REPO_URL_PLACEHOLDER stable main" \
  | sudo tee /etc/apt/sources.list.d/podman-debian.list</code></pre>
  </div>
  <div id="tab-edge" class="tab-content">
    <pre><code>echo "deb [signed-by=/usr/share/keyrings/podman-debian.gpg] https://REPO_URL_PLACEHOLDER edge main" \
  | sudo tee /etc/apt/sources.list.d/podman-debian.list</code></pre>
  </div>
  <div id="tab-nightly" class="tab-content">
    <pre><code>echo "deb [signed-by=/usr/share/keyrings/podman-debian.gpg] https://REPO_URL_PLACEHOLDER nightly main" \
  | sudo tee /etc/apt/sources.list.d/podman-debian.list</code></pre>
  </div>
</div>

<p>3. Install:</p>
<pre><code>sudo apt-get update
sudo apt-get install podman-suite</code></pre>
<p><code>podman-suite</code> is a meta-package that installs Podman and all its dependencies
(crun, conmon, netavark, aardvark-dns, pasta, buildah, skopeo, and more).</p>

<h2>Available Suites</h2>
HTMLEOF

# Append suite info dynamically (only suites with actual packages)
for s in "${available_suites[@]}"; do
    packages_file="${OUTPUT_DIR}/dists/${s}/main/binary-amd64/Packages"
    pkg_count=$(grep -c "^Package:" "${packages_file}" 2>/dev/null || true)
    pkg_count=${pkg_count:-0}

    # Skip suites with no packages (reprepro export creates empty dists/ for all configured suites)
    if [[ ${pkg_count} -eq 0 ]]; then
        continue
    fi

    cat >> "${OUTPUT_DIR}/index.html" << SUITEEOF
<h3>${s} — ${pkg_count} packages <a href="dists/${s}/InRelease" style="font-size:0.8em;font-weight:normal">[InRelease]</a></h3>
<table>
<tr><th>Package</th><th>Version</th></tr>
SUITEEOF

    awk '/^Package:/{pkg=$2} /^Version:/{print pkg, $2}' "${packages_file}" \
    | sort \
    | while read -r pkg ver; do
        cat >> "${OUTPUT_DIR}/index.html" << ROWEOF
<tr><td>${pkg}</td><td><code>${ver}</code></td></tr>
ROWEOF
    done

    cat >> "${OUTPUT_DIR}/index.html" << SUITEEOF
</table>
SUITEEOF
done

cat >> "${OUTPUT_DIR}/index.html" << 'HTMLEOF'

<h2>Resources</h2>
<ul>
<li><a href="podman-debian.gpg">GPG signing key</a></li>
<li><a href="https://github.com/slazarov/podman-debian">Source repository</a></li>
</ul>

<script>
function showTab(track) {
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
  document.querySelector('.tab-btn[onclick*="' + track + '"]').classList.add('active');
  document.getElementById('tab-' + track).classList.add('active');
}
</script>
</body>
</html>
HTMLEOF

# Replace placeholder with actual repo URL
sed -i "s|REPO_URL_PLACEHOLDER|${REPO_URL#https://}|g" "${OUTPUT_DIR}/index.html"

echo ">>> index.html generated"
echo ""

# ============================================
# Step 6: Summary
# ============================================

echo "========================================"
echo ">>> CI Repository Build Complete"
echo "========================================"
echo ""
echo "Current suite:  ${SUITE} (${deb_count} packages from build)"
for other_suite in "${OTHER_SUITES[@]}"; do
    echo "Other suite:    ${other_suite} (${OTHER_SUITE_COUNTS["${other_suite}"]} packages from live repo)"
done
echo "Output:         ${OUTPUT_DIR}"
echo ""

# List contents to confirm structure
echo "Repository structure:"
echo "----------------------------------------"
for suite_name in "${SUITE}" "${OTHER_SUITES[@]}"; do
    if [[ -d "${OUTPUT_DIR}/dists/${suite_name}" ]]; then
        echo "  dists/${suite_name}/"
        for f in "${OUTPUT_DIR}/dists/${suite_name}"/*; do
            if [[ -f "${f}" ]]; then
                echo "    $(basename "${f}")"
            elif [[ -d "${f}" ]]; then
                echo "    $(basename "${f}")/"
            fi
        done
    fi
done
if [[ -d "${OUTPUT_DIR}/pool" ]]; then
    echo "  pool/"
fi
if [[ -f "${OUTPUT_DIR}/podman-debian.gpg" ]]; then
    echo "  podman-debian.gpg"
fi
echo "----------------------------------------"
