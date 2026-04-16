#!/usr/bin/env ruby

class StatusCommentBuilder
  SUPPORT_URL = "https://nitro.powerhrg.com/connect/#rooms/138"

  def initialize(run_url:, version:, run_id:, run_attempt:, provider:, model:, started_at:, agent_cli_version: nil)
    @run_url = run_url
    @version = version
    @run_id = run_id
    @run_attempt = run_attempt
    @provider = provider
    @model = model
    @started_at = started_at
    @agent_cli_version = agent_cli_version
  end

  def in_progress_body
    [
      ":hourglass_flowing_sand: **Agentic PR Review** — in progress",
      "",
      "[View workflow run](#{@run_url})",
      "",
      metadata_block,
      "<!-- agentic-pr-review:status=in_progress -->",
    ].join("\n")
  end

  def failure_body(duration_seconds:)
    human = format_duration(duration_seconds)

    [
      ":x: **Agentic PR Review** — failed after #{human}",
      "",
      "[View workflow run](#{@run_url}) for details. If this looks like a transient error, re-run the job. For persistent failures, reach out in [Nitro Dev Discuss](#{SUPPORT_URL}).",
      "",
      metadata_block,
      "<!-- agentic-pr-review:completed_at=#{now_utc} -->",
      "<!-- agentic-pr-review:duration_seconds=#{duration_seconds} -->",
      "<!-- agentic-pr-review:status=failure -->",
    ].join("\n")
  end

private

  def format_duration(seconds)
    if seconds >= 60
      "#{seconds / 60}m #{seconds % 60}s"
    else
      "#{seconds}s"
    end
  end

  def now_utc
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  def metadata_block
    lines = [
      "<!-- agentic-pr-review:version=#{@version} -->",
      "<!-- agentic-pr-review:run_id=#{@run_id} -->",
      "<!-- agentic-pr-review:run_attempt=#{@run_attempt} -->",
      "<!-- agentic-pr-review:provider=#{@provider} -->",
      "<!-- agentic-pr-review:model=#{@model} -->",
      "<!-- agentic-pr-review:started_at=#{@started_at} -->",
    ]
    if @agent_cli_version && !@agent_cli_version.to_s.empty?
      lines << "<!-- agentic-pr-review:agent_cli_version=#{@agent_cli_version} -->"
    end
    lines.join("\n")
  end
end
