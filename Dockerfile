FROM ruby:3.3.12-slim

RUN apt-get update -qq \
  && apt-get install --no-install-recommends -y build-essential libpq-dev postgresql-client \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /rails

COPY Gemfile Gemfile.lock ./
RUN bundle config set frozen true && bundle install

COPY . .
RUN chmod +x bin/*

ENTRYPOINT ["bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0"]

