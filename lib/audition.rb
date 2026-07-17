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

module Audition
  class Error < StandardError; end
end
