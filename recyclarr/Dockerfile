# The upstream image already has everything watch.sh needs (bash, supercronic, the recyclarr
# CLI) — this just swaps the entrypoint so scheduled syncs and Dojo-triggered on-demand syncs
# run from the same process instead of only supporting one or the other.
# :8 is the major-version tag recyclarr's own docs recommend — feature/bugfix releases
# automatically, manual bump only on a breaking change. Matches the v8 config schema the
# bundled templates (dojo/recyclarr-templates/) already declare.
FROM ghcr.io/recyclarr/recyclarr:8

COPY --chmod=555 watch.sh /watch.sh

ENTRYPOINT ["/sbin/tini", "--", "/watch.sh"]
