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
    @payload = JSON.parse(extract_json(json_string))
    validate_root!
    @summary_body = build_summary_body
    @inline_comments = build_inline_comments
  end

  attr_reader :summary_body, :inline_comments

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
