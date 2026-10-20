ARG RUBY_VERSION=3.4
FROM ruby:${RUBY_VERSION} AS base

# Avoid warnings by switching to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential \
      libssl-dev \
      postgresql-client \
      libpq-dev \
 && rm -rf /var/lib/apt/lists/* \
 && gem install bundler

WORKDIR /app
COPY . .
RUN bundle install
CMD ["/bin/bash"]
