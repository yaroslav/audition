# frozen_string_literal: true

# Audition's dynamic probe harness. Executed as a subprocess, never
# required into the host process:
#
#   ruby harness.rb MODE < payload.json
#
# Prints exactly one JSON document on stdout and never raises.
# Stdlib only; must stay runnable on a bare Ruby 4.0.

Warning[:experimental] = false
Thread.report_on_exception = false

require "json"

module AuditionHarness
  MAX_CONSTS = 5000

  # Fixtures for capability probes.
  CAP_CONST = [1, 2] # audition:disable mutable-constants

  class CapClassVar
    @@flag = true # audition:disable class-variables

    def self.read
      @@flag
    end
  end

  class CapIvar
    @mutable = {"k" => 1} # audition:disable class-level-state

    def self.write
      @x = 1 # audition:disable class-level-state
    end

    def self.read_mutable
      @mutable
    end
  end

  module_function

  def main(mode, payload, out:)
    result =
      case mode
      when "script_main" then script_main(payload.fetch("path"))
      when "script_ractor" then script_ractor(payload.fetch("path"))
      when "require" then library(payload)
      when "rack" then rack(payload)
      when "rails" then rails(payload)
      when "capabilities" then capabilities
      else {"error" => {"class" => "ArgumentError",
                        "message" => "unknown mode #{mode}"}}
      end
    out.puts(JSON.generate(result))
  rescue Exception => e
    begin
      out.puts(JSON.generate("error" => describe_error(e)))
    rescue Exception
      out.puts('{"error":{"class":"HarnessFailure",' \
               '"message":"unreportable error"}}')
    end
  end

  # Exception messages can carry arbitrary bytes (C extensions,
  # binary filenames); unscrubbed they blow up JSON.generate
  # inside the rescue and the harness dies without output.
  def describe_error(error)
    root = unwrap(error)
    {"class" => scrub(root.class.name.to_s),
     "message" => scrub(root.message.to_s)[0, 500]}
  end

  def scrub(text)
    text.dup.force_encoding(Encoding::UTF_8).scrub
  rescue Exception
    "(unprintable)"
  end

  def unwrap(error)
    if error.is_a?(Ractor::RemoteError) && error.cause
      error.cause
    else
      error
    end
  end

  def in_ractor(*args, &block)
    ractor = Ractor.new(*args, &block)
    {"ok" => true, "value" => jsonable(ractor.value)}
  rescue Exception => e
    {"ok" => false, "error" => describe_error(e)}
  end

  def jsonable(value)
    case value
    when Numeric, String, Symbol, true, false, nil then value
    else value.inspect[0, 200]
    end
  end

  # -- scripts -----------------------------------------------------

  def script_main(path)
    load path # audition:disable runtime-require
    {"ok" => true}
  rescue Exception => e
    {"ok" => false, "error" => describe_error(e)}
  end

  # `load` is not proxied to the main Ractor (unlike `require` on
  # Ruby 4.0), so the script body truly executes inside the Ractor.
  def script_ractor(path)
    in_ractor(path) do |p|
      load p # audition:disable runtime-require
      :ok
    end
  end

  # -- libraries ---------------------------------------------------

  def library(payload)
    Array(payload["load_paths"]).each do |lp|
      $LOAD_PATH.unshift(lp) # audition:disable global-variables
    end
    before = Object.constants
    require payload.fetch("feature") # audition:disable runtime-require
    scan(Object.constants - before, root: payload["root"])
  end

  # Breadth-first walk of every constant the require introduced:
  # plain values get a Ractor.shareable? verdict; classes and modules
  # are inspected for class-level ivars and class variables, then
  # descended into. const_get can raise (autoload failures) and
  # anything can lie; every step is rescued and counted.
  def scan(root_names, root: nil)
    # Loaded features are realpathed by require; the target root
    # must be too, or symlinked paths (macOS /var vs /private/var)
    # break the own-vs-dependency comparison.
    if root
      root = begin
        File.realpath(root)
      rescue
        root
      end
    end
    unshareable = []
    class_state = []
    class_vars = []
    errors = 0
    seen = {}
    queue = root_names.map { |name| [Object, name.to_s] }
    visited = 0

    until queue.empty?
      owner, name = queue.shift
      visited += 1
      break if visited > MAX_CONSTS

      begin
        value = owner.const_get(name, false)
      rescue Exception
        errors += 1
        next
      end
      full = owner.equal?(Object) ? name : "#{owner}::#{name}"
      origin = origin_for(owner, name, root)

      if value.is_a?(Module)
        next if seen[value.object_id]

        seen[value.object_id] = true
        errors += inspect_module(full, value, origin,
          class_state, class_vars)
        value.constants(false).each do |child|
          queue << [value, child.to_s]
        end
      else
        begin
          unless Ractor.shareable?(value)
            unshareable << origin.merge(
              "const" => full, "class" => value.class.name
            )
          end
        rescue Exception
          errors += 1
        end
      end
    end

    {"unshareable_constants" => unshareable,
     "class_state" => class_state,
     "class_variables" => class_vars,
     "scanned" => visited,
     "errors" => errors}
  end

  # Where was this constant defined, and does that location belong
  # to the audited target (as opposed to a dependency it loaded)?
  # Unknown locations (C extensions, core) count as own so nothing
  # gets silently downgraded.
  def origin_for(owner, name, root)
    path, line = begin
      owner.const_source_location(name)
    rescue Exception
      nil
    end
    # The separator matters: /x/app must not claim /x/app-helpers.
    own = root.nil? || path.nil? || path == root ||
      path.start_with?(root + File::SEPARATOR)
    {"path" => path, "line" => line, "own" => own}
  end

  def inspect_module(full, mod, origin, class_state, class_vars)
    ivars = mod.instance_variables
    if ivars.any?
      shareability = ivars.map do |ivar|
        value = mod.instance_variable_get(ivar)
        [ivar.to_s, safe_shareable?(value)]
      end
      class_state << origin.merge(
        "const" => full,
        "ivars" => shareability.map(&:first),
        "unshareable" => shareability.reject(&:last).map(&:first)
      )
    end
    cvars = mod.class_variables(false)
    if cvars.any?
      class_vars << origin.merge(
        "const" => full, "cvars" => cvars.map(&:to_s)
      )
    end
    0
  rescue Exception
    1
  end

  def safe_shareable?(value)
    Ractor.shareable?(value)
  rescue Exception
    false
  end

  # -- rack --------------------------------------------------------

  # App objects built in config.ru are almost never shareable (the
  # file is instance_eval'd inside Rack::Builder, so every lambda's
  # self is the Builder). Ractor web servers therefore boot the app
  # once per Ractor; the probe mirrors that model: parse config.ru
  # and serve one request entirely inside a Ractor.
  def rack(payload)
    config_ru = payload.fetch("config_ru")
    begin
      require "rack" # audition:disable runtime-require
    rescue LoadError
      return {"rack_available" => false}
    end

    out = {"rack_available" => true}
    begin
      app = Rack::Builder.parse_file(config_ru)
      app = app.first if app.is_a?(Array)
      out["app_class"] = app.class.name
      out["shareable"] = Ractor.shareable?(app)
    rescue Exception => e
      out["main_boot_error"] = describe_error(e)
    end

    out["ractor_boot_call"] = rack_in_ractor(config_ru)
    if out["ractor_boot_call"]["ok"]
      out["concurrency"] = rack_concurrent(
        config_ru,
        payload.fetch("ractors", 4),
        payload.fetch("requests", 25)
      )
    end
    out
  end

  # Real failures (races on shared state, require-proxy
  # serialization) only show up under load: boot the app in N
  # Ractors and serve M requests from each.
  def rack_concurrent(config_ru, workers, requests)
    ractors = workers.times.map do
      Ractor.new(config_ru, requests) do |path, n|
        require "rack" # audition:disable runtime-require
        require "stringio" # audition:disable runtime-require
        builder = Rack::Builder.new
        builder.instance_eval(File.read(path), path, 1)
        app = builder.to_app
        statuses = Hash.new(0)
        n.times do
          statuses[app.call(AuditionHarness.base_env).first] += 1
        end
        statuses
      end
    end
    results = ractors.map do |ractor|
      {"ok" => true, "statuses" => ractor.value}
    rescue Exception => e
      {"ok" => false, "error" => describe_error(e)}
    end

    merged = Hash.new(0)
    results.each do |result|
      next unless result["ok"]

      result["statuses"].each { |code, n| merged[code.to_s] += n }
    end
    {"workers" => workers,
     "requests_per_worker" => requests,
     "failures" => results.count { |r| !r["ok"] },
     "first_error" => results.find { |r| !r["ok"] }&.dig("error"),
     "statuses" => merged}
  end

  def base_env
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "80",
      "SERVER_PROTOCOL" => "HTTP/1.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(+""),
      "rack.errors" => StringIO.new(+"")
    }
  end

  # Rack::Builder.parse_file cannot run inside a Ractor at all on
  # rack 3.2 (Rack::BUILDER_TOPLEVEL_BINDING holds an unshareable
  # Binding), so the per-Ractor boot rebuilds the app by
  # instance_eval'ing config.ru into a fresh Builder; same DSL,
  # no poisoned constant.
  def rack_in_ractor(config_ru)
    in_ractor(config_ru) do |path|
      require "rack" # audition:disable runtime-require
      require "stringio" # audition:disable runtime-require
      builder = Rack::Builder.new
      builder.instance_eval(File.read(path), path, 1)
      app = builder.to_app
      app.call(AuditionHarness.base_env).first
    end
  end

  # -- rails -------------------------------------------------------

  def rails(payload)
    environment = payload.fetch("environment")
    before = Object.constants
    started = Time.now
    require environment # audition:disable runtime-require
    begin
      Rails.application.eager_load!
    rescue Exception
      nil
    end
    boot = {"ok" => true,
            "seconds" => (Time.now - started).round(1)}
    scan(Object.constants - before, root: payload["root"])
      .merge("boot" => boot)
  rescue Exception => e
    {"boot" => {"ok" => false, "error" => describe_error(e)}}
  end

  # -- capabilities ------------------------------------------------

  def capabilities
    caps = {}
    capability_probes.each do |label, probe|
      probe.call
      caps[label] = {"ok" => true, "error" => nil}
    rescue Exception => e
      caps[label] = {"ok" => false,
                      "error" => unwrap(e).class.name}
    end
    {"capabilities" => caps}
  end

  def capability_probes
    {
      "global variable read" =>
        -> { Ractor.new { $audition_cap }.value }, # audition:disable
      "global variable write" =>
        -> { Ractor.new { $audition_cap = 1 }.value }, # audition:disable
      "class variable access" =>
        -> { Ractor.new { CapClassVar.read }.value },
      "class ivar write" =>
        -> { Ractor.new { CapIvar.write }.value },
      "class ivar read (mutable value)" =>
        -> { Ractor.new { CapIvar.read_mutable }.value },
      "unshareable constant read" =>
        -> { Ractor.new { CAP_CONST }.value },
      "constant set (unshareable value)" =>
        -> { Ractor.new { Object.const_set(:AUDITION_X, +"s") }.value },
      "ENV read" =>
        -> { Ractor.new { ENV.fetch("HOME", "none") }.value },
      "ENV write" =>
        -> { Ractor.new { ENV["AUD_CAP"] = "1" }.value }, # audition:disable
      "require inside Ractor" =>
        -> { Ractor.new { require "date" }.value }, # audition:disable
      "ObjectSpace.each_object" =>
        -> { Ractor.new { ObjectSpace.each_object(Class).first }.value },
      "Signal.trap" =>
        -> { Ractor.new { Signal.trap("USR2") {} }.value }, # audition:disable
      "Thread.current storage" =>
        -> { Ractor.new { Thread.current[:x] = 1 }.value },
      "Timeout.timeout" =>
        lambda do
          require "timeout" # audition:disable runtime-require
          Ractor.new { Timeout.timeout(2) { :ok } }.value
        end,
      "proc copied into Ractor" =>
        lambda do
          pr = proc { 1 }
          Ractor.new(pr) { |_p| :ok }.value
        end,
      "outer local capture" =>
        lambda do
          z = [1]
          Ractor.new { z }.value # audition:disable ractor-isolation
        end
    }
  end
end

if $PROGRAM_NAME == __FILE__ # audition:disable global-variables
  # The audited code may print anything, from any Ractor, straight
  # to fd 1. Keep a private dup of the real stdout for the JSON
  # document and point fd 1 at stderr for everyone else.
  real_stdout = $stdout.dup
  $stdout.reopen($stderr)
  mode = ARGV.fetch(0, "capabilities")
  raw = $stdin.tty? ? "" : $stdin.read
  payload = raw.empty? ? {} : JSON.parse(raw)
  AuditionHarness.main(mode, payload, out: real_stdout)
end
