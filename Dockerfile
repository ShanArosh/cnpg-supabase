ARG PG_MAJOR=15
ARG SUPABASE_PG_VERSION=15.1.1.38
ARG TIMESCALEDB_RELEASE=2.13.0


####################
# Setup Postgres PPA
####################
FROM ubuntu:focal as ppa
# Redeclare args for use in subsequent stages
ARG postgresql_major
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg \
    ca-certificates \
    lsb-core \
    wget \
    && rm -rf /var/lib/apt/lists/*
RUN sh -c 'echo "deb https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' && \
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - 


####################
# Download postgres dev
####################
FROM ppa as pg-dev
ARG PG_MAJOR
# Download .deb packages
RUN apt-get update && apt-get install -y --no-install-recommends --download-only \
    postgresql-server-dev-${PG_MAJOR} \
    && rm -rf /var/lib/apt/lists/*
RUN mv /var/cache/apt/archives/*.deb /tmp/

FROM ubuntu:focal as builder
# Install build dependencies
COPY --from=pg-dev /tmp /tmp
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    /tmp/*.deb \
    build-essential \
    checkinstall \
    cmake \
    && rm -rf /var/lib/apt/lists/* /tmp/*

FROM builder as ccache
# Cache large build artifacts
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang \
    ccache \
    libkrb5-dev \
    && rm -rf /var/lib/apt/lists/*
ENV CCACHE_DIR=/ccache
ENV PATH=/usr/lib/ccache:$PATH
# Used to update ccache
ARG CACHE_EPOCH

####################
# 10-timescaledb.yml
####################
FROM ccache as timescaledb-source
# Download and extract
ARG TIMESCALEDB_RELEASE
ADD "https://github.com/timescale/timescaledb/archive/refs/tags/${TIMESCALEDB_RELEASE}.tar.gz" \
    /tmp/timescaledb.tar.gz
RUN tar -xvf /tmp/timescaledb.tar.gz -C /tmp && \
    rm -rf /tmp/timescaledb.tar.gz
# Build from source
WORKDIR /tmp/timescaledb-${TIMESCALEDB_RELEASE}/build
RUN cmake ..
RUN --mount=type=cache,target=/ccache,from=public.ecr.aws/supabase/postgres:ccache \
    make -j$(nproc)
# Create debian package
RUN checkinstall -D --install=no --fstrans=no --backup=no --pakdir=/tmp --pkgname=timescaledb --pkgversion=${TIMESCALEDB_RELEASE} --nodoc


####################
# Download CNPG Extensions
####################
FROM ppa as cnpg-ext
ARG PG_MAJOR
# Download .deb packages
RUN apt-get update && apt-get install -y --no-install-recommends --download-only \
    # "postgresql-${PG_MAJOR}-pgaudit" \
    # "postgresql-${PG_MAJOR}-pgvector" \
    "postgresql-${PG_MAJOR}-pg-failover-slots" \
    python3-pip \
    python3-psycopg2 \
    python3-setuptools \
    && rm -rf /var/lib/apt/lists/*
RUN mv /var/cache/apt/archives/*.deb /tmp/

FROM supabase/postgres:${SUPABASE_PG_VERSION} as production

COPY --from=cnpg-ext /tmp/*.deb /tmp/
COPY --from=timescaledb-source /tmp/*.deb /tmp/

ENV DEBIAN_FRONTEND=noninteractive
# RUN apt-get purge timescaledb -y --no-install-recommends \
#     && rm -rf /usr/lib/postgresql/15/lib/timescaledb* \
#     /usr/share/postgresql/15/extension/timescaledb*
RUN apt-get update && apt-get install -y --no-install-recommends \
    /tmp/*.deb \
    # Needed for anything using libcurl
    # https://github.com/supabase/postgres/issues/573
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* /tmp/*


# COPY requirements.txt /
ADD https://raw.githubusercontent.com/cloudnative-pg/postgres-containers/main/Debian/15/requirements.txt /

RUN set -xe; \
    pip3 install --upgrade pip; \
    # TODO: Remove --no-deps once https://github.com/pypa/pip/issues/9644 is solved
    pip3 install --no-deps -r requirements.txt; \
    rm -rf /var/lib/apt/lists/*;


COPY scripts/realtime.sql /docker-entrypoint-initdb.d/migrations/99-realtime.sql
COPY scripts/logs.sql /docker-entrypoint-initdb.d/migrations/99-logs.sql
COPY scripts/webhooks.sql /docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql
COPY scripts/roles.sql /docker-entrypoint-initdb.d/init-scripts/99-roles.sql
COPY scripts/jwt.sql /docker-entrypoint-initdb.d/init-scripts/99-jwt.sql

# CNPG uses postInitApplicationSQLRefsFolder: "/etc/post-init-application-sql"  for migrations
# RUN mv /docker-entrypoint-initdb.d/ /etc/post-init-application-sql/

# Change the uid of postgres to 26
RUN usermod -u 26 postgres
USER 26
