# Use Ubuntu 24.04 (Noble) as the base
FROM ubuntu:noble AS builder

ENV NODE_ENV="production"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
      build-essential \
      python3-setuptools \
      ca-certificates \
      curl \
      gnupg \
      pkg-config \
      xvfb \
      libglfw3-dev \
      libuv1-dev \
      libcairo2-dev \
      libpango1.0-dev \
      libpng-dev \
      libjpeg-dev \
      libgif-dev \
      librsvg2-dev \
      libcurl4-openssl-dev \
      libicu-dev && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests nodejs && \
    # Deliberately NOT `npm i -g npm@latest`: npm 12 blocks package install
    # scripts by default (allowScripts), which silently skips the native builds
    # for canvas, sqlite3 and @maplibre/maplibre-gl-native and produces an image
    # that builds fine and then crashes on startup with "Could not locate the
    # bindings file". Use the npm bundled with the pinned Node instead.
    apt-get -y remove curl gnupg && \
    apt-get -y --purge autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/src/app

WORKDIR /usr/src/app

COPY package.json package-lock.json ./

RUN npm config set fetch-retries 5 && \
    npm config set fetch-retry-mintimeout 100000 && \
    npm config set fetch-retry-maxtimeout 600000 && \
    npm ci --omit=dev && \
    # Build canvas from source for the Noble architecture
    # `--build-from-source` was never a real npm flag -- npm just forwarded it as
    # npm_config_build_from_source and npm 12 made unknown flags fatal. Set the
    # env var directly: same mechanism, portable across npm versions.
    npm_config_build_from_source=true npm rebuild canvas && \
    chown -R root:root /usr/src/app

# --- Final Stage ---
FROM ubuntu:noble AS final

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN export DEBIAN_FRONTEND=noninteractive && \
    groupadd -r node && \
    useradd -r -g node node && \
    apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests \
      ca-certificates \
      curl \
      gnupg \
      xvfb \
      libglfw3 \
      libuv1 \
      libicu74 \
      libcairo2 \
      libjpeg-turbo8 \
      libgif7 \
      libpng16-16t64 \
      libopengl0 \
      libcurl4 \
      librsvg2-dev \
      libpango-1.0-0 \
      libjemalloc2 && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends --no-install-suggests nodejs && \
    # Create appropriate symlinks if needed
    ln -sf "$(find /usr -name "libjemalloc.so*" | head -n 1)" /usr/lib/libjemalloc.so && \
    apt-get -y remove curl gnupg && \
    apt-get -y --purge autoremove && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/node/.aws && \
    chown -R node:node /home/node

ENV \
    NODE_ENV="production" \
    CHOKIDAR_USEPOLLING=1 \
    CHOKIDAR_INTERVAL=500 \
    LD_PRELOAD="/usr/lib/libjemalloc.so" \
    MALLOC_CONF="background_thread:true,metadata_thp:auto,dirty_decay_ms:5000,muzzy_decay_ms:5000"

COPY --from=builder /usr/src/app /usr/src/app
COPY . /usr/src/app

# The image built cleanly while every native module was missing, because npm 12
# silently skips install scripts. Fail the build instead of the container.
RUN node -e "require('/usr/src/app/node_modules/@maplibre/maplibre-gl-native'); \
             require('/usr/src/app/node_modules/canvas'); \
             require('/usr/src/app/node_modules/sharp'); \
             require('/usr/src/app/node_modules/sqlite3'); \
             console.log('native modules load OK')"

RUN mkdir -p /data && chown node:node /data
VOLUME /data
WORKDIR /data

EXPOSE 8080

USER node:node

ENTRYPOINT ["/usr/src/app/docker-entrypoint.sh"]

HEALTHCHECK CMD node /usr/src/app/src/healthcheck.js
