#!/usr/bin/env ruby

require "json"

class AgentReviewParser
  MAX_INLINE_COMMENTS = 50
  # Bump when changing review posting behavior or summary format.
  REVIEW_POSTER_VERSION = "1.0.0"

  def self.parse_file(path)
    new(File.read(path))
  end

  def initialize(json_string)
    @payload = JSON.parse(json_string)
    validate_root!
    @summary_body = build_summary_body
    @inline_comments = build_inline_comments
  end

  attr_reader :summary_body, :inline_comments

private

  def validate_root!
    raise "Review JSON root must be a JSON object" unless @payload.is_a?(Hash)

    summary = @payload["summary"].to_s.strip
    raise 'Review JSON must include a non-empty "summary" string' if summary.empty?
  end

  def build_summary_body
    summary = @payload["summary"].to_s.strip
    "<!-- agentic-pr-review #{REVIEW_POSTER_VERSION} -->\n\n#{summary}"
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

    {
      "path" => path,
      "body" => format_comment_body(entry["severity"], body),
      "line" => line_i,
      "side" => "RIGHT",
    }
  end

  def limit_inline_comments(comments)
    return comments if comments.size <= MAX_INLINE_COMMENTS

    dropped = comments.size - MAX_INLINE_COMMENTS
    warn "[process_review] #{comments.size} inline comments exceed max (#{MAX_INLINE_COMMENTS}); " \
         "truncating to first #{MAX_INLINE_COMMENTS} (#{dropped} omitted)"
    comments.take(MAX_INLINE_COMMENTS)
  end
end
