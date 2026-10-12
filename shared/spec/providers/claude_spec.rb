# frozen_string_literal: true

require_relative "../spec_helper"

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "providers/claude.sh" do
  let(:script) { File.join(SHARED_ROOT, "providers", "claude.sh") }

  # Its environment, and the identity token it would read, are recorded beside its arguments.
  def claude_script(args_path)
    <<~CLAUDE
      #!/usr/bin/env bash
      printf '%s\\n' "$@" > "#{args_path}"
      env > "#{args_path}.env"
      if [[ -n "${ANTHROPIC_IDENTITY_TOKEN_FILE:-}" ]]; then
        cat "${ANTHROPIC_IDENTITY_TOKEN_FILE}" > "#{args_path}.jwt"
      fi
      case "${CLAUDE_MODE}" in
        ok)   echo '{"summary":"Looks fine"}' ;;
        fail) echo 'Invalid API key'; exit 2 ;;
      esac
    CLAUDE
  end

  # HOME is redirected at a scratch directory so the script's own
  # `export PATH="${HOME}/.local/bin:${PATH}"` cannot find a real Claude CLI. Ruby's own
  # directory is on PATH because claude-args are split with it.
  def run_provider(mode: "ok", env: {}, install: nil, oidc: nil)
    Dir.mktmpdir do |root|
      workspace = File.join(root, "workspace")
      bin = File.join(root, "bin")
      home = File.join(root, "home")
      temp = File.join(root, "tmp")
      FileUtils.mkdir_p([workspace, bin, home, temp])

      args_path = File.join(root, "claude-args")
      curl_log = File.join(root, "curl-log")
      if install
        write_fake_curl(bin, install.call(claude_script(args_path)))
      else
        write_fake_oidc_curl(bin, curl_log, oidc) if oidc
        File.write(File.join(bin, "claude"), claude_script(args_path))
        FileUtils.chmod(0o755, File.join(bin, "claude"))
      end

      prompt = File.join(root, "prompt.md")
      File.write(prompt, "Review this.")
      json_path = File.join(root, "agent.json")

      # A nil value unsets the variable, so a test can drop the default key.
      env = { "PROVIDER_API_KEY" => "sk-ant-test" }.merge(env).merge(
        "PATH" => "#{bin}:#{File.dirname(RbConfig.ruby)}:#{SYSTEM_PATH}",
        "HOME" => home,
        "TMPDIR" => temp,
        "CLAUDE_MODE" => mode,
        "GITHUB_WORKSPACE" => workspace,
        "AGENT_OUTPUT_PATH" => json_path,
        "AGENT_PROMPT_PATH" => prompt
      )
      _stdout, stderr, status = Open3.capture3(env, "bash", script, unsetenv_others: false)

      yield(
        status:,
        stderr:,
        output: File.exist?(json_path) ? File.read(json_path) : nil,
        args: File.exist?(args_path) ? File.read(args_path).split("\n") : [],
        claude_env: read_env("#{args_path}.env"),
        jwt: File.exist?("#{args_path}.jwt") ? File.read("#{args_path}.jwt") : nil,
        curl: File.exist?(curl_log) ? File.read(curl_log) : "",
        temp:
      )
    end
  end

  def read_env(path)
    return {} unless File.exist?(path)

    File.read(path).lines.to_h { |line| line.chomp.split("=", 2) }
  end

  # Stands in for GitHub's OIDC token endpoint, logging its arguments and the config it
  # was handed on stdin.
  def write_fake_oidc_curl(bin, log, response)
    File.write(File.join(bin, "curl"), <<~CURL)
      #!/usr/bin/env bash
      printf 'args:%s\\n' "$*" >> "#{log}"
      printf 'stdin:%s\\n' "$(cat)" >> "#{log}"
      printf %s '#{response}'
    CURL
    FileUtils.chmod(0o755, File.join(bin, "curl"))
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
      # On the command line, so a caller's claude-settings cannot drop it.
      expect(args.each_cons(2)).to include(["--disallowed-tools", "Read(//proc/**)"])
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

  it "fails without an API key or a federation rule" do
    run_provider(env: { "PROVIDER_API_KEY" => nil }) do |result|
      expect(result[:status]).not_to be_success
      expect(result[:stderr]).to include("needs PROVIDER_API_KEY or ANTHROPIC_FEDERATION_RULE_ID")
      expect(result[:args]).to be_empty
    end
  end

  describe "workload identity federation" do
    # Empty values are what a composite step passes for inputs the caller left out.
    let(:federation) do
      {
        "PROVIDER_API_KEY" => "",
        "ANTHROPIC_FEDERATION_RULE_ID" => "fdrl_test",
        "ANTHROPIC_ORGANIZATION_ID" => "org-test",
        "ANTHROPIC_SERVICE_ACCOUNT_ID" => "svac_test",
        "ANTHROPIC_WORKSPACE_ID" => "",
        "ACTIONS_ID_TOKEN_REQUEST_URL" => "https://token.example/request?api-version=2",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => "request-token",
        "ANTHROPIC_AUTH_TOKEN" => "from-the-job-env",
      }
    end

    it "hands the CLI a GitHub OIDC token file and no competing credential" do
      run_provider(env: federation, oidc: '{"value":"github-jwt"}') do |result|
        expect(result[:status]).to be_success
        expect(result[:stderr]).to include("workload identity federation")

        expect(result[:curl]).to include("audience=https%3A%2F%2Fapi.anthropic.com")
        expect(result[:curl]).to include('stdin:header = "Authorization: bearer request-token"')
        expect(result[:curl]).not_to match(/^args:.*request-token/)

        env = result[:claude_env]
        expect(env).to include(
          "ANTHROPIC_FEDERATION_RULE_ID" => "fdrl_test",
          "ANTHROPIC_ORGANIZATION_ID" => "org-test",
          "ANTHROPIC_SERVICE_ACCOUNT_ID" => "svac_test"
        )
        expect(env.keys).not_to include(
          "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_WORKSPACE_ID",
          "ACTIONS_ID_TOKEN_REQUEST_URL", "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
        )
        expect(result[:jwt]).to eq("github-jwt")

        # The agent can read anywhere else, and the file always holds an unused JWT.
        identity_dir = File.dirname(env.fetch("ANTHROPIC_IDENTITY_TOKEN_FILE"))
        after_flag = result[:args].drop(result[:args].index("--disallowed-tools") + 1)
        denied = after_flag.take_while { |arg| !arg.start_with?("--") }
        expect(denied).to contain_exactly("Read(//proc/**)", "Read(/#{identity_dir}/**)")
        # The token's directory goes with the run.
        expect(File.exist?(env.fetch("ANTHROPIC_IDENTITY_TOKEN_FILE"))).to be(false)
      end
    end

    it "passes a workspace ID through when one is given" do
      env = federation.merge("ANTHROPIC_WORKSPACE_ID" => "wrkspc_test")

      run_provider(env:, oidc: '{"value":"github-jwt"}') do |result|
        expect(result[:status]).to be_success
        expect(result[:claude_env]).to include("ANTHROPIC_WORKSPACE_ID" => "wrkspc_test")
      end
    end

    it "asks for id-token: write when the job cannot mint an OIDC token" do
      env = federation.merge("ACTIONS_ID_TOKEN_REQUEST_URL" => nil, "ACTIONS_ID_TOKEN_REQUEST_TOKEN" => nil)

      run_provider(env:) do |result|
        expect(result[:status]).not_to be_success
        expect(result[:stderr]).to include("id-token: write")
        expect(result[:args]).to be_empty
      end
    end

    it "fails before the CLI runs when the OIDC endpoint returns no token" do
      run_provider(env: federation, oidc: "{}") do |result|
        expect(result[:status]).not_to be_success
        expect(result[:stderr]).to include("Could not fetch a GitHub OIDC token")
        expect(result[:args]).to be_empty
        expect(Dir.children(result[:temp])).to be_empty
      end
    end

    it "requires the service account alongside the rule" do
      env = federation.merge("ANTHROPIC_SERVICE_ACCOUNT_ID" => "")

      run_provider(env:, oidc: '{"value":"github-jwt"}') do |result|
        expect(result[:status]).not_to be_success
        expect(result[:stderr]).to include("ANTHROPIC_SERVICE_ACCOUNT_ID is required")
      end
    end

    it "refuses an API key and a federation rule together" do
      env = federation.merge("PROVIDER_API_KEY" => "sk-ant-test")

      run_provider(env:, oidc: '{"value":"github-jwt"}') do |result|
        expect(result[:status]).not_to be_success
        expect(result[:stderr]).to include("not both")
        expect(result[:args]).to be_empty
      end
    end

    it "keeps empty federation inputs away from an API-key run" do
      env = { "ANTHROPIC_FEDERATION_RULE_ID" => "", "ANTHROPIC_ORGANIZATION_ID" => "" }

      run_provider(env:) do |result|
        expect(result[:status]).to be_success
        expect(result[:claude_env]).to include("ANTHROPIC_API_KEY" => "sk-ant-test")
        expect(result[:claude_env].keys).not_to include("ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID")
      end
    end
  end
end
