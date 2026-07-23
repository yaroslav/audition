# frozen_string_literal: true

require_relative "lib/audition/version"

Gem::Specification.new do |spec|
  spec.name = "audition"
  spec.version = Audition::VERSION
  spec.authors = ["Yaroslav Markin"]
  spec.email = ["yaroslav@markin.net"]

  spec.summary = "Probe Ruby code for Ractor-readiness"
  spec.description =
    "Auditions scripts, gems, Rack apps, and Rails applications " \
    "for the ability to run under Ractors: static analysis of " \
    "Ractor-isolation violations plus dynamic in-Ractor probing, " \
    "with explanations and fixes."
  spec.homepage = "https://github.com/yaroslav/audition"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["audition"]
  spec.require_paths = ["lib"]

  spec.add_dependency "pastel", ">= 0.8"
  spec.add_dependency "prism", ">= 1.0"
  spec.add_dependency "rubydex", ">= 0.2"
  spec.add_dependency "table_tennis", ">= 1.0"
  spec.add_dependency "tty-link", ">= 0.2"
end
