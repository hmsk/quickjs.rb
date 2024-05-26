# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end

require 'rake/extensiontask'

task build: :compile

GEMSPEC = Gem::Specification.load('quickjs.gemspec')

Rake::ExtensionTask.new('quickjsrb', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/quickjs'
end

task default: %i[clobber compile test]
