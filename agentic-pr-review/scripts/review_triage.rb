#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks the agent's output against what the bot already said, so the prompt's rules hold
# even when the agent ignores them:
#
# - in an incremental review, a comment off the lines pushed since the last review is dropped
# - a comment on the same line as one of the bot's open threads is dropped as a repeat
# - a comment marked as a regression of a thread the bot resolved links back to that thread
# - only the bot's own open threads can be resolved
class ReviewTriage
  attr_reader :comments, :threads_to_resolve

  # findings: the context file's "findings", keyed F1, F2, ...
  # allowed_lines: path => Set of lines comments may anchor to, or nil for no restriction
  def initialize(comments:, resolved_keys:, findings:, allowed_lines: nil)
    @findings = findings.to_h { |finding| [finding["key"], finding] }
    @allowed_lines = allowed_lines
    @threads_to_resolve = resolved_keys.filter_map { |key| @findings[key] }
                                       .select { |finding| finding["status"] == "open" }
                                       .uniq { |finding| finding["thread_id"] }
    @comments = comments.filter_map { |comment| triage(comment) }
  end

private

  def triage(comment)
    comment = comment.dup
    regressed = @findings[comment.delete("regression_of")]
    regressed = nil unless regressed && regressed["status"] == "resolved"
    where = "#{comment['path']}:#{comment['line']}"

    if @allowed_lines && !@allowed_lines.fetch(comment["path"], []).include?(comment["line"])
      warn "[process_review] Dropping comment on #{where}: not on a line changed since the last review"
      return nil
    end

    if regressed
      comment["body"] = "#{comment['body']}\n\n" \
                        "This was raised in [an earlier thread](#{regressed['url']}) and fixed, but it has come back."
    elsif (open = open_finding_at(comment["path"], comment["line"]))
      warn "[process_review] Dropping comment on #{where}: repeats #{open['key']}, which is still open"
      return nil
    end

    comment
  end

  # A thread about to be resolved does not count: a new issue on its line is a new finding.
  def open_finding_at(path, line)
    @findings.each_value.find do |finding|
      finding["status"] == "open" && finding["path"] == path && finding["line"] == line &&
        !@threads_to_resolve.include?(finding)
    end
  end
end
