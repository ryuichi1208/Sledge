# syntax=docker/dockerfile:1
#
# Sledge container image
#
#   production:  docker build -t sledge .
#   development: docker build --target dev -t sledge-dev .
#
ARG UBUNTU_VERSION=26.04

############################################################
# Build Perl itself (the latest stable release rather than Ubuntu's perl)
############################################################
FROM ubuntu:${UBUNTU_VERSION} AS perl-build

ARG PERL_VERSION=5.44.0
ARG PERL_SHA256=3b855066b92491cb40e86affb1ca57d1a388aa43e51b91c7806a32c2f65f96c3

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/perl
RUN curl -fsSL -o perl.tar.gz "https://www.cpan.org/src/5.0/perl-${PERL_VERSION}.tar.gz" \
 && echo "${PERL_SHA256}  perl.tar.gz" | sha256sum -c - \
 && tar --strip-components=1 -xzf perl.tar.gz \
 && rm perl.tar.gz \
 && ./Configure -des -Dprefix=/opt/perl -Duseshrplib -Dusethreads -Dman1dir=none -Dman3dir=none \
 && make -j"$(nproc)" \
 && make install \
 && cd / && rm -rf /usr/src/perl

ENV PATH=/opt/perl/bin:$PATH
RUN curl -fsSL https://cpanmin.us | perl - --notest App::cpanminus \
 && cpanm --notest --quiet Carton \
 && rm -rf /root/.cpanm

############################################################
# CPAN dependencies
############################################################
FROM perl-build AS deps

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libmysqlclient-dev libpq-dev \
 && rm -rf /var/lib/apt/lists/*

# Install exactly the versions pinned in cpanfile.snapshot (run `carton install`
# to update it). Installed outside /app so the dev bind mount does not hide them.
ENV PERL_CARTON_PATH=/opt/carton
WORKDIR /app
COPY cpanfile cpanfile.snapshot ./
RUN carton install --deployment \
 && rm -rf /root/.cpanm /opt/carton/cache
ENV PATH=/opt/carton/bin:$PATH \
    PERL5LIB=/opt/carton/lib/perl5

############################################################
# Development image: includes test tools and database clients
############################################################
FROM deps AS dev

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git less vim-tiny sqlite3 default-mysql-client postgresql-client \
 && rm -rf /var/lib/apt/lists/*

# Development-only tools (not part of the pinned runtime dependencies)
RUN cpanm --notest --quiet Perl::Tidy Devel::Cover \
 && rm -rf /root/.cpanm

ENV PERL5LIB=/app/lib:/opt/carton/lib/perl5
CMD ["bash"]

############################################################
# Production image
############################################################
FROM ubuntu:${UBUNTU_VERSION} AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates libmysqlclient24 libpq5 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 sledge \
 && useradd --system --uid 10001 --gid sledge --home-dir /app --shell /usr/sbin/nologin sledge

COPY --from=deps /opt/perl /opt/perl
COPY --from=deps /opt/carton /opt/carton
ENV PATH=/opt/carton/bin:/opt/perl/bin:$PATH \
    PERL5LIB=/app/lib:/opt/carton/lib/perl5

WORKDIR /app
# The source stays owned by root (read-only for the runtime user)
COPY lib ./lib
COPY eg/psgi ./eg/psgi
COPY eg/websocket ./eg/websocket

USER 10001:10001
# 5000: Sledge (Starlet), 5001: WebSocket server (eg/websocket/app.pl)
EXPOSE 5000 5001

# Point SLEDGE_PSGI at your own application to run it
ENV SLEDGE_PSGI=/app/eg/psgi/app.psgi \
    SLEDGE_WORKERS=4 \
    SLEDGE_MAX_REQS_PER_CHILD=1000

# Identifies the release; scripts/release passes the git revision.
# Declared last so that a new revision does not invalidate the layers above.
ARG GIT_REVISION=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.source="https://github.com/ryuichi1208/Sledge" \
      org.opencontainers.image.revision="${GIT_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}"
ENV SLEDGE_RELEASE=${GIT_REVISION}

# --env deployment disables Plack's development middleware.
# On SIGTERM, Starlet finishes in-flight requests before exiting.
CMD ["sh", "-c", "exec plackup -s Starlet --host 0.0.0.0 --port 5000 --max-workers \"$SLEDGE_WORKERS\" --max-reqs-per-child \"$SLEDGE_MAX_REQS_PER_CHILD\" --env deployment \"$SLEDGE_PSGI\""]
