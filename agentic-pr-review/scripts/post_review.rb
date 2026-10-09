#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

require_relative "agent_review_parser"
require_relative "diff_lines"
require_relative "github_review_poster"
require_relative "review_triage"

def load_review(path, head_sha)
  AgentReviewParser.parse_file(path, head_sha:)
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

def read_diff(path)
  File.read(path, encoding: Encoding::UTF_8).scrub
end

# In an incremental review a comment may only land on a line pushed since the last review
# that the pull request itself changes; a full review leaves anchoring to the prompt and
# GitHub's own check.
def allowed_lines(context)
  return nil unless context["mode"] == "incremental"

  DiffLines.intersect(
    DiffLines.added(read_diff(ENV.fetch("PR_INCREMENTAL_DIFF_PATH"))),
    DiffLines.added(read_diff(ENV.fetch("PR_DIFF_PATH")))
  )
end

def scope_note(context, resolved_count)
  notes = []
  if context["mode"] == "incremental"
    notes << "Reviewed the commits since `#{context['last_reviewed_sha'][0, 7]}`."
  end
  notes << "Resolving #{resolved_count} earlier finding(s) that look fixed." if resolved_count.positive?
  notes.empty? ? "" : "\n\n---\n\n_#{notes.join(' ')}_"
end

def post_review(poster, summary_body, inline_comments)
  if poster.post_batch_review(summary_body, inline_comments)
    warn "[process_review] Posted batch review"
    return true
  end

  unless poster.post_summary_only(summary_body)
    warn "[process_review] Failed to post review summary"
    return false
  end

  warn "[process_review] Posted summary review; posting #{inline_comments.size} inline comment(s)"

  inline_comments.each_with_index do |c, i|
    label = "Inline comment #{i + 1} failed"
    warn "[process_review] Inline comment #{i + 1}: OK" if poster.post_single_comment(c, failure_label: label)
  end
  true
end

review_path = ENV["REVIEW_JSON_PATH"] || File.join(Dir.pwd, "review-agent.json")

unless File.file?(review_path)
  warn "Review JSON not found at #{review_path}"
  exit 1
end

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

parsed = load_review(review_path, commit_sha)
context = JSON.parse(File.read(ENV.fetch("REVIEW_CONTEXT_PATH"), encoding: Encoding::UTF_8))

triage = ReviewTriage.new(
  comments: parsed.inline_comments,
  resolved_keys: parsed.resolved_findings,
  findings: Array(context["findings"]),
  allowed_lines: allowed_lines(context)
)

poster = GitHubReviewPoster.new(
  owner:,
  repo:,
  pr_number: Integer(pr_number),
  commit_sha:,
  token:
)

summary_body = parsed.summary_body + scope_note(context, triage.threads_to_resolve.size)
exit 1 unless post_review(poster, summary_body, triage.comments)

# After the review, so a run that failed to post leaves every thread as it found it.
triage.threads_to_resolve.each do |finding|
  resolved = poster.resolve_thread(
    thread_id: finding["thread_id"],
    comment_id: finding["comment_id"],
    body: "This looks addressed as of #{commit_sha[0, 7]}, so the agentic review is resolving it."
  )
  warn "[process_review] Resolved #{finding['key']} (#{finding['path']})" if resolved
end

exit 0
