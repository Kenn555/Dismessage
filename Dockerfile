# Dismessage relay server (WebSocket /ws + /health).
# Build context: repository root (the server depends on packages/protocol).

FROM dart:3.8 AS build
WORKDIR /src
COPY packages/protocol/pubspec.* packages/protocol/
COPY server/pubspec.* server/
WORKDIR /src/server
RUN dart pub get
WORKDIR /src
COPY packages/protocol packages/protocol
COPY server server
WORKDIR /src/server
RUN dart pub get --offline && dart compile exe bin/server.dart -o /src/dismessage-server

# Minimal runtime image: AOT binary + Dart runtime libraries only.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /src/dismessage-server /app/server
# Run by docker-compose.yml (VPS), which sets DISMESSAGE_IDS (on disk) and
# DISMESSAGE_ID_KEY (from .env: a random text of 32+ characters, never
# changed: changing it gives everyone a new ID). Not here, it is a secret.
# Without a proxy header, the client IP is the last X-Forwarded-For entry,
# set by Caddy.
ENV DISMESSAGE_IDS=/tmp/ids.json
# The web client is served by GitHub Pages, not by this container.
ENV DISMESSAGE_WEB=/nonexistent
EXPOSE 8080
CMD ["/app/server"]
