# frozen_string_literal: true

require_relative "spec_helper"

require "open3"

RSpec.describe "bin/run_provider.sh" do
  let(:script) { File.join(SHARED_ROOT, "bin", "run_provider.sh") }

  def run(provider)
    Open3.capture3({ "PROVIDER" => provider, "PATH" => SYSTEM_PATH }, "bash", script)
  end

  # The name becomes part of a path, and the provider credential is in the environment.
  it "refuses a name that could reach outside providers/" do
    _stdout, stderr, status = run("../bin/comment")

    expect(status).not_to be_success
    expect(stderr).to include("Invalid provider name")
  end

  it "refuses a provider with no script" do
    _stdout, stderr, status = run("gemini")

    expect(status).not_to be_success
    expect(stderr).to include("Unknown provider: gemini")
  end

  it "has a script for every provider the actions document" do
    %w[cursor claude].each do |provider|
      expect(File).to exist(File.join(SHARED_ROOT, "providers", "#{provider}.sh"))
    end
  end
end
