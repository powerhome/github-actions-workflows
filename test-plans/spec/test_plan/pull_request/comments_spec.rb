require_relative "../../spec_helper"
require "test_plan/pull_request/comments"

require "json"

RSpec.describe TestPlan::PullRequest::Comments do
  # Stands in for gh: records the calls and answers listings from a fixed set of comments.
  class FakeGh
    attr_reader :calls

    def initialize(pages: [[]])
      @pages = pages
      @calls = []
    end

    def call(arguments, input)
      @calls << { arguments: arguments, input: input && JSON.parse(input) }
      method = arguments[arguments.index("--method") + 1]
      path = arguments[3]

      if method == "GET" && path.include?("/comments?")
        page = path[/[?&]page=(\d+)/, 1].to_i
        return JSON.generate(@pages.fetch(page - 1, []))
      end

      return "" if method == "DELETE"

      JSON.generate("id" => 999)
    end
  end

  def comments(gh)
    described_class.new(repository: "powerhome/nitro-web", pull_request_number: "62698", runner: gh)
  end

  def marker(tag = "cobra-test-plan")
    described_class.marker(tag)
  end

  def request(gh, method)
    gh.calls.find { |call| call[:arguments][call[:arguments].index("--method") + 1] == method }
  end

  describe "#upsert" do
    it "creates a comment carrying its tag when the pull request has none" do
      gh = FakeGh.new
      result = comments(gh).upsert(tag: "cobra-test-plan", body: "## Plan\n")

      post = request(gh, "POST")
      expect(post[:arguments]).to include("repos/powerhome/nitro-web/issues/62698/comments")
      expect(post[:input].fetch("body")).to eq("## Plan\n#{marker}\n")
      expect(result).to include("created")
    end

    it "updates the comment carrying the same tag instead of posting a second one" do
      gh = FakeGh.new(pages: [[{ "id" => 7, "body" => "old plan\n#{marker}" }]])
      result = comments(gh).upsert(tag: "cobra-test-plan", body: "new plan")

      expect(request(gh, "PATCH")[:arguments])
        .to include("repos/powerhome/nitro-web/issues/comments/7")
      expect(request(gh, "POST")).to be_nil
      expect(result).to include("updated comment 7")
    end

    # Not recognising one would leave two test plans on the PR, the stale one first.
    it "adopts a comment left behind by the action this replaced" do
      legacy = described_class.legacy_marker("cobra-test-plan")
      gh = FakeGh.new(pages: [[{ "id" => 9, "body" => "old plan\n#{legacy}" }]])

      comments(gh).upsert(tag: "cobra-test-plan", body: "new plan")

      patch = request(gh, "PATCH")
      expect(patch[:arguments]).to include("repos/powerhome/nitro-web/issues/comments/9")
      expect(patch[:input].fetch("body")).to include(marker)
      expect(patch[:input].fetch("body")).not_to include(legacy)
    end

    it "ignores a comment tagged for a different profile step" do
      gh = FakeGh.new(pages: [[{ "id" => 3, "body" => "status\n#{marker("cobra-test-plan-status")}" }]])

      comments(gh).upsert(tag: "cobra-test-plan", body: "plan")

      expect(request(gh, "PATCH")).to be_nil
      expect(request(gh, "POST")).not_to be_nil
    end

    it "keeps looking past a full page of comments" do
      filler = Array.new(described_class::PER_PAGE) { |index| { "id" => index, "body" => "chatter" } }
      gh = FakeGh.new(pages: [filler, [{ "id" => 500, "body" => marker }]])

      comments(gh).upsert(tag: "cobra-test-plan", body: "plan")

      expect(request(gh, "PATCH")[:arguments])
        .to include("repos/powerhome/nitro-web/issues/comments/500")
    end

    it "stops after a partial page rather than paging forever" do
      gh = FakeGh.new(pages: [[{ "id" => 1, "body" => "chatter" }]])

      comments(gh).upsert(tag: "cobra-test-plan", body: "plan")

      listings = gh.calls.count { |call| call[:arguments][3].include?("/comments?") }
      expect(listings).to eq(1)
    end

    # A body read out of the environment is tagged with the locale's encoding, so the
    # em dash in every message this posts arrives as UTF-8 bytes tagged BINARY.
    it "sends a body that arrived from the environment as UTF-8" do
      gh = FakeGh.new
      binary = "\u2014 in progress".dup.force_encoding(Encoding::ASCII_8BIT)

      expect { comments(gh).upsert(tag: "cobra-test-plan", body: binary) }.not_to output.to_stderr

      expect(request(gh, "POST")[:input].fetch("body")).to start_with("\u2014 in progress")
    end

    it "sends the body as input rather than an argument" do
      gh = FakeGh.new
      comments(gh).upsert(tag: "cobra-test-plan", body: "a" * 5000)

      post = request(gh, "POST")
      expect(post[:arguments]).to include("--input", "-")
      expect(post[:arguments].join(" ")).not_to include("aaaa")
    end
  end

  describe "#delete" do
    it "removes the comment carrying the tag" do
      gh = FakeGh.new(pages: [[{ "id" => 12, "body" => "failed\n#{marker("cobra-test-plan-failure")}" }]])

      result = comments(gh).delete(tag: "cobra-test-plan-failure")

      expect(request(gh, "DELETE")[:arguments])
        .to include("repos/powerhome/nitro-web/issues/comments/12")
      expect(result).to include("deleted comment 12")
    end

    it "is a no-op when no comment carries the tag" do
      gh = FakeGh.new
      result = comments(gh).delete(tag: "cobra-test-plan-failure")

      expect(request(gh, "DELETE")).to be_nil
      expect(result).to eq("nothing to delete")
    end
  end

  describe "input it refuses" do
    it "rejects a tag that could break out of the marker" do
      gh = FakeGh.new
      expect { comments(gh).upsert(tag: 'x" --> <img src=q onerror=alert(1)>', body: "plan") }
        .to raise_error(/Invalid comment tag/)
      expect(gh.calls).to be_empty
    end

    it "rejects a repository that is not owner/name" do
      expect { described_class.new(repository: "nitro-web", pull_request_number: "1") }
        .to raise_error(/Invalid GITHUB_REPOSITORY/)
    end

    it "rejects a pull-request number that is not a number" do
      expect { described_class.new(repository: "powerhome/nitro-web", pull_request_number: "12; rm -rf /") }
        .to raise_error(ArgumentError)
    end
  end
end
