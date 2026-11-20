FROM node:24-bookworm-slim

WORKDIR /app
COPY server.mjs ./
RUN install -d -m 0700 -o node -g node /var/lib/myenergy

ENV NODE_ENV=production \
    MYENERGY_HOST=0.0.0.0 \
    MYENERGY_PORT=8787 \
    MYENERGY_DATABASE=/var/lib/myenergy/myenergy.sqlite

USER node
EXPOSE 8787
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s \
    CMD ["node", "-e", "fetch('http://127.0.0.1:' + process.env.MYENERGY_PORT + '/healthz', { signal: AbortSignal.timeout(2000) }).then(response => { process.exitCode = response.ok ? 0 : 1 })"]
CMD ["node", "server.mjs"]
