#!/usr/bin/env ruby

require_relative "agent_review_parser"
require_relative "github_review_poster"

def load_review(path)
  AgentReviewParser.parse_file(path)
rescue JSON::ParserError => e
  warn "Failed to parse review JSON: #{e.message}"
  exit 1
rescue Errno::ENOENT => e
  warn "Review JSON not found: #{e.message}"
  exit 1
rescue => e
  warn e.message
  exit 1
end

review_path = ENV["REVIEW_JSON_PATH"] || File.join(Dir.pwd, "review-agent.json")

unless File.file?(review_path)
  warn "Review JSON not found at #{review_path}"
  exit 1
end

parsed = load_review(review_path)

repo_full = ENV["GITHUB_REPOSITORY"].to_s
owner, repo = repo_full.split("/", 2)
pr_number = ENV["PULL_NUMBER"].to_s
token = ENV["GITHUB_TOKEN"].to_s
commit_sha = ENV["COMMIT_SHA"].to_s

env_var_errors = []
env_var_errors << "GITHUB_REPOSITORY" if repo_full.empty? || owner.to_s.empty? || repo.to_s.empty?
env_var_errors << "PULL_NUMBER" if pr_number.empty?
env_var_errors << "GITHUB_TOKEN" if token.empty?
env_var_errors << "COMMIT_SHA" if commit_sha.empty?

raise "Missing required env vars: #{env_var_errors.join(', ')}" unless env_var_errors.empty?

poster = GitHubReviewPoster.new(
  owner:,
  repo:,
  pr_number: Integer(pr_number),
  commit_sha:,
  token:
)

if poster.post_batch_review(parsed.summary_body, parsed.inline_comments)
  warn "[process_review] Posted batch review"
  exit 0
end

exit 1 unless poster.post_summary_only(parsed.summary_body)

warn "[process_review] Posted summary review; posting #{parsed.inline_comments.size} inline comment(s)"

parsed.inline_comments.each_with_index do |c, i|
  label = "Inline comment #{i + 1} failed"
  warn "[process_review] Inline comment #{i + 1}: OK" if poster.post_single_comment(c, failure_label: label)
end

exit 0
