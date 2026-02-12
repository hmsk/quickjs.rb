# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end

require 'rake/extensiontask'

task build: [:compile, 'polyfills:version:warn']

GEMSPEC = Gem::Specification.load('quickjs.gemspec')

Rake::ExtensionTask.new('quickjsrb', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/quickjs'
end

def check_polyfill_version!
  require 'json'
  require_relative 'lib/quickjs/version'

  package = JSON.parse(File.read(File.expand_path('polyfills/package.json', __dir__)))
  return if package['version'] == Quickjs::VERSION

  yield package['version'], Quickjs::VERSION
end

namespace :polyfills do
  desc 'Build polyfill bundles with rolldown and recompile'
  task build: :clobber do
    require 'json'
    require_relative 'lib/quickjs/version'

    polyfills_dir = File.expand_path('polyfills', __dir__)
    package_json_path = File.join(polyfills_dir, 'package.json')
    package = JSON.parse(File.read(package_json_path))
    old_version = package['version']
    package['version'] = Quickjs::VERSION
    File.write(package_json_path, "#{JSON.pretty_generate(package)}\n")
    if old_version != Quickjs::VERSION
      warn "\n⚠️  polyfills/package.json version was #{old_version}, updated to #{Quickjs::VERSION}\n\n"
    end

    Dir.chdir(polyfills_dir) do
      sh 'npm install' unless File.exist?('node_modules/.package-lock.json') &&
        File.mtime('node_modules/.package-lock.json') >= File.mtime('package.json')
      sh 'npx rolldown -c rolldown.config.mjs'
    end

    Rake::Task[:compile].invoke
  end

  namespace :version do
    task :check do
      check_polyfill_version! do |pkg_v, gem_v|
        abort "polyfills/package.json version (#{pkg_v}) does not match gem version (#{gem_v}). Run `rake polyfills:build` first."
      end
    end

    task :warn do
      check_polyfill_version! do |pkg_v, gem_v|
        warn "⚠️  polyfills/package.json version (#{pkg_v}) does not match gem version (#{gem_v}). Run `rake polyfills:build` to sync."
      end
    end
  end
end

task 'release:guard_clean' => 'polyfills:version:check'

task default: %i[clobber compile test]
