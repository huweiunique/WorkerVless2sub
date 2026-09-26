FROM node:20-alpine

WORKDIR /app

COPY _worker.js ./worker.mjs
COPY docker/server.mjs ./server.mjs

ENV PORT=8787
EXPOSE 8787

CMD ["node", "server.mjs"]
