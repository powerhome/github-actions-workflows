require_relative "spec_helper"
require "test_plan/profile"

require "yaml"

# action.yml and the scripts it invokes form a contract nothing else checks: the scripts
# read environment variables the steps have to set, the steps read outputs the scripts
# have to write, and several steps hand each other files by path. All of it is spelled
# out in two places at once, so a rename in one of them fails at runtime on a real pull
# request rather than here.
module ActionWiring
  module_function

  # Supplied by the runner or the shell, so no step declares them.
  AMBIENT = %w[
    BASH_SOURCE CI GITHUB_ENV GITHUB_OUTPUT GITHUB_REPOSITORY GITHUB_RUN_ATTEMPT
    GITHUB_RUN_ID GITHUB_SERVER_URL GITHUB_STEP_SUMMARY GITHUB_WORKSPACE HOME PATH
  ].freeze

  # Steps whose outputs come from a third-party action rather than a script of ours.
  EXTERNAL_OUTPUT_STEPS = %w[app_token].freeze

  def action
    @action ||= YAML.safe_load_file(File.join(ACTION_ROOT, "action.yml"), aliases: true)
  end

  def steps
    action.fetch("runs").fetch("steps")
  end

  def read(path)
    File.read(File.join(ACTION_ROOT, path), encoding: Encoding::UTF_8)
  end

  def entry_points
    Dir[File.join(ACTION_ROOT, "bin", "*.rb")].sort.map { |path| "bin/#{File.basename(path)}" }
  end

  # Follows require_relative from an entry point, so each step is checked against the
  # environment its own code reads rather than the union of every script's.
  #
  # Paths are resolved against ACTION_ROOT rather than the working directory: these
  # specs run both from the repository root and from test-plans/, and resolving
  # relatively would quietly find nothing from one of them, leaving every check here
  # passing against an empty set.
  def sources(entry, seen = [])
    return seen if seen.include?(entry)

    seen << entry
    directory = File.dirname(File.join(ACTION_ROOT, entry))
    read(entry).scan(/require_relative "([^"]+)"/).flatten.each do |target|
      resolved = File.expand_path(target, directory).delete_prefix("#{ACTION_ROOT}/")
      resolved = "#{resolved}.rb" unless resolved.end_with?(".rb")
      sources(resolved, seen) if File.exist?(File.join(ACTION_ROOT, resolved))
    end
    seen
  end

  def ruby_env_reads(entry)
    sources(entry).flat_map do |source|
      read(source).scan(/ENV\.fetch\("([A-Z_]+)"|ENV\["([A-Z_]+)"\]/).flatten.compact
    end.uniq
  end

  # Shell reads, minus anything the script assigns itself.
  def shell_env_reads(path)
    body = read(path)
    assigned = body.scan(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=/).flatten
    body.scan(/\$\{([A-Z_][A-Z0-9_]*)[:}]/).flatten.uniq - assigned
  end

  def step_running(script)
    steps.find { |step| step.fetch("run", "").include?(script) }
  end

  def profile_output_keys
    TestPlan::Profile.load(action_root: ACTION_ROOT, profile_id: "cobra-test-plan").to_h.keys
  end

  def outputs_written_by(step)
    entry = step.fetch("run", "")[%r{bin/\w+\.rb}]
    return [] unless entry

    sources(entry).flat_map do |source|
      body = read(source)
      keys = body.scan(/output\.puts\("([a-z_]+)=/).flatten
      # resolve_profile writes whatever Profile#to_h is keyed on, not literals.
      keys += profile_output_keys if body.include?('"#{key}=#{value}"')
      keys
    end.uniq
  end

  def outputs_consumed
    read("action.yml")
      .scan(/steps\.([a-z_]+)\.outputs\.([a-z_]+)/)
      .reject { |id, _name| EXTERNAL_OUTPUT_STEPS.include?(id) }
      .uniq
  end
end

RSpec.describe "action.yml wiring" do
  describe "environment" do
    ActionWiring.entry_points.each do |entry|
      it "#{entry} only reads variables its step provides" do
        step = ActionWiring.step_running(entry)
        expect(step).not_to(be_nil, -> { "no action.yml step runs #{entry}" })

        provided = step.fetch("env", {}).keys + ActionWiring::AMBIENT
        expect(ActionWiring.ruby_env_reads(entry) - provided).to be_empty
      end
    end

    # Guards the checks above from passing against an empty set: every entry point is a
    # thin wrapper that requires its library code, so resolving one source means
    # resolution is broken and nothing below is really being checked.
    ActionWiring.entry_points.each do |entry|
      it "resolves the library code behind #{entry}" do
        expect(ActionWiring.sources(entry).length).to be > 1
      end
    end

    it "runs every bin entry point from some step" do
      orphaned = ActionWiring.entry_points.reject { |entry| ActionWiring.step_running(entry) }
      expect(orphaned).to be_empty
    end

    it "cursor.sh only reads variables the provider step provides" do
      step = ActionWiring.step_running("providers/${provider}.sh")
      provided = step.fetch("env", {}).keys + ActionWiring::AMBIENT

      expect(ActionWiring.shell_env_reads("providers/cursor.sh") - provided).to be_empty
    end
  end

  describe "step outputs" do
    it "consumes only outputs the corresponding script writes" do
      written = ActionWiring.steps.each_with_object({}) do |step, index|
        index[step["id"]] = ActionWiring.outputs_written_by(step) if step["id"]
      end

      missing = ActionWiring.outputs_consumed.reject do |id, name|
        written.fetch(id, []).include?(name)
      end

      expect(missing).to be_empty
    end
  end

  describe "files handed between steps" do
    it "spells each shared path the same way in every step that touches it" do
      paths = Hash.new { |hash, key| hash[key] = [] }
      ActionWiring.steps.each do |step|
        step.fetch("env", {}).each do |name, value|
          paths[name] << value if value.to_s.include?("github.workspace")
        end
      end

      expect(paths.select { |_name, values| values.uniq.length > 1 }).to be_empty
    end

    it "uploads every workspace file the steps produce" do
      produced = ActionWiring.steps
        .flat_map { |step| step.fetch("env", {}).values }
        .grep(/github\.workspace/)
        .map { |value| File.basename(value) }
        .uniq
        # Comments are posted, not archived.
        .reject { |name| name.end_with?("-comment.md") }

      upload = ActionWiring.steps.find { |step| step.fetch("name", "").include?("Upload") }
      uploaded = upload.dig("with", "path").to_s

      expect(produced.reject { |name| uploaded.include?(name) }).to be_empty
    end
  end
end
