#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "github_api"

class GitHubReviewPoster
  def initialize(owner:, repo:, pr_number:, commit_sha:, token:)
    @owner = owner
    @repo = repo
    @pr_number = pr_number
    @commit_sha = commit_sha
    @api = GitHubApi.new(token:)
  end

  def post_batch_review(summary_body, inline_comments)
    @api.post(
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews",
      {
        commit_id: @commit_sha,
        body: summary_body,
        event: "COMMENT",
        comments: inline_comments,
      }
    )
    true
  rescue GitHubApi::RequestError => e
    log_request_error("Batch review failed", e)
    false
  end

  def post_summary_only(summary_body)
    @api.post(
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews",
      {
        commit_id: @commit_sha,
        body: summary_body,
        event: "COMMENT",
      }
    )
    true
  rescue GitHubApi::RequestError => e
    log_request_error("Summary review failed", e)
    false
  end

  def post_single_comment(comment, failure_label: "Inline comment failed")
    @api.post(
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/comments",
      {
        body: comment["body"],
        commit_id: @commit_sha,
        path: comment["path"],
        line: comment["line"],
        side: comment["side"] || "RIGHT",
      }
    )
    true
  rescue GitHubApi::RequestError => e
    log_request_error(failure_label, e)
    false
  end

  # Replies under a thread's first comment. The bot never resolves threads: GitHub only
  # lets an App do that with Contents write, which is more access than a reviewer needs.
  def reply_to_thread(comment_id:, body:)
    @api.post("/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/comments/#{comment_id}/replies", { body: })
    true
  rescue GitHubApi::RequestError => e
    log_request_error("Reply to comment #{comment_id} failed", e)
    false
  end

private

  def log_request_error(label, error)
    warn "[process_review] #{label}: #{error.message}"
  end
end
