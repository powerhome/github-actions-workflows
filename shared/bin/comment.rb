#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/pull_request_comments"

# Drives one comment operation from the environment, so the action's steps stay
# declarative and no comment body reaches a command line.
def comment_body
  path = ENV["COMMENT_BODY_PATH"].to_s
  inline = ENV["COMMENT_BODY"].to_s

  # Exactly one, so neither an unset body nor a conflicting pair passes silently.
  if path.empty? == inline.empty?
    raise "Set exactly one of COMMENT_BODY_PATH or COMMENT_BODY"
  end

  body = path.empty? ? inline : File.read(path, encoding: Encoding::UTF_8)
  raise "Refusing to post an empty comment" if body.strip.empty?

  body
end

def comment_tag
  tag = ENV["COMMENT_TAG"].to_s
  raise "COMMENT_TAG is required to #{ENV.fetch("COMMENT_MODE")} a comment" if tag.empty?

  tag
end

begin
  comments = PullRequestComments.new(
    repository: ENV.fetch("GITHUB_REPOSITORY"),
    pull_request_number: ENV.fetch("PR_NUMBER")
  )
  mode = ENV.fetch("COMMENT_MODE")

  result =
    case mode
    when "upsert" then comments.upsert(tag: comment_tag, body: comment_body)
    when "create" then comments.create(body: comment_body)
    when "delete" then comments.delete(tag: comment_tag)
    else raise "Unknown comment mode: #{mode.inspect} (expected upsert, create or delete)"
    end

  label = ENV["COMMENT_TAG"].to_s
  puts "[comment] #{label.empty? ? mode : label}: #{result}"
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
