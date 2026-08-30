require_relative "../spec_helper"

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "providers/cursor.sh" do
  let(:script) { File.join(ACTION_ROOT, "providers", "cursor.sh") }

  def agent_script(args_path)
    <<~AGENT
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{args_path}"
      case "${AGENT_MODE}" in
        ok)     echo '{"permissions":{"required":"no"}}' ;;
        empty)  : ;;
        prose)  echo 'Cannot use this model: bogus-model' ;;
        fail)   echo 'Cannot use this model: bogus-model'; exit 3 ;;
      esac
    AGENT
  end

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
      File.write(File.join(bin, "agent"), agent_script(args_path))
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

  # The install branch is skipped by every example above, because they put `agent` on
  # PATH -- yet it is the branch that runs on a real runner, where the CLI is absent.
  # A fake curl stands in for the download so the branch executes end to end.
  #
  # The installer is placed through TMPDIR, which mktemp only honours when given a
  # template on BSD; without one this would inspect a directory nothing ever wrote to.
  def run_install(installer_body:)
    Dir.mktmpdir do |root|
      workspace = File.join(root, "workspace")
      bin = File.join(root, "bin")
      home = File.join(root, "home")
      temp = File.join(root, "tmp")
      FileUtils.mkdir_p([workspace, bin, home, temp])

      args_path = File.join(root, "agent-args")
      File.write(File.join(bin, "curl"), <<~CURL)
        #!/usr/bin/env bash
        out=""
        while [[ $# -gt 0 ]]; do
          case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
        done
        cat > "${out}" <<'INSTALLER'
        #{installer_body.call(args_path).gsub("\n", "\n        ")}
        INSTALLER
      CURL
      FileUtils.chmod(0o755, File.join(bin, "curl"))

      prompt = File.join(root, "prompt.md")
      File.write(prompt, "Generate a plan.")
      json_path = File.join(root, "test-plan-agent.json")

      env = {
        # No `agent` on PATH, so the script has to install one.
        "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
        "HOME" => home,
        "TMPDIR" => temp,
        "AGENT_MODE" => "ok",
        "GITHUB_WORKSPACE" => workspace,
        "TEST_PLAN_JSON_PATH" => json_path,
        "TEST_PLAN_PROMPT_PATH" => prompt,
        "PROVIDER_API_KEY" => "crsr_test",
        "MODEL" => "claude-opus-5-high",
      }
      _stdout, stderr, status = Open3.capture3(env, "bash", script, unsetenv_others: false)

      yield(
        status: status,
        stderr: stderr,
        output: File.exist?(json_path) ? File.read(json_path) : nil,
        installed: File.join(home, ".local", "bin", "agent"),
        temp: temp
      )
    end
  end

  def working_installer
    lambda do |args_path|
      body = agent_script(args_path).gsub("\n", "\\n").gsub('"', '\\"')
      <<~SH.strip
        #!/usr/bin/env bash
        mkdir -p "${HOME}/.local/bin"
        printf "#{body}" > "${HOME}/.local/bin/agent"
        chmod +x "${HOME}/.local/bin/agent"
      SH
    end
  end

  it "downloads and runs the installer when the CLI is absent" do
    run_install(installer_body: working_installer) do |result|
      expect(result[:status]).to be_success
      expect(result[:output]).to include('"permissions"')
      expect(File.executable?(result[:installed])).to be(true)

      # Logged before it is executed, so a surprising run has something to compare to.
      expect(result[:stderr]).to match(/Cursor installer: +\d+ bytes, sha256 [0-9a-f]{64}/)
      expect(Dir.children(result[:temp])).to be_empty
    end
  end

  it "cleans up the downloaded installer even when it fails" do
    failing = ->(_args_path) { "#!/usr/bin/env bash\nexit 7\n" }

    run_install(installer_body: failing) do |result|
      expect(result[:status]).not_to be_success
      # The explicit removal is never reached, so the trap is what clears it.
      expect(Dir.children(result[:temp])).to be_empty
    end
  end
end
