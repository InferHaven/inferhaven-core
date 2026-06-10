# syntax=docker/dockerfile:1.6
#
# InferHaven custom code-server image
#
# Bakes our custom-cont-init.d/ scripts into the linuxserver/code-server image
# instead of binding them at runtime. Same reason as docker/caddy/Dockerfile:
# under nested compose (devpod-in-devpod, haven devcontainer up of a compose-
# based project) relative-path binds in docker-compose.yml send INNER paths to
# the OUTER docker daemon, which silently creates empty source dirs on the
# outer host instead of seeing the actual files. Symptom: code-server's
# init scripts never run, and the phantom dirs pollute the workspace bind.
#
# Build cost: ~3-5 s cold (6 tiny shell scripts), cached thereafter.
# Edits to custom-cont-init.d/*.sh now need `docker compose up -d code-server
# --build` instead of `docker compose restart code-server` to take effect.
FROM lscr.io/linuxserver/code-server:latest

COPY custom-cont-init.d/ /custom-cont-init.d/

RUN chmod +x /custom-cont-init.d/*.sh
