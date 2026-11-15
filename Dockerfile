# Container mode: one agent per node (Docker host or Kubernetes DaemonSet).
#
#   docker run -d --name quickstatus-agent --restart unless-stopped \
#     --cap-drop ALL --security-opt no-new-privileges --read-only \
#     -e QUICKSTATUS_TOKEN=qse_... -v /:/host:ro -v quickstatus:/var/lib/quickstatus \
#     ghcr.io/quickstatushq/quickstatus-agent:X.Y.Z
#
# The host's / is mounted read-only so the agent can measure each host filesystem (df needs the
# mount point). It runs as uid 10001 with no capabilities, so it can read only what any
# unprivileged host user could: not root-only files (keys, credentials) and not root's sockets
# (docker.sock, containerd.sock).
FROM alpine:3.20
LABEL org.opencontainers.image.source="https://github.com/QuickStatusHQ/quickstatus-agent" \
      org.opencontainers.image.description="QuickStatus.dev server agent" \
      org.opencontainers.image.licenses="MIT"
RUN apk add --no-cache bash curl coreutils findutils tini \
 && addgroup -S -g 10001 quickstatus \
 && adduser -S -D -H -u 10001 -G quickstatus -h /var/lib/quickstatus -s /sbin/nologin quickstatus \
 && install -d -m 0700 -o quickstatus -g quickstatus /var/lib/quickstatus
COPY quickstatus-agent.sh /usr/local/bin/quickstatus-agent
ENV HOST_ROOT=/host
VOLUME /var/lib/quickstatus
USER 10001:10001
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/quickstatus-agent"]
CMD ["loop"]
