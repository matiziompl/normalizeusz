FROM alpine:3.21

LABEL maintainer="mateusz"
LABEL description="music-gain: automatic non-invasive ReplayGain 2.0 / EBU R128 loudness normalizer"

# Install rsgain (Alpine community repo), inotify-tools, and supporting utilities
RUN apk add --no-cache \
    rsgain \
    inotify-tools \
    bash \
    su-exec \
    coreutils \
    tzdata

# Copy entrypoint and watcher scripts
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY watcher.sh /usr/local/bin/watcher.sh

# Ensure executable permissions
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/watcher.sh

# Target music volume
VOLUME ["/music"]

WORKDIR /music

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
