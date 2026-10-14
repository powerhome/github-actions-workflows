# frozen_string_literal: true

require_relative "spec_helper"

require "review_history"

RSpec.describe ReviewHistory do
  let(:api) { instance_double(GitHubApi) }
  let(:bot) { { "login" => "nitro-review[bot]", "type" => "Bot" } }
  let(:human) { { "login" => "octocat", "type" => "User" } }
  let(:old_sha) { "a" * 40 }
  let(:new_sha) { "b" * 40 }

  subject(:history) do
    described_class.new(api:, owner: "acme", repo: "widgets", pr_number: 42, app_slug: "nitro-review")
  end

  def review(user, body, submitted_at)
    { "user" => user, "body" => body, "submitted_at" => submitted_at }
  end

  def stub_reviews(*reviews)
    allow(api).to receive(:get_all).with("/repos/acme/widgets/pulls/42/reviews").and_return(reviews)
  end

  describe "#last_reviewed_sha" do
    it "is the SHA in the bot's latest summary" do
      stub_reviews(
        review(bot, "<!-- agentic-pr-review 1.1.0 head=#{new_sha} -->\n\nNew", "2026-10-02T00:00:00Z"),
        review(bot, "<!-- agentic-pr-review 1.1.0 head=#{old_sha} -->\n\nOld", "2026-10-01T00:00:00Z"),
        review(bot, "", "2026-10-03T00:00:00Z")
      )

      expect(history.last_reviewed_sha).to eq(new_sha)
    end

    it "ignores a marker someone else posted" do
      stub_reviews(
        review(bot, "<!-- agentic-pr-review 1.1.0 head=#{old_sha} -->", "2026-10-01T00:00:00Z"),
        review(human, "<!-- agentic-pr-review 1.1.0 head=#{new_sha} -->", "2026-10-02T00:00:00Z"),
        review({ "login" => "nitro-review", "type" => "User" }, "<!-- agentic-pr-review 1.1.0 head=#{new_sha} -->",
               "2026-10-03T00:00:00Z")
      )

      expect(history.last_reviewed_sha).to eq(old_sha)
    end

    it "is nil when the latest summary predates head=" do
      stub_reviews(
        review(bot, "<!-- agentic-pr-review 1.1.0 head=#{old_sha} -->", "2026-10-01T00:00:00Z"),
        review(bot, "<!-- agentic-pr-review 1.0.0 -->\n\nLegacy", "2026-10-02T00:00:00Z")
      )

      expect(history.last_reviewed_sha).to be_nil
    end

    it "is nil with no bot review" do
      stub_reviews

      expect(history.last_reviewed_sha).to be_nil
    end
  end

  describe "review threads" do
    def thread(id, author:, resolved: false, resolved_by: nil, line: 5, replies: [])
      {
        "id" => id,
        "isResolved" => resolved,
        "path" => "a.rb",
        "line" => line,
        "resolvedBy" => resolved_by,
        "comments" => {
          "nodes" => [{ "databaseId" => 100, "url" => "https://github.test/#{id}", "body" => "Body #{id}",
                        "author" => author, }] +
            replies.map { |who, body| { "databaseId" => 101, "body" => body, "author" => who } },
        },
      }
    end

    def page(nodes, next_cursor: nil)
      {
        "repository" => {
          "pullRequest" => {
            "reviewThreads" => {
              "pageInfo" => { "hasNextPage" => !next_cursor.nil?, "endCursor" => next_cursor },
              "nodes" => nodes,
            },
          },
        },
      }
    end

    let(:gql_bot) { { "__typename" => "Bot", "login" => "nitro-review" } }
    let(:gql_human) { { "__typename" => "User", "login" => "octocat" } }

    it "returns the bot's threads across pages, with a status for each" do
      allow(api).to receive(:graphql)
        .with(described_class::THREADS_QUERY, hash_including(cursor: nil))
        .and_return(page([thread("T1", author: gql_bot), thread("T2", author: gql_human)], next_cursor: "c1"))
      allow(api).to receive(:graphql)
        .with(described_class::THREADS_QUERY, hash_including(cursor: "c1"))
        .and_return(page([
                           thread("T3", author: gql_bot, resolved: true, resolved_by: gql_bot, line: nil),
                           thread("T4", author: gql_bot, resolved: true, resolved_by: gql_human),
                         ]))

      threads = history.bot_threads

      expect(threads.map { |t| [t["thread_id"], t["status"], t["line"]] }).to eq(
        [["T1", "open", 5], ["T3", "resolved", nil], ["T4", "dismissed", 5]]
      )
      expect(threads.first).to include("comment_id" => 100, "url" => "https://github.test/T1", "body" => "Body T1",
                                       "path" => "a.rb", "replies" => [])
    end

    def stub_threads(*nodes)
      allow(api).to receive(:graphql).with(described_class::THREADS_QUERY, anything).and_return(page(nodes))
    end

    let(:gql_other_bot) { { "__typename" => "Bot", "login" => "dependabot" } }

    it "keeps people's replies to the bot's threads, but not the bot's own" do
      stub_threads(
        thread("T1", author: gql_bot, replies: [[gql_human, "Intentional"], [gql_bot, "Looks addressed"], [nil, "Old"]])
      )

      expect(history.bot_threads.first["replies"]).to eq(
        [{ "author" => "octocat", "body" => "Intentional" }, { "author" => "ghost", "body" => "Old" }]
      )
    end

    it "cuts long bodies short" do
      stub_threads(thread("T1", author: gql_bot, replies: [[gql_human, "x" * (described_class::MAX_BODY + 10)]]))

      reply = history.bot_threads.first["replies"].first["body"]
      expect(reply.length).to eq(described_class::MAX_BODY + 1)
      expect(reply).to end_with("…")
    end

    it "returns the threads people started, without other bots' threads or comments" do
      stub_threads(
        thread("T1", author: gql_bot),
        thread("T2", author: gql_human, resolved: true, replies: [[gql_other_bot, "CI"], [gql_human, "Fixed"]]),
        thread("T3", author: gql_other_bot)
      )

      expect(history.people_threads).to eq(
        [{
          "status" => "resolved", "path" => "a.rb", "line" => 5,
          "comments" => [{ "author" => "octocat", "body" => "Body T2" }, { "author" => "octocat", "body" => "Fixed" }],
        }]
      )
    end
  end

  describe "#people_comments_on_pull_request" do
    it "returns general comments from people only" do
      allow(api).to receive(:get_all).with("/repos/acme/widgets/issues/42/comments").and_return(
        [
          { "user" => human, "body" => "Why this approach?" },
          { "user" => bot, "body" => "in progress" },
          { "user" => { "login" => "dependabot[bot]", "type" => "Bot" }, "body" => "Bump" },
        ]
      )

      expect(history.people_comments_on_pull_request).to eq([{ "author" => "octocat", "body" => "Why this approach?" }])
    end
  end

  it "requires an app slug" do
    expect do
      described_class.new(api:, owner: "acme", repo: "widgets", pr_number: 42, app_slug: "")
    end.to raise_error(RuntimeError, /app slug/)
  end
end
