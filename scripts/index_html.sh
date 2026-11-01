#!/bin/bash

# index_html.sh -- defines generate_index_html, which writes the landing page
# (index.html) of the published APT repository. Sourced by ci_publish.sh.
#
# The setup snippets, distro toggle and package tables are generated from
# VALID_TRACKS, VALID_DISTROS and DISTRO_VERSION_IDS (config.sh), so adding a
# distro or track to config.sh updates the page too.

# html_escape -- escape the four HTML metacharacters on stdin. Package names
# and versions come from the Packages index, and nightly versions derive from
# upstream HEAD, so they are escaped before going into the page. `&` goes
# first so already-escaped entities are not double-escaped.
html_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

# generate_index_html <output-dir> <repo-url>
generate_index_html() {
    local lout="$1"
    local lrepo_url="$2"
    local lhost="${lrepo_url#https://}"
    local lpage="${lout}/index.html"
    local ldistro ltrack lfirst lhidden lactive lpkgs_file lpkg lver
    local -a lall_pkgs

    cat > "${lpage}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Podman for Debian: APT repository</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; color: #1a1a1a; line-height: 1.6; }
h1 { border-bottom: 2px solid #333; padding-bottom: 0.5rem; }
code, pre { background: #f4f4f4; border-radius: 4px; }
code { padding: 0.15em 0.4em; font-size: 0.9em; }
pre { padding: 1rem; overflow-x: auto; }
.tracks { display: flex; gap: 1rem; margin: 1.5rem 0; flex-wrap: wrap; }
.track { flex: 1; min-width: 280px; padding: 1rem; border: 1px solid #ddd; border-radius: 6px; }
.track h3 { margin-top: 0; }
.tab-group { margin: 1.5rem 0; }
.tab-buttons { display: flex; gap: 0; }
.tab-btn { padding: 0.5rem 1.5rem; border: 1px solid #ddd; background: #f4f4f4; cursor: pointer; font-size: 0.95em; }
.tab-btn:first-child { border-radius: 6px 0 0 0; }
.tab-btn:last-child { border-radius: 0 6px 0 0; }
.distro-group { margin: 1.5rem 0 0.5rem; }
.distro-btn { padding: 0.5rem 1.5rem; border: 1px solid #ddd; background: #f4f4f4; cursor: pointer; font-size: 0.95em; margin-right: 0.25rem; border-radius: 4px; }
.distro-btn.active { background: #fff; border-color: #333; font-weight: 600; }
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
<h1>Podman for Debian: APT repository</h1>
HTMLEOF

    {
        printf '<p>Podman and its dependencies, built from upstream source and packaged as <code>.deb</code> files for'
        lfirst=true
        for ldistro in "${VALID_DISTROS[@]}"; do
            [[ "${lfirst}" == "true" ]] || printf ' and'
            printf ' Debian %s (%s)' "${DISTRO_VERSION_IDS[${ldistro}]}" "${ldistro}"
            lfirst=false
        done
        printf ', amd64 only.</p>\n'
    } >> "${lpage}"

    cat >> "${lpage}" << 'HTMLEOF'

<h2>Tracks</h2>
<div class="tracks">
  <div class="track">
    <h3>stable</h3>
    <p>Podman 6.x. Follows new upstream releases within the 6.x series after a soak period. Use this one unless you have a reason not to.</p>
  </div>
  <div class="track">
    <h3>v5</h3>
    <p>Podman 5.x. Same update policy as stable, for hosts that are not ready for the changes in Podman 6.0.</p>
  </div>
  <div class="track">
    <h3>nightly</h3>
    <p>Built every day from the upstream main branch. Expect breakage.</p>
  </div>
</div>

<h2>Setup</h2>

<div class="distro-group">
  <strong>Your Debian release:</strong>
HTMLEOF

    lactive=" active"
    for ldistro in "${VALID_DISTROS[@]}"; do
        printf '  <button class="distro-btn%s" onclick="setDistro('"'"'%s'"'"')">Debian %s (%s)</button>\n' \
            "${lactive}" "${ldistro}" "${DISTRO_VERSION_IDS[${ldistro}]}" "${ldistro}" >> "${lpage}"
        lactive=""
    done

    cat >> "${lpage}" << HTMLEOF
</div>

<p>1. Import the signing key:</p>
<pre><code>sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://${lhost}/podman-debian.gpg \\
  | sudo tee /etc/apt/keyrings/podman-debian.gpg &gt; /dev/null</code></pre>

<p>2. Add the repository for one track:</p>
<div class="tab-group">
  <div class="tab-buttons">
HTMLEOF

    lactive=" active"
    for ltrack in "${VALID_TRACKS[@]}"; do
        printf '    <button class="tab-btn%s" onclick="showTab('"'"'%s'"'"')">%s</button>\n' \
            "${lactive}" "${ltrack}" "${ltrack}" >> "${lpage}"
        lactive=""
    done
    printf '  </div>\n' >> "${lpage}"

    lactive=" active"
    for ltrack in "${VALID_TRACKS[@]}"; do
        printf '  <div id="tab-%s" class="tab-content%s">\n' "${ltrack}" "${lactive}" >> "${lpage}"
        lactive=""
        lhidden=""
        for ldistro in "${VALID_DISTROS[@]}"; do
            cat >> "${lpage}" << HTMLEOF
    <pre class="snippet" data-distro="${ldistro}"${lhidden}><code>sudo tee /etc/apt/sources.list.d/podman-debian.sources &lt;&lt; 'EOF'
Types: deb
URIs: https://${lhost}
Suites: ${ltrack}-${ldistro}
Components: main
Signed-By: /etc/apt/keyrings/podman-debian.gpg
EOF</code></pre>
HTMLEOF
            lhidden=' style="display:none"'
        done
        printf '  </div>\n' >> "${lpage}"
    done

    cat >> "${lpage}" << 'HTMLEOF'
</div>

<p>3. Install:</p>
<pre><code>sudo apt-get update
sudo apt-get install podman-suite</code></pre>
<p><code>podman-suite</code> is a meta-package that installs Podman and the rest of the stack
(crun, conmon, netavark, aardvark-dns, pasta, buildah, skopeo, and others).</p>

<h2>Package versions</h2>
HTMLEOF

    # One table per distro: one row per package, one column per track.
    for ldistro in "${VALID_DISTROS[@]}"; do
        local -A lversions=()
        for ltrack in "${VALID_TRACKS[@]}"; do
            lpkgs_file="${lout}/dists/${ltrack}-${ldistro}/main/binary-amd64/Packages"
            [[ -f "${lpkgs_file}" ]] || continue
            while read -r lpkg lver; do
                lversions["${ltrack}|${lpkg}"]="${lver}"
            done < <(awk '/^Package:/{pkg=$2} /^Version:/{print pkg, $2}' "${lpkgs_file}")
        done

        # Union of package names across tracks. grep -v '^$' drops the empty
        # element printf emits when there are no keys at all.
        readarray -t lall_pkgs < <(
            for lpkg in "${!lversions[@]}"; do printf '%s\n' "${lpkg#*|}"; done \
            | grep -v '^$' | sort -u
        )
        [[ ${#lall_pkgs[@]} -gt 0 ]] || continue

        {
            printf '<h3>Debian %s (%s)</h3>\n' "${DISTRO_VERSION_IDS[${ldistro}]}" "${ldistro}"
            printf '<table>\n<tr><th>Package</th>'
            for ltrack in "${VALID_TRACKS[@]}"; do
                printf '<th>%s</th>' "${ltrack}"
            done
            printf '</tr>\n'
            for lpkg in "${lall_pkgs[@]}"; do
                printf '<tr><td>%s</td>' "$(printf '%s' "${lpkg}" | html_escape)"
                for ltrack in "${VALID_TRACKS[@]}"; do
                    printf '<td><code>%s</code></td>' \
                        "$(printf '%s' "${lversions[${ltrack}|${lpkg}]:-none}" | html_escape)"
                done
                printf '</tr>\n'
            done
            printf '</table>\n'
        } >> "${lpage}"
        unset lversions
    done

    cat >> "${lpage}" << 'HTMLEOF'

<h2>Links</h2>
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
function setDistro(name) {
  document.querySelectorAll('.distro-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('.distro-btn[onclick*="' + name + '"]').classList.add('active');
  document.querySelectorAll('.snippet').forEach(s => {
    s.style.display = s.dataset.distro === name ? '' : 'none';
  });
}
</script>
</body>
</html>
HTMLEOF
}
