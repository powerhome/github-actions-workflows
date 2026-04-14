#!/usr/bin/env ruby

require "json"
require "net/http"
require "uri"

class GitHubReviewPoster
  def initialize(owner:, repo:, pr_number:, commit_sha:, token:)
    @owner = owner
    @repo = repo
    @pr_number = pr_number
    @commit_sha = commit_sha
    @token = token
  end

  def post_batch_review(summary_body, inline_comments)
    post(
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews",
      {
        commit_id: @commit_sha,
        body: summary_body,
        event: "COMMENT",
        comments: inline_comments,
      }
    )
    true
  rescue RequestError => e
    log_request_error("Batch review failed", e)
    false
  end

  def post_summary_only(summary_body)
    post(
      "/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews",
      {
        commit_id: @commit_sha,
        body: summary_body,
        event: "COMMENT",
      }
    )
    true
  rescue RequestError => e
    log_request_error("Summary review failed", e)
    false
  end

  def post_single_comment(comment, failure_label: "Inline comment failed")
    post(
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

private

  class RequestError < StandardError; end

  def api_endpoint
    base = ENV.fetch("GITHUB_API_URL", "https://api.github.com").chomp("/")
    URI("#{base}/")
  end

  def post(path, payload)
    uri = api_endpoint + path.delete_prefix("/")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Accept"] = "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "nitro-agentic-pr-review"
    request.content_type = "application/json"
    request.body = JSON.dump(payload)

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
