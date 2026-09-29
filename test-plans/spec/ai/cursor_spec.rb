# frozen_string_literal: true

require_relative "../spec_helper"

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "ai/providers/cursor.sh" do
  # System directories only. Inheriting the caller's PATH meant a real Cursor CLI on this
  # machine was found by `command -v agent`, skipping the install branch and running the
  # actual agent against a scratch workspace.
  SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin".freeze

  let(:script) { File.join(ACTION_ROOT, "ai", "providers", "cursor.sh") }

  def agent_script(args_path)
    <<~AGENT
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{args_path}"
      case "${AGENT_MODE}" in
        ok)     echo '{"permissions":{"required":"no"}}' ;;
        empty)  : ;;
        prose)  echo 'The agent returned prose instead of JSON' ;;
        fail)   echo 'The agent refused the workspace'; exit 3 ;;
      esac
    AGENT
  end

  # HOME is redirected at a scratch directory so the script's own
  # `export PATH="${HOME}/.local/bin:${PATH}"` cannot find a real Cursor CLI.
  def run_provider(mode:)
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
        "PATH" => "#{bin}:#{SYSTEM_PATH}",
        "HOME" => home,
        "AGENT_MODE" => mode,
        "GITHUB_WORKSPACE" => workspace,
        "TEST_PLAN_JSON_PATH" => json_path,
        "TEST_PLAN_PROMPT_PATH" => prompt,
        "PROVIDER_API_KEY" => "crsr_test",
      }
      stdout, stderr, status = Open3.capture3(env, "bash", script, unsetenv_others: false)

      yield(
        status:,
        stdout:,
        stderr:,
        output: File.exist?(json_path) ? File.read(json_path) : nil,
        agent_args: File.exist?(args_path) ? File.read(args_path).split("\n") : [],
        workspace:
      )
    end
  end

  it "writes the agent's response without pinning a model" do
    run_provider(mode: "ok") do |result|
      expect(result[:status]).to be_success
      expect(result[:output]).to include('"permissions"')
      expect(result[:agent_args]).not_to include("--model")
      expect(result[:stderr]).to include("provider: cursor")
    end
  end

  it "installs the read-only CLI permissions into the workspace" do
    run_provider(mode: "ok") do |result|
      config = File.join(result[:workspace], ".cursor", "cli-config.json")
      # The web denials matter as much as the shell one: everything the plan says comes
      # from evidence this action assembled.
      expect(File.read(config)).to include("Read(**)", "Shell(*)", "WebFetch(*)", "WebSearch(*)")
    end
  end

  it "surfaces the agent's own message when it exits non-zero" do
    # The agent writes errors to stdout, which the redirect captures into the output file
    # rather than the log; without echoing it back the run shows only an exit code.
    run_provider(mode: "fail") do |result|
      expect(result[:status].exitstatus).to eq(3)
      expect(result[:stderr]).to include("failed with exit 3", "The agent refused the workspace")
    end
  end

  it "fails when the agent exits zero having written nothing" do
    run_provider(mode: "empty") do |result|
      expect(result[:status]).not_to be_success
      expect(result[:stderr]).to include("produced no output")
    end
  end

  it "fails when the response contains no JSON object" do
    run_provider(mode: "prose") do |result|
      expect(result[:status]).not_to be_success
      expect(result[:stderr]).to include("returned no JSON object")
      expect(result[:stderr]).to include("The agent returned prose instead of JSON")
    end
  end

  # Every example above puts `agent` on PATH and skips the install branch -- yet that is
  # the branch a real runner takes. A fake curl stands in for the download.
  #
  # TMPDIR is only honoured by mktemp when given a template on BSD; without one this would
  # inspect a directory nothing ever wrote to.
  def run_install(installer_body:)
    Dir.mktmpdir do |root|
      workspace = File.join(root, "workspace")
      bin = File.join(root, "bin")
      home = File.join(root, "home")
      temp = File.join(root, "tmp")
      FileUtils.mkdir_p([workspace, bin, home, temp])

      args_path = File.join(root, "agent-args")
      # base64 rather than a heredoc, which always emits a trailing newline: an empty
      # download has to arrive as zero bytes, the size the script checks for.
      payload = [installer_body.call(args_path)].pack("m0")
      File.write(File.join(bin, "curl"), <<~CURL)
        #!/usr/bin/env bash
        out=""
        while [[ $# -gt 0 ]]; do
          case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
        done
        printf %s '#{payload}' | base64 --decode > "${out}"
      CURL
      FileUtils.chmod(0o755, File.join(bin, "curl"))

      prompt = File.join(root, "prompt.md")
      File.write(prompt, "Generate a plan.")
      json_path = File.join(root, "test-plan-agent.json")

      env = {
        # No `agent` on PATH, so the script has to install one.
        "PATH" => "#{bin}:#{SYSTEM_PATH}",
        "HOME" => home,
        "TMPDIR" => temp,
        "AGENT_MODE" => "ok",
        "GITHUB_WORKSPACE" => workspace,
        "TEST_PLAN_JSON_PATH" => json_path,
        "TEST_PLAN_PROMPT_PATH" => prompt,
        "PROVIDER_API_KEY" => "crsr_test",
      }
      _stdout, stderr, status = Open3.capture3(env, "bash", script, unsetenv_others: false)

      yield(
        status:,
        stderr:,
        output: File.exist?(json_path) ? File.read(json_path) : nil,
        installed: File.join(home, ".local", "bin", "agent"),
        temp:
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

  it "fails on an empty download rather than running it as an installer" do
    empty = ->(_args_path) { "" }

    run_install(installer_body: empty) do |result|
      expect(result[:status]).not_to be_success
      expect(result[:stderr]).to include("Downloaded an empty Cursor installer")
      # bash runs an empty script happily, so without the size check this reads as an
      # installer that ran and placed nothing, a different problem.
      expect(result[:stderr]).not_to include("agent CLI not found after install")
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
