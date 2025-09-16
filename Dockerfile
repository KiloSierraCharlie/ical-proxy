FROM ruby:3.4-alpine AS base
RUN apk add --no-cache tzdata sqlite-libs postgresql-libs mariadb-connector-c

FROM base AS dependencies
RUN apk add --no-cache build-base sqlite-dev postgresql-dev mariadb-dev
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs=3 --retry=3

FROM base
RUN adduser -D app
USER app
WORKDIR /app
COPY --from=dependencies /usr/local/bundle/ /usr/local/bundle/
COPY --chown=app . ./

EXPOSE 9292
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
