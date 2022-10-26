ARG RUBY_VERSION=3.1.2
FROM ruby:${RUBY_VERSION} as base

# Avoid warnings by switching to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential \
      libssl-dev \
      postgresql-client \
      libpq-dev \
      netcat \
 && rm -rf /var/lib/apt/lists/* \
 && gem install bundler

WORKDIR /app
COPY . .
RUN chmod +x scripts/*.sh
RUN bundle install
CMD ["/bin/bash"]
