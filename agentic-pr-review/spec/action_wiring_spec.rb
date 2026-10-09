# frozen_string_literal: true

require_relative "spec_helper"

require "pathname"
require "yaml"

# action.yml and the shared scripts it runs spell the same names in two places, so a rename
# in shared/ fails at runtime on a real pull request rather than here.
module ReviewActionWiring
module_function

  ACTION_ROOT = File.expand_path("..", __dir__)
  SHARED_ROOT = File.expand_path("../../shared", __dir__)

  # Supplied by the runner or the shell, so no step declares them.
  AMBIENT = %w[
    BASH_SOURCE CI GITHUB_OUTPUT GITHUB_REPOSITORY GITHUB_WORKSPACE HOME PATH TMPDIR
  ].freeze

  def steps
    YAML.safe_load_file(File.join(ACTION_ROOT, "action.yml")).fetch("runs").fetch("steps")
  end

  def step_named(name)
    steps.find { |step| step.fetch("name") == name } || raise("no step named #{name}")
  end

  def shared_paths_run
    steps.flat_map { |step| step.fetch("run", "").scan(%r{/\.\./(shared/\S+?\.(?:rb|sh))}).flatten }.uniq
  end

  def read(path)
    File.read(path, encoding: Encoding::UTF_8)
  end

  # Follows require_relative, so a step is checked against everything its entry point loads.
  def ruby_sources(entry, seen = [])
    return seen if seen.include?(entry)

    seen << entry
    read(entry).scan(/require_relative "([^"]+)"/).flatten.each do |target|
      resolved = File.expand_path(target, File.dirname(entry))
      resolved = "#{resolved}.rb" unless resolved.end_with?(".rb")
      ruby_sources(resolved, seen) if File.exist?(resolved)
    end
    seen
  end

  # ENV.fetch("X") raises when a step forgot it; ENV["X"] tolerates it.
  def ruby_required_env_reads(entry)
    ruby_sources(entry).flat_map { |source| read(source).scan(/ENV\.fetch\("([A-Z_]+)"\)/).flatten }.uniq
  end

  # Only the reads a script cannot run without. A variable it also reads as ${X:-...} is an
  # optional setting, guarded wherever it is used bare.
  def required_shell_env_reads(body)
    assigned = body.scan(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=/).flatten
    optional = body.scan(/\$\{([A-Z_][A-Z0-9_]*):-/).flatten
    body.scan(/\$\{([A-Z_][A-Z0-9_]*)(?:\}|:\?)/).flatten.uniq - assigned - optional
  end

  def provided(step)
    step.fetch("env", {}).keys + AMBIENT
  end
end

RSpec.describe "agentic-pr-review action.yml wiring" do
  it "runs only shared scripts that exist" do
    paths = ReviewActionWiring.shared_paths_run
    # Guards the check from passing against an empty set.
    expect(paths).to include("shared/bin/run_provider.sh", "shared/bin/comment.rb")

    missing = paths.reject { |path| File.exist?(File.join(ReviewActionWiring::SHARED_ROOT, "..", path)) }
    expect(missing).to be_empty
  end

  it "gives every Ruby entry point the variables it requires, in every step that runs it" do
    missing = ReviewActionWiring.steps.each_with_object({}) do |step, index|
      entry = step.fetch("run", "")[%r{/\.\./(shared/bin/\w+\.rb)}, 1]
      next unless entry

      required = ReviewActionWiring.ruby_required_env_reads(File.join(ReviewActionWiring::SHARED_ROOT, "..", entry))
      absent = required - ReviewActionWiring.provided(step)
      index[step.fetch("name")] = absent if absent.any?
    end

    expect(missing).to be_empty
  end

  it "gives every provider script the variables it requires" do
    step = ReviewActionWiring.step_named("Run review provider")
    scripts = [File.join(ReviewActionWiring::SHARED_ROOT, "bin", "run_provider.sh")] +
              Dir[File.join(ReviewActionWiring::SHARED_ROOT, "providers", "**", "*.sh")].sort
    expect(scripts.length).to be > 2

    missing = scripts.each_with_object({}) do |script, index|
      absent = ReviewActionWiring.required_shell_env_reads(ReviewActionWiring.read(script)) -
               ReviewActionWiring.provided(step)
      index[File.basename(script)] = absent if absent.any?
    end

    expect(missing).to be_empty
  end

  it "hands the provider the prompt the compose step writes" do
    composed = ReviewActionWiring.step_named("Compose review prompt").dig("env", "AGENT_PROMPT_PATH")
    read = ReviewActionWiring.step_named("Run review provider").dig("env", "AGENT_PROMPT_PATH")

    expect(read).to eq(composed)
    # Outside the workspace, which is the pull request's head.
    expect(read).to include("runner.temp")
  end

  it "posts the review from the file the provider writes" do
    written = ReviewActionWiring.step_named("Run review provider").dig("env", "AGENT_OUTPUT_PATH")
    posted = ReviewActionWiring.step_named("Post review to GitHub").dig("env", "REVIEW_JSON_PATH")

    expect(posted).to eq(written)
  end

  # Under `set -u` an undeclared variable aborts the step rather than expanding empty.
  it "declares every variable its inline shell steps reference" do
    undeclared = ReviewActionWiring.steps.filter_map do |step|
      next unless step["shell"] == "bash" && step.key?("run")

      missing = ReviewActionWiring.required_shell_env_reads(step.fetch("run")) - ReviewActionWiring.provided(step)
      [step.fetch("name"), missing] if missing.any?
    end

    expect(undeclared).to be_empty
  end

  # The provider reads the workspace, so both have to be done before it starts.
  it "drops the credential and resets agent instructions before the provider runs" do
    names = ReviewActionWiring.steps.map { |step| step.fetch("name") }
    provider = names.index("Run review provider")

    expect(names.index("Remove Git credentials from the workspace")).to be_between(
      names.index("Fetch through merge-base"), provider
    )
    expect(names.index("Reset agent instructions to the merge base")).to be_between(
      names.index("Fetch through merge-base"), provider
    )
  end
end
