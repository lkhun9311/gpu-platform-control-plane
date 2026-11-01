# shellcheck shell=bash
# The parts of hack/restart-lifecycle-kind.sh that decide whether a cluster is its own, whether its helpers are gone,
# and whether the rehearsal may report success, as functions, so hack/test/check-restart-kind-driver.sh can break each.
#
# Like hack/lib/restart-session.sh it never calls `set`, never `cd`s and installs no traps: those belong to the caller.

# rstk_cluster_listed NAME: 0 when kind lists NAME, 1 when it lists clusters and not NAME, 2 when the list cannot be read.
#
# A failed lookup is not "no cluster": read that way, the driver went on to create one, took ownership, and its cleanup
# would then remove a cluster of that name it had not made (codex review against origin/dev).
rstk_cluster_listed() {
  local listed
  listed="$(kind get clusters 2>&1)" || {
    echo "could not list the kind clusters: ${listed:0:200}" >&2
    return 2
  }
  # kind says this on stderr, merged above, when there are none; it is an answer, not a cluster's name.
  listed="$(grep -v '^No kind clusters found\.$' <<<"$listed")"
  if grep -qx -- "$1" <<<"$listed"; then return 0; fi
  return 1
}
