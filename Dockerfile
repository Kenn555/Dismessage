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
# Render's free plan has no persistent disk: IDs are re-claimed by their
# owners (same secret) when they reconnect after a restart.
ENV DISMESSAGE_IDS=/tmp/ids.json
# The web client is served by GitHub Pages, not by this container.
ENV DISMESSAGE_WEB=/nonexistent
EXPOSE 8080
CMD ["/app/server"]
