#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "agent_review_parser"
require_relative "github_api"

# What the bot has already said on a pull request: the head SHA its latest review covered,
# and the inline comment threads it opened. Everything comes from the pull request itself,
# so nothing is stored anywhere else between runs.
class ReviewHistory
  THREADS_QUERY = <<~GRAPHQL
    query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              path
              line
              resolvedBy { __typename login }
              comments(first: 1) {
                nodes { databaseId url body author { __typename login } }
              }
            }
          }
        }
      }
    }
  GRAPHQL

  def initialize(api:, owner:, repo:, pr_number:, app_slug:)
    @api = api
    @owner = owner
    @repo = repo
    @pr_number = Integer(pr_number)
    @app_slug = app_slug.to_s
    raise "An app slug is required to tell the bot's reviews apart" if @app_slug.empty?
  end

  # Only the bot's own reviews count: anyone can paste a marker into a review of their own,
  # and one naming the current head would otherwise switch the next review off.
  #
  # The latest summary decides, so one posted before head= existed means a full review even
  # if an older one recorded a SHA. Reviews with an empty body are the fallback path's
  # standalone inline comments, and carry no marker.
  def last_reviewed_sha
    latest = bot_reviews.select { |review| AgentReviewParser.marker?(review["body"]) }.last
    latest && AgentReviewParser.reviewed_sha(latest["body"])
  end

  # The threads the bot opened, oldest first, each as:
  #   "status"  -- "open"; "resolved" when the bot itself resolved it, so its fix is known;
  #                or "dismissed" when someone else did, which may mean "won't fix"
  #   "line"    -- the thread's line on the current head, or nil once that code has changed
  def bot_threads
    @bot_threads ||= review_threads.filter_map do |thread|
      root = thread.dig("comments", "nodes", 0)
      next unless root && bot?(root["author"])

      {
        "thread_id" => thread["id"],
        "comment_id" => root["databaseId"],
        "url" => root["url"],
        "status" => thread_status(thread),
        "path" => thread["path"],
        "line" => thread["line"],
        "body" => root["body"].to_s,
      }
    end
  end

private

  def bot_reviews
    @api.get_all("/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews")
        .select { |review| bot?(review["user"]) }
        .sort_by { |review| review["submitted_at"].to_s }
  end

  def review_threads
    threads = []
    cursor = nil

    1.upto(GitHubApi::MAX_PAGES) do
      data = @api.graphql(THREADS_QUERY, owner: @owner, repo: @repo, number: @pr_number, cursor:)
      page = data.dig("repository", "pullRequest", "reviewThreads") || {}
      threads.concat(Array(page["nodes"]))
      break unless page.dig("pageInfo", "hasNextPage")

      cursor = page.dig("pageInfo", "endCursor")
    end

    threads
  end

  def thread_status(thread)
    return "open" unless thread["isResolved"]

    bot?(thread["resolvedBy"]) ? "resolved" : "dismissed"
  end

  # REST spells an app's login "slug[bot]" with type "Bot"; GraphQL spells it "slug" with
  # __typename "Bot". The type check keeps a user who happens to share the slug out.
  def bot?(actor)
    return false unless actor.is_a?(Hash)

    type = actor["type"] || actor["__typename"]
    type == "Bot" && actor["login"].to_s.delete_suffix("[bot]") == @app_slug
  end
end
