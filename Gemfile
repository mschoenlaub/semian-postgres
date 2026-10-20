# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in semian-pg.gemspec
gemspec

gem 'rake', '~> 12.0'

group :test do
  # Bundled gems from Ruby 4.0 on, used by semian and the spec helpers.
  gem 'benchmark'
  gem 'logger'
  gem 'rspec', '~> 3.0'
  gem 'toxiproxy', '~> 2.0'
end

group :lint do
  gem 'rubocop', require: false
  gem 'rubocop-rake', require: false
  gem 'rubocop-rspec', require: false
end
