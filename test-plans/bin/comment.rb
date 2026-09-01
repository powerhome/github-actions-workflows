#!/usr/bin/env ruby

require_relative "../lib/test_plan/pull_request/comments"

# Drives one comment operation from the environment, so the action's steps stay
# declarative and no comment body reaches a command line.
begin
  comments = TestPlan::PullRequest::Comments.new(
    repository: ENV.fetch("GITHUB_REPOSITORY"),
    pull_request_number: ENV.fetch("PR_NUMBER")
  )
  mode = ENV.fetch("COMMENT_MODE")
  tag = ENV.fetch("COMMENT_TAG")

  result =
    case mode
    when "upsert"
      path = ENV["COMMENT_BODY_PATH"].to_s
      inline = ENV["COMMENT_BODY"].to_s

      # Exactly one, so neither an unset body nor a conflicting pair passes silently.
      if path.empty? == inline.empty?
        raise "Set exactly one of COMMENT_BODY_PATH or COMMENT_BODY for an upsert"
      end

      body = path.empty? ? inline : File.read(path, encoding: Encoding::UTF_8)
      raise "Refusing to post an empty comment" if body.strip.empty?

      comments.upsert(tag: tag, body: body)
    when "delete"
      comments.delete(tag: tag)
    else
      raise "Unknown comment mode: #{mode.inspect} (expected upsert or delete)"
    end

  puts "[test_plan] #{tag}: #{result}"
rescue Errno::ENOENT => e
  warn "Comment body could not be read: #{e.message}"
  exit 1
rescue KeyError => e
  warn "Missing required environment variable: #{e.message}"
  exit 1
rescue => e
  warn "Comment operation failed: #{e.message}"
  exit 1
end
