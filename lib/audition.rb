# frozen_string_literal: true

require_relative "audition/version"
require_relative "audition/finding"
require_relative "audition/target"
require_relative "audition/static/source_file"
require_relative "audition/static/literal_classifier"
require_relative "audition/static/checks"
require_relative "audition/static/graph_audit"
require_relative "audition/static/analyzer"
require_relative "audition/dynamic/prober"
require_relative "audition/report"
require_relative "audition/config"
require_relative "audition/baseline"
require_relative "audition/directives"
require_relative "audition/fixer"
require_relative "audition/bundle_sweep"
require_relative "audition/cli"

# Probes Ruby code for the ability to run inside Ractors: static
# analysis (Prism per-file checks plus whole-program rubydex graph
# checks), dynamic in-Ractor probing in subprocesses, explanations
# and fixes for every finding, and a four-state verdict.
#
# The command line lives in {Audition::CLI}; library consumers
# usually start from {Audition::Target.detect} and
# {Audition::Static::Analyzer}.
#
# @example Audit one file programmatically
#   analyzer = Audition::Static::Analyzer.new
#   findings = analyzer.analyze_path("app/models/user.rb")
#   findings.each { |f| puts "#{f.location}: #{f.message}" }
module Audition
  # Raised for user-facing failures: unknown targets, unreadable
  # config, malformed baselines. The CLI converts it to exit code 2.
  class Error < StandardError; end
end
