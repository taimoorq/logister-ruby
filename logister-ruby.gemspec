require_relative 'lib/logister/version'

Gem::Specification.new do |spec|
  spec.name = 'logister-ruby'
  spec.version = Logister::VERSION
  spec.authors = ['Logister']
  spec.email = ['support@logister.org']

  spec.summary = 'Ruby and Rails client for sending events to Logister'
  spec.description = 'Ruby and Rails client for reporting errors, logs, metrics, transactions, and check-ins to the Logister backend, including self-hosted installs.'
  spec.homepage = 'https://github.com/taimoorq/logister-ruby'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/taimoorq/logister-ruby'
  spec.metadata['documentation_uri'] = 'https://docs.logister.org/integrations/ruby/'
  spec.metadata['changelog_uri'] = 'https://github.com/taimoorq/logister-ruby/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/taimoorq/logister-ruby/issues'

  spec.files = Dir.chdir(__dir__) do
    Dir.glob('lib/**/*') + ['README.md', 'CHANGELOG.md', 'LICENSE', 'logister-ruby.gemspec']
  end

  spec.require_paths = ['lib']

  spec.add_dependency 'activesupport', '>= 6.1'
  spec.add_development_dependency 'actionpack', '>= 6.1'
  spec.add_development_dependency 'rake', '>= 13.0'
end
