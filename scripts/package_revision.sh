#!/bin/bash
# package_revision.sh -- the packaging revision N in ~deb{VERSION_ID}.podmanN.
#
# Sourced by config.sh (build) and check_republish_needed.sh (republish
# guard) so the two always agree.
#
# Bump this whenever packaging changes (Depends, Conflicts, file paths,
# renames) without an upstream version change. Otherwise the rebuilt .debs
# carry the exact version string already published: apt never upgrades to an
# identical version, and ci_publish.sh keeps the already-published .deb of the
# same filename in the pool, discarding the new build. A bump changes every
# package's filename once, so the whole set republishes.
#
# History: 1 = initial.
export PACKAGE_REVISION="${PACKAGE_REVISION:-1}"
