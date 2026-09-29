#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "github_comment_poster"

begin
  poster = GitHubCommentPoster.new(
    repository: ENV["GITHUB_REPOSITORY"].to_s,
    pr_number: ENV["PR_NUMBER"].to_s
  )
  mode = ENV["COMMENT_MODE"].to_s
  body = ENV["COMMENT_BODY"].to_s
  tag = ENV["COMMENT_TAG"].to_s

  raise "Refusing to post an empty comment" if body.strip.empty? && mode != "delete"

  result =
    case mode
    when "upsert" then poster.upsert(tag:, body:)
    when "create" then poster.create(body:)
    when "delete" then poster.delete(tag:)
    else raise "Unknown comment mode: #{mode.inspect} (expected upsert, create or delete)"
    end

  puts "[agentic_pr_review] #{tag.empty? ? mode : tag}: #{result}"
rescue => e
  warn "Comment operation failed: #{e.message}"
  exit 1
end
