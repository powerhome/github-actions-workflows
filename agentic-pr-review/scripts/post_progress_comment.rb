#!/usr/bin/env ruby

require_relative "github_review_poster"
require_relative "status_comment_builder"

command = ARGV[0]
unless %w[create success failure].include?(command)
  warn "Usage: post_progress_comment.rb <create|success|failure>"
  exit 1
end

repo_full  = ENV.fetch("GITHUB_REPOSITORY")
owner, repo = repo_full.split("/", 2)
token      = ENV.fetch("GITHUB_TOKEN")
pr_number  = Integer(ENV.fetch("PR_NUMBER"))

poster = GitHubReviewPoster.new(owner:, repo:, pr_number:, token:)

def build_status_comment(repo_full)
  start_time  = Integer(ENV.fetch("START_TIME"))
  server_url  = ENV.fetch("GITHUB_SERVER_URL", "https://github.com")
  run_id      = ENV.fetch("GITHUB_RUN_ID")
  run_attempt = ENV.fetch("GITHUB_RUN_ATTEMPT", "1")

  builder = StatusCommentBuilder.new(
    run_url: "#{server_url}/#{repo_full}/actions/runs/#{run_id}/attempts/#{run_attempt}",
    version: ENV.fetch("ACTION_VERSION", "1.1.0"),
    run_id:,
    run_attempt:,
    provider: ENV.fetch("PROVIDER", "cursor"),
    model: ENV.fetch("MODEL", "default"),
    started_at: Time.at(start_time).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
  )

  [builder, start_time]
end

case command
when "create"
  builder, = build_status_comment(repo_full)
  result = poster.create_issue_comment(builder.in_progress_body)
  unless result
    warn "[status_comment] Failed to create status comment"
    exit 1
  end

  comment_id = result["id"]
  github_output = ENV["GITHUB_OUTPUT"]
  if github_output && !github_output.empty?
    File.open(github_output, "a") { |f| f.puts "comment_id=#{comment_id}" }
  end
  warn "[status_comment] Created comment #{comment_id}"

when "success"
  comment_id = Integer(ENV.fetch("COMMENT_ID"))
  poster.delete_issue_comment(comment_id)
  warn "[status_comment] Deleted comment #{comment_id} — success"

when "failure"
  builder, start_time = build_status_comment(repo_full)
  comment_id = Integer(ENV.fetch("COMMENT_ID"))
  duration = Time.now.to_i - start_time

  body = builder.failure_body(duration_seconds: duration)
  poster.update_issue_comment(comment_id, body)
  warn "[status_comment] Updated comment #{comment_id} — failure"
end
