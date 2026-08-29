require_relative "../spec_helper"

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "providers/cursor.sh" do
  let(:script) { File.join(ACTION_ROOT, "providers", "cursor.sh") }

  # Runs the provider against a stubbed `agent` on PATH. HOME is redirected at a scratch
  # directory so the script's own `export PATH="${HOME}/.local/bin:${PATH}"` cannot pick
  # up a real Cursor CLI from the machine running the specs.
  def run_provider(mode:, model: nil)
    Dir.mktmpdir do |root|
      workspace = File.join(root, "workspace")
      bin = File.join(root, "bin")
      home = File.join(root, "home")
      FileUtils.mkdir_p([workspace, bin, home])

      args_path = File.join(root, "agent-args")
      File.write(File.join(bin, "agent"), <<~AGENT)
        #!/usr/bin/env bash
        printf '%s\\n' "$@" > "#{args_path}"
        case "${AGENT_MODE}" in
          ok)     echo '{"permissions":{"required":"no"}}' ;;
          empty)  : ;;
          prose)  echo 'Cannot use this model: bogus-model' ;;
          fail)   echo 'Cannot use this model: bogus-model'; exit 3 ;;
        esac
      AGENT
      FileUtils.chmod(0o755, File.join(bin, "agent"))

      prompt = File.join(root, "prompt.md")
      File.write(prompt, "Generate a plan.")
      json_path = File.join(root, "test-plan-agent.json")

      env = {
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "HOME" => home,
        "AGENT_MODE" => mode,
        "GITHUB_WORKSPACE" => workspace,
        "TEST_PLAN_JSON_PATH" => json_path,
        "TEST_PLAN_PROMPT_PATH" => prompt,
        "PROVIDER_API_KEY" => "crsr_test",
        "MODEL" => model.to_s,
      }
      stdout, stderr, status = Open3.capture3(env, "bash", script, unsetenv_others: false)

      yield(
        status: status,
        stdout: stdout,
        stderr: stderr,
        output: File.exist?(json_path) ? File.read(json_path) : nil,
        agent_args: File.exist?(args_path) ? File.read(args_path).split("\n") : [],
        workspace: workspace
      )
    end
  end

  it "writes the agent's response and reports the model it used" do
    run_provider(mode: "ok", model: "claude-opus-5-high") do |result|
      expect(result[:status]).to be_success
      expect(result[:output]).to include('"permissions"')
      expect(result[:stderr]).to include("model: claude-opus-5-high")
      expect(result[:agent_args]).to include("--model", "claude-opus-5-high")
    end
  end

  it "omits --model entirely when the profile pins none" do
    run_provider(mode: "ok", model: "") do |result|
      expect(result[:status]).to be_success
      expect(result[:agent_args]).not_to include("--model")
      expect(result[:stderr]).to include("model: cursor default")
    end
  end

  it "installs the read-only CLI permissions into the workspace" do
    run_provider(mode: "ok") do |result|
      config = File.join(result[:workspace], ".cursor", "cli-config.json")
      expect(File.read(config)).to include("Read(**)", "Shell(*)")
    end
  end

  it "surfaces the agent's own message when it exits non-zero" do
    # A rejected model is written to stdout, which the redirect captures into the output
    # file rather than the log; without echoing it back the run shows only an exit code.
    run_provider(mode: "fail", model: "bogus-model") do |result|
      expect(result[:status].exitstatus).to eq(3)
      expect(result[:stderr]).to include("failed with exit 3", "bogus-model")
      expect(result[:stderr]).to include("Cannot use this model")
    end
  end

  it "fails when the agent exits zero having written nothing" do
    run_provider(mode: "empty", model: "claude-opus-5-high") do |result|
      expect(result[:status]).not_to be_success
      expect(result[:stderr]).to include("produced no output", "claude-opus-5-high")
    end
  end

  it "fails when the response contains no JSON object" do
    run_provider(mode: "prose") do |result|
      expect(result[:status]).not_to be_success
      expect(result[:stderr]).to include("returned no JSON object")
      expect(result[:stderr]).to include("Cannot use this model")
    end
  end
end
