#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

require_relative "github_api"
require_relative "review_history"
require_relative "review_scope"

# Reads what the bot already said on the pull request, picks the review's scope, and writes
# both to REVIEW_CONTEXT_PATH for the prompt and posting steps. Runs before the checkout's
# credential is removed, so it can still fetch the last-reviewed commit.

# Earlier comment bodies go into the prompt, so a long-running pull request is capped at its
# most recent threads, each cut short.
MAX_FINDINGS = 100
MAX_FINDING_BODY = 2000
SHA_PATTERN = /\A[0-9a-f]{40}\z/

def commit_present?(sha)
  system("git", "cat-file", "-e", "#{sha}^{commit}", out: File::NULL, err: File::NULL)
end

# The checkout only reaches back to the merge base, so a last-reviewed commit before a merge
# from the base branch may be missing. Fetching it by SHA settles that; if the fetch fails, the
# commit is gone from the branch and the review is a full one.
def ancestor?(sha, head_sha)
  unless commit_present?(sha)
    system("git", "fetch", "--no-tags", "--quiet", "--depth=1", "origin", sha, out: File::NULL, err: File::NULL)
  end

  commit_present?(sha) &&
    system("git", "merge-base", "--is-ancestor", sha, head_sha, out: File::NULL, err: File::NULL)
end

def findings_for_prompt(threads)
  threads.last(MAX_FINDINGS).each_with_index.map do |thread, index|
    body = thread["body"]
    body = "#{body[0, MAX_FINDING_BODY]}…" if body.length > MAX_FINDING_BODY
    thread.merge("key" => "F#{index + 1}", "body" => body)
  end
end

head_sha = ENV.fetch("HEAD_SHA")
raise "HEAD_SHA is not a full commit SHA: #{head_sha.inspect}" unless SHA_PATTERN.match?(head_sha)

owner, repo = ENV.fetch("GITHUB_REPOSITORY").split("/", 2)
history = ReviewHistory.new(
  api: GitHubApi.new(token: ENV.fetch("GITHUB_TOKEN")),
  owner:,
  repo:,
  pr_number: ENV.fetch("PULL_NUMBER"),
  app_slug: ENV.fetch("APP_SLUG")
)

scope = ReviewScope.decide(
  requested: ENV.fetch("REVIEW_SCOPE"),
  event_name: ENV.fetch("EVENT_NAME"),
  last_reviewed_sha: history.last_reviewed_sha,
  head_sha:,
  ancestor: ->(sha) { ancestor?(sha, head_sha) }
)
warn "[plan_review] #{scope.mode}: #{scope.reason}"

findings = scope.skip? ? [] : findings_for_prompt(history.bot_threads)
warn "[plan_review] #{findings.size} earlier finding(s) on the pull request"

File.write(
  ENV.fetch("REVIEW_CONTEXT_PATH"),
  JSON.pretty_generate(
    "mode" => scope.mode,
    "reason" => scope.reason,
    "head_sha" => head_sha,
    "last_reviewed_sha" => scope.last_reviewed_sha,
    "findings" => findings
  )
)

File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
  output.puts "mode=#{scope.mode}"
  output.puts "last_reviewed_sha=#{scope.last_reviewed_sha}"
end
