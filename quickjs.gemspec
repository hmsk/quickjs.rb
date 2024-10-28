# frozen_string_literal: true

require_relative 'lib/quickjs/version'

Gem::Specification.new do |spec|
  spec.name = 'quickjs'
  spec.version = Quickjs::VERSION
  spec.authors = ['hmsk']
  spec.email = ['k.hamasaki@gmail.com']

  spec.summary = 'Run binding of QuickJS'
  spec.description = 'A native wrapper to run QuickJS in Ruby'
  spec.homepage = 'https://github.com/hmsk/quickjs.rb'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/hmsk/quickjs.rb/blob/main/CHANGELOG.md'

  spec.add_runtime_dependency 'json'
  spec.add_runtime_dependency 'securerandom'
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end + Dir['ext/quickjsrb/quickjs/*'].select { |f| f.end_with?(*%w[.c .h LICENSE]) }
  spec.require_paths = ['lib']
  spec.extensions = ['ext/quickjsrb/extconf.rb']
end
