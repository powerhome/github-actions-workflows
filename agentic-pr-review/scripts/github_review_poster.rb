#!/usr/bin/env ruby

require "json"
require "net/http"
require "uri"

class GitHubReviewPoster
  def initialize(owner:, repo:, pr_number:, token:, commit_sha: nil)
    @owner = owner
    @repo = repo
    @pr_number = pr_number
    @commit_sha = commit_sha
    @token = token
  end

  def post_batch_review(summary_body, inline_comments)
    api_request(
      :post,
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews",
      {
        commit_id: @commit_sha,
        body: summary_body,
        event: "COMMENT",
        comments: inline_comments,
      }
    )
  rescue RequestError => e
    log_request_error("Batch review failed", e)
    false
  end

  def post_summary_only(summary_body)
    api_request(
      :post,
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews",
      {
        commit_id: @commit_sha,
        body: summary_body,
        event: "COMMENT",
      }
    )
  rescue RequestError => e
    log_request_error("Summary review failed", e)
    false
  end

  def post_single_comment(comment, failure_label: "Inline comment failed")
    api_request(
      :post,
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
  rescue RequestError => e
    log_request_error(failure_label, e)
    false
  end

  def create_issue_comment(body)
    api_request(
      :post,
      "/repos/#{@owner}/#{@repo}/issues/#{@pr_number}/comments",
      { body: body }
    )
  rescue RequestError => e
    log_request_error("Create issue comment failed", e)
    false
  end

  def update_issue_comment(comment_id, body)
    api_request(
      :patch,
      "/repos/#{@owner}/#{@repo}/issues/comments/#{comment_id}",
      { body: body }
    )
  rescue RequestError => e
    log_request_error("Update issue comment failed", e)
    false
  end

  def delete_issue_comment(comment_id)
    api_request(
      :delete,
      "/repos/#{@owner}/#{@repo}/issues/comments/#{comment_id}"
    )
    true
  rescue RequestError => e
    log_request_error("Delete issue comment failed", e)
    false
  end

private

  class RequestError < StandardError; end

  HTTP_METHODS = {
    post: Net::HTTP::Post,
    patch: Net::HTTP::Patch,
    delete: Net::HTTP::Delete,
  }.freeze

  def api_endpoint
    base = ENV.fetch("GITHUB_API_URL", "https://api.github.com").chomp("/")
    URI("#{base}/")
  end

  def api_request(method, path, payload = nil)
    uri = api_endpoint + path.delete_prefix("/")
    klass = HTTP_METHODS.fetch(method) { raise ArgumentError, "Unsupported HTTP method: #{method}" }
    request = klass.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "nitro-agentic-pr-review"
    if payload
      request.content_type = "application/json"
      request.body = JSON.dump(payload)
    end

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    return parse_response(response) if response.is_a?(Net::HTTPSuccess)

    raise RequestError, format_error(response)
  end

  def parse_response(response)
    return if response.body.to_s.empty?

    JSON.parse(response.body)
  rescue JSON::ParserError
    response.body
  end

  def format_error(response)
    payload = parse_response(response)
    message =
      if payload.is_a?(Hash)
        details = Array(payload["errors"]).map(&:inspect)
        [payload["message"], *details].compact.join(" | ")
      else
        payload.to_s
      end

    "HTTP #{response.code}: #{message}"
  end

  def log_request_error(label, error)
    warn "[process_review] #{label}: #{error.message}"
  end
end
