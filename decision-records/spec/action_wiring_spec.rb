# frozen_string_literal: true

require_relative "spec_helper"

require "open3"
require "rbconfig"
require "yaml"

ACTION_ROOT = File.expand_path("..", __dir__)

# action.yml and the script spell the same environment variable names, so a rename in one
# fails on a real pull request rather than here.
RSpec.describe "decision-records action wiring" do
  let(:action) { YAML.safe_load_file(File.join(ACTION_ROOT, "action.yml")) }
  let(:step) { action.fetch("runs").fetch("steps").first }
  let(:script) { File.read(File.join(ACTION_ROOT, "bin/check_decision_records.rb")) }

  it "passes every input to the script through a variable the script reads" do
    expect(step.fetch("env").keys).to all(satisfy { |name| script.include?(%("#{name}")) })
    action.fetch("inputs").each_key do |input|
      expect(step.fetch("env").values).to include("${{ inputs.#{input} }}")
    end
  end

  it "fails a run with problems and annotates them for GitHub" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs/decisions"))
      File.write(File.join(root, "docs/decisions/0001-bare.md"), "# A decision\n")

      env = {
        "GITHUB_ACTIONS" => "true",
        "GITHUB_WORKSPACE" => root,
        "DECISION_RECORDS_ADR_DIRS" => "docs/decisions\n",
        "DECISION_RECORDS_CIR_DIRS" => "",
        "DECISION_RECORDS_MKDOCS" => "mkdocs.yml"
      }
      script = File.join(ACTION_ROOT, "bin/check_decision_records.rb")
      stdout, _stderr, status = Open3.capture3(env, RbConfig.ruby, script)

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("::error file=docs/decisions/0001-bare.md::missing YAML front matter")
    end
  end

  it "passes a clean run from the command line" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs/cir"))
      stdout, _stderr, status = Open3.capture3(
        { "GITHUB_ACTIONS" => nil, "GITHUB_WORKSPACE" => nil },
        RbConfig.ruby, File.join(ACTION_ROOT, "bin/check_decision_records.rb"), "--root", root, "--cir", "docs/cir"
      )

      expect(status.exitstatus).to eq(0)
      expect(stdout).to include("follow RFC 0110")
    end
  end
end
