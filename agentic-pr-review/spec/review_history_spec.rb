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
    def thread(id, author:, resolved: false, line: 5, replies: [], at: "2026-10-01T00:00:00Z")
      {
        "id" => id,
        "isResolved" => resolved,
        "path" => "a.rb",
        "line" => line,
        "comments" => {
          "nodes" => [{ "databaseId" => 100, "url" => "https://github.test/#{id}", "body" => "Body #{id}",
                        "author" => author, "createdAt" => at, }] +
            replies.map do |who, body, reply_at = at|
              { "databaseId" => 101, "body" => body, "author" => who, "createdAt" => reply_at }
            end,
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
    let(:fixed_note) { "#{AgentReviewParser::FIXED_NOTE_MARKER}\nAddressed in abc." }

    it "does not take a person's reply quoting the fixed note for the bot's" do
      allow(api).to receive(:graphql).and_return(page([thread("T1", author: gql_bot,
                                                                    replies: [[gql_human, fixed_note]])]))

      expect(history.bot_threads.first["status"]).to eq("open")
    end

    it "returns the bot's threads across pages, with a status for each" do
      allow(api).to receive(:graphql)
        .with(described_class::THREADS_QUERY, hash_including(cursor: nil))
        .and_return(page([thread("T1", author: gql_bot), thread("T2", author: gql_human)], next_cursor: "c1"))
      allow(api).to receive(:graphql)
        .with(described_class::THREADS_QUERY, hash_including(cursor: "c1"))
        .and_return(page([
                           thread("T3", author: gql_bot, line: nil, replies: [[gql_bot, fixed_note]]),
                           thread("T4", author: gql_bot, resolved: true),
                           thread("T5", author: gql_bot, resolved: true, replies: [[gql_bot, fixed_note]]),
                         ]))

      threads = history.bot_threads

      expect(threads.map { |t| [t["thread_id"], t["status"], t["line"]] }).to eq(
        [["T1", "open", 5], ["T3", "fixed", nil], ["T4", "dismissed", 5], ["T5", "fixed", 5]]
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
        thread("T1", author: gql_bot, replies: [[gql_human, "Intentional"], [gql_bot, "Addressed in abc"], [nil, "Old"]])
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

  describe "#people_threads with since" do
    before do
      allow(api).to receive(:graphql).and_return(
        "repository" => { "pullRequest" => { "reviewThreads" => {
          "pageInfo" => { "hasNextPage" => false },
          "nodes" => [
            thread_node("Quiet", [["octocat", "2026-10-01T00:00:00Z"]]),
            thread_node("Replied", [["octocat", "2026-10-01T00:00:00Z"], ["hubot", "2026-10-05T00:00:00Z"]]),
            thread_node("Bot only since", [["octocat", "2026-10-01T00:00:00Z"]],
                        bot_reply_at: "2026-10-06T00:00:00Z"),
          ],
        }, }, }
      )
    end

    def thread_node(body, comments, bot_reply_at: nil)
      nodes = comments.map do |login, at|
        { "body" => body, "createdAt" => at, "author" => { "__typename" => "User", "login" => login } }
      end
      if bot_reply_at
        nodes << { "body" => "bot", "createdAt" => bot_reply_at,
                   "author" => { "__typename" => "Bot", "login" => "nitro-review" }, }
      end
      { "id" => body, "isResolved" => false, "path" => "a.rb", "line" => 1, "comments" => { "nodes" => nodes } }
    end

    it "keeps only threads a person commented in since, in full" do
      threads = history.people_threads(since: "2026-10-03T00:00:00Z")

      expect(threads.size).to eq(1)
      expect(threads.first["comments"].map { |c| c["author"] }).to eq(%w[octocat hubot])
    end

    it "keeps every thread without since" do
      expect(history.people_threads.size).to eq(3)
    end
  end

  describe "#last_review_url" do
    it "links the latest summary" do
      stub_reviews(
        review(bot, "<!-- agentic-pr-review 1.1.0 head=#{old_sha} -->", "2026-10-01T00:00:00Z")
          .merge("html_url" => "https://github.test/r/1"),
        review(bot, "<!-- agentic-pr-review 1.1.0 head=#{new_sha} -->", "2026-10-02T00:00:00Z")
          .merge("html_url" => "https://github.test/r/2")
      )

      expect(history.last_review_url).to eq("https://github.test/r/2")
    end

    it "is nil with no earlier review" do
      stub_reviews

      expect(history.last_review_url).to be_nil
    end
  end

  describe "#last_seen_at" do
    it "reads seen= from the latest summary" do
      stub_reviews(review(bot, "<!-- agentic-pr-review 1.1.0 head=#{new_sha} seen=2026-10-02T09:00:00Z -->",
                          "2026-10-02T10:00:00Z"))

      expect(history.last_seen_at).to eq("2026-10-02T09:00:00Z")
    end

    it "falls back to when the summary was posted" do
      stub_reviews(review(bot, "<!-- agentic-pr-review 1.1.0 head=#{new_sha} -->", "2026-10-02T10:00:00Z"))

      expect(history.last_seen_at).to eq("2026-10-02T10:00:00Z")
    end

    it "is nil with no earlier review" do
      stub_reviews

      expect(history.last_seen_at).to be_nil
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

    it "keeps only comments left after since" do
      allow(api).to receive(:get_all).with("/repos/acme/widgets/issues/42/comments").and_return(
        [
          { "user" => human, "body" => "Old", "created_at" => "2026-10-01T00:00:00Z" },
          { "user" => human, "body" => "New", "created_at" => "2026-10-05T00:00:00Z" },
        ]
      )

      expect(history.people_comments_on_pull_request(since: "2026-10-03T00:00:00Z").map { |c| c["body"] })
        .to eq(["New"])
    end
  end

  it "requires an app slug" do
    expect do
      described_class.new(api:, owner: "acme", repo: "widgets", pr_number: 42, app_slug: "")
    end.to raise_error(RuntimeError, /app slug/)
  end
end
