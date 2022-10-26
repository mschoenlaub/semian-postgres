# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in semian-pg.gemspec
gemspec

gem 'rake', '~> 12.0'

group :test do
  gem 'rspec', '~> 3.0'
  gem 'ruby-debug-ide', '~> 0.7.3'
  gem 'timecop', '~> 0.9.1'
  gem 'toxiproxy', '~> 2.0 '
end

group :lint do
  gem 'rubocop', require: false
  gem 'rubocop-rake', require: false
  gem 'rubocop-rspec', require: false
end
