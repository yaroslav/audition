# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"
require "yard"

RSpec::Core::RakeTask.new(:spec)
YARD::Rake::YardocTask.new(:yard)

task default: %i[spec standard]
