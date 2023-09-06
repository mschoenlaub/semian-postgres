# frozen_string_literal: true

require_relative 'lib/semian/pg/version'

Gem::Specification.new do |spec|
  spec.name = 'semian-postgres'
  spec.version = Semian::PG::VERSION
  spec.homepage = 'https://github.com/mschoenlaub/semian-postgres'
  spec.authors = ['Manuel Schönlaub']
  spec.email = ['manuel.schonlaub@prodigygame.com']

  spec.summary = 'Semian adapter for Postgres'
  spec.license = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>=2.7.0')

  spec.add_runtime_dependency 'pg', '~> 1.5.0'
  spec.add_runtime_dependency 'semian', ['>=0.16.0', '<0.18.0']

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/main/CHANGELOG.md"

  spec.files = Dir.glob('{lib}/**/*', File::FNM_DOTMATCH)
  spec.files += ['LICENSE.txt', 'README.md']
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'
end
