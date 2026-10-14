#!/usr/bin/env ruby
# frozen_string_literal: true

require "time"

require_relative "agent_review_parser"
require_relative "github_api"

# What has already been said on a pull request: the head SHA the bot's latest review covered,
# the inline threads it opened and the replies to them, and what people said elsewhere on it.
# Everything comes from the pull request itself, so nothing is stored anywhere else between runs.
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
              comments(first: 50) {
                nodes { databaseId url body createdAt author { __typename login } }
              }
            }
          }
        }
      }
    }
  GRAPHQL

  # Comment bodies go into the prompt, so each is cut short, and a long thread keeps its
  # latest replies.
  MAX_BODY = 2000
  MAX_REPLIES = 20

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
    last_review && AgentReviewParser.reviewed_sha(last_review["body"])
  end

  # A link to the latest summary, for a notice that points back to it.
  def last_review_url
    last_review&.fetch("html_url", nil)
  end

  # When the run behind the latest summary read the pull request. A summary without seen=
  # falls back to when it was posted, which misses comments left while that run's agent ran.
  def last_seen_at
    return nil unless last_review

    AgentReviewParser.seen_at(last_review["body"]) || last_review["submitted_at"]
  end

  # The threads the bot opened, oldest first, each as:
  #   "status"  -- "fixed" once the bot has replied that it looks addressed, whether or not
  #                someone then resolved it; otherwise "open", or "dismissed" when someone
  #                resolved it without a fix, which may mean "won't fix"
  #   "line"    -- the thread's line on the current head, or nil once that code has changed
  #   "replies" -- what people answered, e.g. "this is intentional"; the bot's own are left out
  def bot_threads
    @bot_threads ||= review_threads.filter_map do |thread|
      root, *replies = thread_comments(thread)
      next unless root && bot?(root["author"])

      {
        "thread_id" => thread["id"],
        "comment_id" => root["databaseId"],
        "url" => root["url"],
        "status" => thread_status(thread, replies),
        "path" => thread["path"],
        "line" => thread["line"],
        "body" => excerpt(root["body"]),
        "replies" => people_comments(replies).last(MAX_REPLIES),
      }
    end
  end

  # Inline threads a person started, oldest first, with what people said in each. Other
  # bots' threads are left out: they are tooling output, not review discussion. With since,
  # only threads someone has commented in after that time, each still in full.
  def people_threads(since: nil)
    review_threads.filter_map do |thread|
      root, = thread_comments(thread)
      next unless root && person?(root["author"])
      next unless people_comments_raw(thread_comments(thread)).any? { |c| after?(c["createdAt"], since) }

      {
        "status" => thread["isResolved"] ? "resolved" : "open",
        "path" => thread["path"],
        "line" => thread["line"],
        "comments" => people_comments(thread_comments(thread)).last(MAX_REPLIES),
      }
    end
  end

  # General comments on the pull request from people, oldest first. The bot's status and
  # failure comments, and other bots' comments, are left out. With since, only those left
  # after that time.
  def people_comments_on_pull_request(since: nil)
    people_comments(
      @api.get_all("/repos/#{@owner}/#{@repo}/issues/#{@pr_number}/comments")
          .select { |comment| after?(comment["created_at"], since) }
          .map { |comment| { "author" => comment["user"], "body" => comment["body"] } }
    )
  end

private

  def thread_comments(thread)
    Array(thread.dig("comments", "nodes"))
  end

  def people_comments_raw(comments)
    comments.select { |comment| person?(comment["author"]) }
  end

  def people_comments(comments)
    people_comments_raw(comments).map do |comment|
      { "author" => comment.dig("author", "login") || "ghost", "body" => excerpt(comment["body"]) }
    end
  end

  def excerpt(body)
    body = body.to_s
    body.length > MAX_BODY ? "#{body[0, MAX_BODY]}…" : body
  end

  # A timestamp that will not parse counts as new, so the comment is kept.
  def after?(timestamp, since)
    return true if since.nil?

    Time.iso8601(timestamp.to_s) > Time.iso8601(since.to_s)
  rescue ArgumentError
    true
  end

  def last_review
    @last_review ||= bot_reviews.select { |review| AgentReviewParser.marker?(review["body"]) }.last
  end

  def bot_reviews
    @api.get_all("/repos/#{@owner}/#{@repo}/pulls/#{@pr_number}/reviews")
        .select { |review| bot?(review["user"]) }
        .sort_by { |review| review["submitted_at"].to_s }
  end

  def review_threads
    @review_threads ||= fetch_review_threads
  end

  def fetch_review_threads
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

  def thread_status(thread, replies)
    fixed = replies.any? do |reply|
      bot?(reply["author"]) && reply["body"].to_s.include?(AgentReviewParser::FIXED_NOTE_MARKER)
    end
    return "fixed" if fixed

    thread["isResolved"] ? "dismissed" : "open"
  end

  # REST spells an app's login "slug[bot]" with type "Bot"; GraphQL spells it "slug" with
  # __typename "Bot". The type check keeps a user who happens to share the slug out.
  def bot?(actor)
    return false unless actor.is_a?(Hash)

    type = actor["type"] || actor["__typename"]
    type == "Bot" && actor["login"].to_s.delete_suffix("[bot]") == @app_slug
  end

  # A deleted account comes back as a null author, which is still a person.
  def person?(actor)
    actor.nil? || (actor["type"] || actor["__typename"]) != "Bot"
  end
end
