# syntax=docker/dockerfile:1.6
#
# InferHaven custom Caddy image
#
# Why we ship our own image instead of consuming caddy:2-alpine directly:
#
# The previous compose service bound entrypoint.sh + the static HTML templates
# from ./docker/caddy into the upstream image at runtime. That works fine for
# top-level `docker compose up`, but in nested compose (`devpod up` from inside
# a running InferHaven workspace, or any other "compose-inside-compose" setup)
# the inner compose-CLI sends bind specs containing the INNER workspace path
# to the OUTER docker daemon. The daemon can't see that path, so the mount
# source ends up empty (or non-existent), the entrypoint silently exits 0,
# and the container restart-loops with empty logs.
#
# Baking the runtime files into the image removes the relative-path binds
# entirely. Build cost is ~3-5 s cold, negligible warm — see plan file.
FROM caddy:2-alpine

COPY entrypoint.sh /entrypoint.sh
COPY status.html   /srv/status.html
COPY denied.html   /srv/denied.html
COPY ide.html      /etc/caddy/ide.html.template

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
