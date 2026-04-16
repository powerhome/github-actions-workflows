#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "rspec/autorun"

require_relative "status_comment_builder"

RSpec.describe StatusCommentBuilder do
  let(:run_url) { "https://github.com/acme/widgets/actions/runs/123/attempts/1" }

  let(:builder) do
    described_class.new(
      run_url:,
      version: "1.1.0",
      run_id: "123",
      run_attempt: "1",
      provider: "cursor",
      model: "gpt-4",
      started_at: "2026-04-15T12:00:00Z",
    )
  end

  describe "#in_progress_body" do
    subject(:body) { builder.in_progress_body }

    it "includes the in-progress header" do
      expect(body).to include(":hourglass_flowing_sand: **Agentic PR Review** — in progress")
    end

    it "links to the workflow run" do
      expect(body).to include("[View workflow run](#{run_url})")
    end

    it "includes all metadata comments" do
      expect(body).to include("<!-- agentic-pr-review:version=1.1.0 -->")
      expect(body).to include("<!-- agentic-pr-review:run_id=123 -->")
      expect(body).to include("<!-- agentic-pr-review:run_attempt=1 -->")
      expect(body).to include("<!-- agentic-pr-review:provider=cursor -->")
      expect(body).to include("<!-- agentic-pr-review:model=gpt-4 -->")
      expect(body).to include("<!-- agentic-pr-review:started_at=2026-04-15T12:00:00Z -->")
      expect(body).to include("<!-- agentic-pr-review:status=in_progress -->")
    end

    it "does not include agent_cli_version when not provided" do
      expect(body).not_to include("agent_cli_version")
    end
  end

  describe "#failure_body" do
    it "includes the failure header with duration" do
      body = builder.failure_body(duration_seconds: 45)
      expect(body).to include(":x: **Agentic PR Review** — failed after 45s")
    end

    it "includes retry guidance and support link" do
      body = builder.failure_body(duration_seconds: 10)
      expect(body).to include("re-run the job")
      expect(body).to include("[Nitro Dev Discuss](#{StatusCommentBuilder::SUPPORT_URL})")
    end

    it "includes failure metadata" do
      body = builder.failure_body(duration_seconds: 10)
      expect(body).to include("<!-- agentic-pr-review:status=failure -->")
      expect(body).to include("<!-- agentic-pr-review:duration_seconds=10 -->")
    end

  end

  describe "agent_cli_version" do
    it "includes the version in metadata when provided" do
      builder_with_cli = described_class.new(
        run_url:,
        version: "1.1.0",
        run_id: "1",
        run_attempt: "1",
        provider: "cursor",
        model: "gpt-4",
        started_at: "2026-04-15T12:00:00Z",
        agent_cli_version: "0.45.0",
      )
      body = builder_with_cli.in_progress_body
      expect(body).to include("<!-- agentic-pr-review:agent_cli_version=0.45.0 -->")
    end
  end
end
