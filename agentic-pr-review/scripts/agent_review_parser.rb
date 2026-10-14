#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

class AgentReviewParser
  MAX_INLINE_COMMENTS = 50
  # Bump when changing review posting behavior or summary format.
  REVIEW_POSTER_VERSION = "1.1.0"
  # Matches every version's marker. head= and seen= arrived in 1.1.0, so an older one has
  # neither. seen= is when the run read the pull request's comments, which comes before the
  # review is posted: a comment left while the agent ran is still new to the next review.
  MARKER_PATTERN = /<!-- agentic-pr-review (\S+?)(?: head=([0-9a-f]{40}))?(?: seen=(\d{4}-\d\d-\d\dT[\d:]{8}Z))? -->/

  # Hidden in the bot's "Addressed in <sha>" reply, so later reviews know the finding was fixed.
  # Hyphenated, so MARKER_PATTERN never takes it for a review summary.
  FIXED_NOTE_MARKER = "<!-- agentic-pr-review-fixed -->"

  # GitHub token formats. The agent can run gh with the job's token, so a review that
  # quotes one, whether misled by the pull request or not, has it blanked before it is posted.
  TOKEN_PATTERN = /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b/

  def self.marker(head_sha, seen_at = nil)
    head = head_sha.to_s.empty? ? "" : " head=#{head_sha}"
    seen = seen_at.to_s.empty? ? "" : " seen=#{seen_at}"
    "<!-- agentic-pr-review #{REVIEW_POSTER_VERSION}#{head}#{seen} -->"
  end

  def self.marker?(body)
    MARKER_PATTERN.match?(body.to_s)
  end

  # The head SHA a review summary records, or nil when it has none.
  def self.reviewed_sha(body)
    MARKER_PATTERN.match(body.to_s)&.[](2)
  end

  # When the run that posted a review summary read the pull request, or nil when it has none.
  def self.seen_at(body)
    MARKER_PATTERN.match(body.to_s)&.[](3)
  end

  def self.parse_file(path, head_sha: nil, seen_at: nil)
    new(File.read(path), head_sha:, seen_at:)
  end

  def self.redact_tokens(text)
    text.gsub(TOKEN_PATTERN, "[redacted token]")
  end

  def initialize(json_string, head_sha: nil, seen_at: nil)
    @head_sha = head_sha
    @seen_at = seen_at
    @payload = JSON.parse(extract_json(self.class.redact_tokens(json_string.to_s)))
    validate_root!
    @summary_body = build_summary_body
    @inline_comments = build_inline_comments
    @fixed_findings = build_fixed_findings
  end

  # An inline comment may carry "regression_of", the key of an earlier finding. ReviewTriage
  # turns it into a link and strips it before the comment is posted.
  attr_reader :summary_body, :inline_comments, :fixed_findings

private

  # Models sometimes emit prose or code fences around the JSON object.
  # Strategy: strip code fences first, then fall back to extracting the
  # substring between the first `{` and last `}` in the output.
  def extract_json(raw)
    stripped = strip_code_fences(raw)
    return stripped if valid_json_object?(stripped)

    first_brace = raw.index("{")
    last_brace = raw.rindex("}")
    if first_brace && last_brace && last_brace > first_brace
      candidate = raw[first_brace..last_brace]
      return candidate if valid_json_object?(candidate)
    end

    stripped
  end

  def strip_code_fences(raw)
    stripped = raw.strip
    stripped = stripped.sub(/\A```\w*\s*\n?/, "").sub(/\n?```\s*\z/, "") if stripped.start_with?("```")
    stripped
  end

  def valid_json_object?(str)
    JSON.parse(str).is_a?(Hash)
  rescue JSON::ParserError
    false
  end

  def validate_root!
    raise "Review JSON root must be a JSON object" unless @payload.is_a?(Hash)

    summary = @payload["summary"].to_s.strip
    raise 'Review JSON must include a non-empty "summary" string' if summary.empty?
  end

  def build_summary_body
    summary = @payload["summary"].to_s.strip
    "#{self.class.marker(@head_sha, @seen_at)}\n\n#{summary}"
  end

  def build_inline_comments
    raw = @payload["comments"]
    raw = [] unless raw.is_a?(Array)
    comments = raw.filter_map { |c| build_inline_comment(c) }
    limit_inline_comments(comments)
  end

  def format_comment_body(severity, body)
    s = severity.to_s.strip
    return body if s.empty?

    "**Severity: #{s}**\n\n#{body}"
  end

  def build_inline_comment(entry)
    return nil unless entry.is_a?(Hash)

    path = entry["path"].to_s.strip
    body = entry["body"].to_s
    line = entry["line"]
    return nil if path.empty? || body.empty?
    return nil if line.nil?

    line_i = Integer(line, exception: false)
    return nil if line_i.nil? || line_i < 1

    comment = {
      "path" => path,
      "body" => format_comment_body(entry["severity"], body),
      "line" => line_i,
      "side" => "RIGHT",
    }
    regression_of = entry["regression_of"].to_s.strip
    comment["regression_of"] = regression_of unless regression_of.empty?
    comment
  end

  def build_fixed_findings
    raw = @payload["fixed_findings"]
    return [] unless raw.is_a?(Array)

    raw.map { |key| key.to_s.strip }.reject(&:empty?).uniq
  end

  def limit_inline_comments(comments)
    return comments if comments.size <= MAX_INLINE_COMMENTS

    dropped = comments.size - MAX_INLINE_COMMENTS
    warn "[process_review] #{comments.size} inline comments exceed max (#{MAX_INLINE_COMMENTS}); " \
         "truncating to first #{MAX_INLINE_COMMENTS} (#{dropped} omitted)"
    comments.take(MAX_INLINE_COMMENTS)
  end
end
