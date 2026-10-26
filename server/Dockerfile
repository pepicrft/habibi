ARG NODE_VERSION=24.18.0
ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3

FROM node:${NODE_VERSION}-bookworm-slim AS marketing
WORKDIR /app
COPY package.json package-lock.json ./
COPY server/marketing/package.json server/marketing/package.json
RUN npm ci
COPY server/marketing server/marketing
COPY server/priv/gettext server/priv/gettext
COPY server/priv/theme.json server/priv/theme-variants.json server/priv/
RUN npm run build

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-bookworm-20260623-slim AS builder
ENV MIX_ENV=prod
ENV ELIXIR_ERL_OPTIONS="+S 2"
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY server/mix.exs server/mix.lock ./
COPY server/config/config.exs config/config.exs
RUN mix deps.get --only prod && mix deps.compile
COPY server/lib lib
COPY server/priv/repo priv/repo
COPY server/priv/templates priv/templates
COPY server/priv/auth_gettext priv/auth_gettext
COPY server/priv/static/auth priv/static/auth
COPY server/rel rel
COPY --from=marketing /app/server/priv/static/marketing priv/static/marketing
ARG HABIBI_VERSION=0.1.0-dev
ENV HABIBI_VERSION=${HABIBI_VERSION}
RUN mix compile --warnings-as-errors
COPY server/config/runtime.exs config/runtime.exs
RUN mix release

FROM debian:bookworm-slim AS runner
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libstdc++6 libncurses6 libssl3 locales tini \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true
ENV PORT=4000
WORKDIR /app
ARG HABIBI_VERSION=0.1.0-dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.source="https://github.com/pepicrft/habibi" \
      org.opencontainers.image.version="${HABIBI_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/habibi ./
COPY LICENSE ./LICENSE
RUN chown nobody:root /app
USER nobody
EXPOSE 4000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/habibi", "start"]
