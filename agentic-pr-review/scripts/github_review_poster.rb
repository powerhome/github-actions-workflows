#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "github_api"

class GitHubReviewPoster
  RESOLVE_THREAD = <<~GRAPHQL
    mutation($threadId: ID!) {
      resolveReviewThread(input: { threadId: $threadId }) { thread { id isResolved } }
    }
  GRAPHQL

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

  # Replies under the thread's first comment, then resolves it, so the thread says why it
  # closed rather than just collapsing.
  def resolve_thread(thread_id:, comment_id:, body:)
    @api.post("/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/comments/#{comment_id}/replies", { body: })
    @api.graphql(RESOLVE_THREAD, threadId: thread_id)
    true
  rescue GitHubApi::RequestError => e
    log_request_error("Resolving thread #{thread_id} failed", e)
    false
  end

private

  def log_request_error(label, error)
    warn "[process_review] #{label}: #{error.message}"
  end
end
