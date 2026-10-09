# frozen_string_literal: true

require_relative "../spec_helper"

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe "providers/cursor.sh" do
  let(:script) { File.join(SHARED_ROOT, "providers", "cursor.sh") }

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
  def run_provider(mode:, env: {}, before: nil)
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
      json_path = File.join(root, "agent.json")
      before&.call(workspace:, root:, json_path:)

      env = env.merge(
        "PATH" => "#{bin}:#{SYSTEM_PATH}",
        "HOME" => home,
        "AGENT_MODE" => mode,
        "GITHUB_WORKSPACE" => workspace,
        "AGENT_OUTPUT_PATH" => json_path,
        "AGENT_PROMPT_PATH" => prompt,
        "PROVIDER_API_KEY" => "crsr_test"
      )
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
      # The web denials matter as much as the shell one: everything the agent says has to
      # come from evidence the calling action assembled.
      expect(File.read(config)).to include("Read(**)", "Shell(*)", "WebFetch(*)", "WebSearch(*)")
    end
  end

  it "passes a caller-chosen model through" do
    run_provider(mode: "ok", env: { "MODEL" => "gpt-5" }) do |result|
      expect(result[:status]).to be_success
      expect(result[:agent_args].each_cons(2)).to include(["--model", "gpt-5"])
    end
  end

  # The workspace is the pull request's head, so it can plant a symlink where the config
  # is copied, which would otherwise carry the write outside the workspace.
  it "replaces a symlinked .cursor rather than writing through it" do
    outside = nil
    plant = lambda do |workspace:, root:, **|
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)
      File.symlink(outside, File.join(workspace, ".cursor"))
    end

    run_provider(mode: "ok", before: plant) do |result|
      expect(result[:status]).to be_success
      expect(File.symlink?(File.join(result[:workspace], ".cursor"))).to be(false)
      expect(Dir.children(outside)).to be_empty
    end
  end

  it "replaces a symlink at the output path rather than writing through it" do
    target = nil
    plant = lambda do |root:, json_path:, **|
      target = File.join(root, "target")
      File.write(target, "untouched")
      File.symlink(target, json_path)
    end

    run_provider(mode: "ok", before: plant) do |result|
      expect(result[:output]).to include("\"permissions\"")
      expect(File.read(target)).to eq("untouched")
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
      json_path = File.join(root, "agent.json")

      env = {
        # No `agent` on PATH, so the script has to install one.
        "PATH" => "#{bin}:#{SYSTEM_PATH}",
        "HOME" => home,
        "TMPDIR" => temp,
        "AGENT_MODE" => "ok",
        "GITHUB_WORKSPACE" => workspace,
        "AGENT_OUTPUT_PATH" => json_path,
        "AGENT_PROMPT_PATH" => prompt,
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
