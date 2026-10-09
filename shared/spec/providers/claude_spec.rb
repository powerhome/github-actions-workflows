# frozen_string_literal: true

require_relative "../spec_helper"

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "providers/claude.sh" do
  let(:script) { File.join(SHARED_ROOT, "providers", "claude.sh") }

  def claude_script(args_path)
    <<~CLAUDE
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{args_path}"
      case "${CLAUDE_MODE}" in
        ok)   echo '{"summary":"Looks fine"}' ;;
        fail) echo 'Invalid API key'; exit 2 ;;
      esac
    CLAUDE
  end

  # HOME is redirected at a scratch directory so the script's own
  # `export PATH="${HOME}/.local/bin:${PATH}"` cannot find a real Claude CLI. Ruby's own
  # directory is on PATH because claude-args are split with it.
  def run_provider(mode: "ok", env: {}, install: nil)
    Dir.mktmpdir do |root|
      workspace = File.join(root, "workspace")
      bin = File.join(root, "bin")
      home = File.join(root, "home")
      temp = File.join(root, "tmp")
      FileUtils.mkdir_p([workspace, bin, home, temp])

      args_path = File.join(root, "claude-args")
      if install
        write_fake_curl(bin, install.call(claude_script(args_path)))
      else
        File.write(File.join(bin, "claude"), claude_script(args_path))
        FileUtils.chmod(0o755, File.join(bin, "claude"))
      end

      prompt = File.join(root, "prompt.md")
      File.write(prompt, "Review this.")
      json_path = File.join(root, "agent.json")

      env = env.merge(
        "PATH" => "#{bin}:#{File.dirname(RbConfig.ruby)}:#{SYSTEM_PATH}",
        "HOME" => home,
        "TMPDIR" => temp,
        "CLAUDE_MODE" => mode,
        "GITHUB_WORKSPACE" => workspace,
        "AGENT_OUTPUT_PATH" => json_path,
        "AGENT_PROMPT_PATH" => prompt,
        "PROVIDER_API_KEY" => "sk-ant-test"
      )
      _stdout, stderr, status = Open3.capture3(env, "bash", script, unsetenv_others: false)

      yield(
        status:,
        stderr:,
        output: File.exist?(json_path) ? File.read(json_path) : nil,
        args: File.exist?(args_path) ? File.read(args_path).split("\n") : [],
        temp:
      )
    end
  end

  # base64 rather than a heredoc, so the installer arrives byte for byte.
  def write_fake_curl(bin, installer)
    payload = [installer].pack("m0")
    File.write(File.join(bin, "curl"), <<~CURL)
      #!/usr/bin/env bash
      out=""
      while [[ $# -gt 0 ]]; do
        case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
      done
      printf %s '#{payload}' | base64 --decode > "${out}"
    CURL
    FileUtils.chmod(0o755, File.join(bin, "curl"))
  end

  it "runs the CLI read-only, unconfigurable by the checkout, with the bundled settings" do
    run_provider do |result|
      expect(result[:status]).to be_success
      expect(result[:output]).to include('"summary"')
      expect(result[:stderr]).to include("provider: claude")

      args = result[:args]
      expect(args.each_cons(2)).to include(
        ["--setting-sources", "user"],
        ["--settings", File.join(SHARED_ROOT, "config", "claude-settings.json")],
        ["--permission-mode", "dontAsk"]
      )
      expect(args).to include("--strict-mcp-config")
      expect(args).not_to include("--model")
      expect(args.last).to eq("Review this.")
    end
  end

  it "bundles settings that deny shell, edits, and the web" do
    settings = File.read(File.join(SHARED_ROOT, "config", "claude-settings.json"))
    expect(settings).to include('"disableAllHooks": true', '"Bash"', '"Write"', '"WebFetch"', '"WebSearch"')
  end

  it "passes the model, caller settings, and caller arguments through" do
    env = {
      "MODEL" => "claude-opus-5-5",
      "CLAUDE_SETTINGS" => '{"permissions":{}}',
      "CLAUDE_ARGS" => '--allowed-tools "Bash(gh pr view:*)" --max-turns 30',
    }

    run_provider(env:) do |result|
      expect(result[:status]).to be_success
      expect(result[:args].each_cons(2)).to include(
        ["--model", "claude-opus-5-5"],
        ["--settings", '{"permissions":{}}'],
        ["--allowed-tools", "Bash(gh pr view:*)"],
        ["--max-turns", "30"]
      )
    end
  end

  it "surfaces the CLI's own message when it exits non-zero" do
    run_provider(mode: "fail") do |result|
      expect(result[:status].exitstatus).to eq(2)
      expect(result[:stderr]).to include("failed with exit 2", "Invalid API key")
    end
  end

  it "downloads the installer before running it when the CLI is absent" do
    installer = lambda do |claude|
      body = claude.gsub("\n", "\\n").gsub('"', '\\"')
      <<~SH.strip
        #!/usr/bin/env bash
        mkdir -p "${HOME}/.local/bin"
        printf "#{body}" > "${HOME}/.local/bin/claude"
        chmod +x "${HOME}/.local/bin/claude"
      SH
    end

    run_provider(install: installer) do |result|
      expect(result[:status]).to be_success
      expect(result[:output]).to include('"summary"')
      expect(result[:stderr]).to match(/Claude installer: +\d+ bytes, sha256 [0-9a-f]{64}/)
      expect(Dir.children(result[:temp])).to be_empty
    end
  end
end
