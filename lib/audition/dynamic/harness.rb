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
require "rbconfig"

module AuditionHarness
  # High enough for the largest targets: the sweep is the backstop
  # for everything static analysis cannot prove, so it must reach
  # every constant the boot defined. A hit is reported as
  # truncated, never silent.
  MAX_CONSTS = 200_000

  # Directories under the target root that are not the target's
  # own surface. Bundler's deployment mode (and bundler-cache in
  # GitHub Actions) vendors every gem into <root>/vendor/bundle,
  # and attributing those constants to the target would flip its
  # verdict from blocked to not_ready. Must mirror
  # Audition::Target::EXCLUDED_DIRS (this file is a standalone
  # subprocess script and cannot require the gem); a spec keeps
  # the two lists in sync.
  EXCLUDED_DIRS = %w[
    vendor node_modules tmp log coverage pkg .git .bundle
  ].freeze

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
     "message" => scrub(root.message.to_s)[0, 500],
     "backtrace" => backtrace_for(root)}
  end

  # Enough frames to reach the target's code under framework
  # wrappers; frames carry paths, which can carry arbitrary bytes.
  def backtrace_for(error)
    Array(error.backtrace).first(30).map do |frame|
      scrub(frame.to_s)[0, 300]
    end
  rescue Exception
    []
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
    baseline = module_state_snapshot
    before = Object.constants
    features = $LOADED_FEATURES.dup # audition:disable global-variables
    require_target(payload.fetch("feature"),
      Array(payload["load_paths"]))
    merge_reopened(
      scan(Object.constants - before, root: payload["root"],
        limit: payload["max_constants"]), baseline
    ).merge(
      "native_extensions" => native_extensions(
        features, payload["root"], payload["known_compiled"]
      )
    )
  end

  # Gem names and entry files diverge in two conventional ways:
  # dashed names ship slashed files (rspec-mocks provides
  # rspec/mocks), and squashed names ship snake_case files
  # (activesupport provides active_support). The second has no
  # rule to invert, so when the target ships exactly one top-level
  # file on its load paths, that file is the entry, required by
  # absolute path. An absolute require keeps the path as given, and scan
  # compares constant origins against the realpathed root, so the
  # candidate is built from the realpath too (a symlinked tmpdir,
  # macOS /var, otherwise turns own findings into dependency ones).
  # The error reported is the last one seen: a candidate that loads
  # but fails inside says more than "cannot load such file".
  def require_target(feature, load_paths)
    require feature # audition:disable runtime-require
  rescue LoadError => error
    entry_candidates(feature, load_paths).each do |candidate|
      return require candidate # audition:disable runtime-require
    rescue LoadError => e
      error = e
    end
    raise error
  end

  def entry_candidates(feature, load_paths)
    candidates = []
    slashed = feature.tr("-", "/")
    candidates << slashed if slashed != feature
    files = load_paths.flat_map do |path|
      Dir[File.join(realpath(path), "*.rb")]
    end
    candidates << files.first.delete_suffix(".rb") if files.size == 1
    candidates
  end

  # Breadth-first walk of every constant the require introduced:
  # plain values get a Ractor.shareable? verdict; classes and modules
  # are inspected for class-level ivars and class variables, then
  # descended into. const_get can raise (autoload failures) and
  # anything can lie; every step is rescued and counted.
  def scan(root_names, root: nil, limit: nil)
    # Loaded features are realpathed by require; the target root
    # must be too, or symlinked paths (macOS /var vs /private/var)
    # break the own-vs-dependency comparison.
    root = realpath(root)
    limit = (limit || MAX_CONSTS).to_i
    unshareable = []
    class_state = []
    class_vars = []
    errors = 0
    truncated = false
    seen = {}
    queue = root_names.map { |name| [Object, name.to_s] }
    visited = 0

    until queue.empty?
      if visited >= limit
        truncated = true
        break
      end
      owner, name = queue.shift
      visited += 1

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
            blocker, blocker_depth = blocker_for(value)
            unshareable << origin.merge(
              "const" => full, "class" => value.class.name,
              "blocker" => blocker,
              "blocker_nested" => blocker_depth.positive?
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
     "truncated" => truncated,
     "limit" => limit,
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
      (path.start_with?(root + File::SEPARATOR) &&
        !excluded?(path, root))
    {"path" => path, "line" => line, "own" => own}
  end

  # Matches the static scanner's exclusion rule: any excluded or
  # dot-prefixed component in the root-relative path means the
  # file is not the target's own code.
  def excluded?(path, root)
    relative = path.delete_prefix(root + File::SEPARATOR)
    relative.split(File::SEPARATOR).any? do |part|
      EXCLUDED_DIRS.include?(part) || part.start_with?(".")
    end
  end

  NATIVE = /\.(bundle|so)\z/
  DECLARATION = "rb_ext_ractor_safe"

  # Compiled extensions the require pulled in, with the one fact
  # that decides their Ractor behavior: whether the file imports
  # rb_ext_ractor_safe. Ruby's own extensions (archdir) are flagged
  # so the prober can leave them to Ruby, and files the static check
  # already covers are flagged as known.
  def native_extensions(before, root, known)
    root = realpath(root)
    known = Array(known).map { |path| realpath(path) }
    archdir = RbConfig::CONFIG["archdir"] + File::SEPARATOR
    loaded = $LOADED_FEATURES - before # audition:disable global-variables
    loaded.grep(NATIVE).map do |path|
      {"path" => path,
       "declares" => declares?(path),
       "ruby" => path.start_with?(archdir),
       "known" => known.include?(path),
       "own" => known.include?(path) || own_path?(path, root)}
    end
  end

  def declares?(path)
    File.binread(path).include?(DECLARATION)
  rescue SystemCallError
    false
  end

  def own_path?(path, root)
    return false unless root

    path == root ||
      (path.start_with?(root + File::SEPARATOR) && !excluded?(path, root))
  end

  def realpath(path)
    return path if path.nil?

    File.realpath(path)
  rescue SystemCallError
    path
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

  # Ivar/cvar state of every module defined before the boot. The
  # new-constants sweep never revisits these, so state the boot
  # plants on reopened core and stdlib classes is diffed against
  # this snapshot instead. Autoload stubs are left untouched:
  # forcing them here would load code behind the back of the
  # before/after constant accounting.
  def module_state_snapshot(limit = 50_000)
    snap = {}
    seen = {}
    queue = Object.constants.map { |name| [Object, name.to_s] }
    until queue.empty? || snap.size >= limit
      owner, name = queue.shift
      begin
        next if owner.autoload?(name, false)

        value = owner.const_get(name, false)
      rescue Exception
        next
      end
      next unless value.is_a?(Module)
      next if seen[value.object_id]

      seen[value.object_id] = true
      begin
        snap[value] = [value.instance_variables,
          value.class_variables(false)]
      rescue Exception
        next
      end
      value.constants(false).each do |child|
        queue << [value, child.to_s]
      end
    end
    snap
  end

  # RubyGems, Bundler, and the VM mutate their own module state on
  # every require; that is probe machinery, not the target's doing.
  MACHINERY = /\A(?:Gem|Bundler|RubyVM)(?:::|\z)/

  # State the boot added to pre-existing modules, reported through
  # the same channels as freshly defined class state. No source
  # location exists for a reopen, and unknown origins count as own.
  def merge_reopened(result, snapshot)
    origin = {"path" => nil, "line" => nil, "own" => true}
    snapshot.each do |mod, (ivars, cvars)|
      new_ivars = mod.instance_variables - ivars
      new_cvars = mod.class_variables(false) - cvars
      next if new_ivars.empty? && new_cvars.empty?

      full = mod.name || mod.inspect
      next if full.match?(MACHINERY)
      if new_ivars.any?
        unshareable = new_ivars.reject do |ivar|
          safe_shareable?(mod.instance_variable_get(ivar))
        end
        result["class_state"] << origin.merge(
          "const" => full,
          "ivars" => new_ivars.map(&:to_s),
          "unshareable" => unshareable.map(&:to_s)
        )
      end
      if new_cvars.any?
        result["class_variables"] << origin.merge(
          "const" => full, "cvars" => new_cvars.map(&:to_s)
        )
      end
    rescue Exception
      next
    end
    result
  end

  # The innermost unshareable node of an unshareable value, with
  # its depth: an unfrozen node with shareable contents just needs
  # freezing, an inherently unshareable one needs replacing.
  # Bounded, because shareability of each child is itself a
  # recursive check.
  def blocker_for(value, depth = 0)
    return [describe_blocker(value), depth] if depth > 5

    child = children_of(value).find { |c| !safe_shareable?(c) }
    if child
      blocker_for(child, depth + 1)
    else
      [describe_blocker(value), depth]
    end
  rescue Exception
    [describe_blocker(value), depth]
  end

  def children_of(value)
    children =
      case value
      when Hash then value.keys + value.values
      when Array then value
      when Struct, Data then value.deconstruct
      else
        value.instance_variables.map do |ivar|
          value.instance_variable_get(ivar)
        end
      end
    children.first(1000)
  end

  # "unfrozen X" only when freezing would actually flip the
  # verdict; a Proc or IO stays unshareable frozen, and naming it
  # unfrozen would send the reader to a fix that cannot work.
  def describe_blocker(value)
    return value.class.to_s if value.frozen?

    frozen_helps = begin
      Ractor.shareable?(value.dup.freeze)
    rescue Exception
      false
    end
    frozen_helps ? "unfrozen #{value.class}" : value.class.to_s
  end

  # -- rack --------------------------------------------------------

  # App objects built in config.ru are almost never shareable (the
  # file is instance_eval'd inside Rack::Builder, so every lambda's
  # self is the Builder). Ractor web servers therefore boot the app
  # once per Ractor; the probe mirrors that model: parse config.ru
  # and serve one request entirely inside a Ractor.
  def rack(payload)
    config_ru = payload.fetch("config_ru")
    root = payload["root"] || File.dirname(config_ru)
    bundler_setup
    begin
      require "rack" # audition:disable runtime-require
    rescue LoadError
      return {"rack_available" => false}
    end

    out = {"rack_available" => true}
    baseline = module_state_snapshot
    before = Object.constants
    features = $LOADED_FEATURES.dup # audition:disable global-variables
    begin
      app = Rack::Builder.parse_file(config_ru)
      app = app.first if app.is_a?(Array)
      out["app_class"] = app.class.name
      out["shareable"] = Ractor.shareable?(app)
    rescue Exception => e
      out["main_boot_error"] = describe_error(e)
    end
    # The main-process boot defines the app's constant graph;
    # sweeping it gives rack targets the same backstop as require
    # and rails targets. A failed boot still sweeps what loaded.
    out.merge!(merge_reopened(
      scan(Object.constants - before, root: root,
        limit: payload["max_constants"]), baseline
    ))
    out["native_extensions"] = native_extensions(
      features, root, payload["known_compiled"]
    )

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

  # The prober sets BUNDLE_GEMFILE to the target's Gemfile; the
  # target's gems must resolve before its boot files load. A
  # setup failure propagates: it is the true boot failure, and
  # the standard reporting captures it. Bundler.setup is called
  # directly because bundler/setup exits on failure, swallowing
  # the message.
  def bundler_setup
    return unless ENV["BUNDLE_GEMFILE"]

    require "bundler" # audition:disable runtime-require
    Bundler.ui.silence { Bundler.setup }
  end

  # A boot failure does not abandon the sweep: everything defined
  # before the failure is still scanned, so the probe reports what
  # it could reach alongside the boot error.
  def rails(payload)
    environment = payload.fetch("environment")
    bundler_setup
    baseline = module_state_snapshot
    before = Object.constants
    features = $LOADED_FEATURES.dup # audition:disable global-variables
    started = Time.now
    boot_error = nil
    begin
      # Absolute requires keep the path as given; realpathing it
      # keeps own-vs-dependency attribution honest under symlinked
      # roots (macOS /var).
      require realpath(environment) # audition:disable runtime-require
      begin
        Rails.application.eager_load!
      rescue Exception
        nil
      end
    rescue Exception => e
      boot_error = describe_error(e)
    end
    boot =
      if boot_error
        {"ok" => false, "error" => boot_error}
      else
        {"ok" => true, "seconds" => (Time.now - started).round(1)}
      end
    merge_reopened(
      scan(Object.constants - before, root: payload["root"],
        limit: payload["max_constants"]), baseline
    ).merge(
      "boot" => boot,
      "native_extensions" => native_extensions(
        features, payload["root"], payload["known_compiled"]
      )
    )
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
