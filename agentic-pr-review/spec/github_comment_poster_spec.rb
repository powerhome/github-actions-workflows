require_relative "spec_helper"

require "json"

require "github_comment_poster"

RSpec.describe GitHubCommentPoster do
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

      # per_page=100 also contains "page=100", so anchor on the separator.
      if method == "GET" && path.include?("/comments?")
        return JSON.generate(@pages.fetch(path[/[?&]page=(\d+)/, 1].to_i - 1, []))
      end

      return "" if method == "DELETE"

      JSON.generate("id" => 999)
    end
  end

  def poster(gh)
    described_class.new(repository: "powerhome/nitro-web", pr_number: "42", runner: gh)
  end

  def request(gh, method)
    gh.calls.find { |call| call[:arguments][call[:arguments].index("--method") + 1] == method }
  end

  let(:tag) { "agentic-pr-review-status" }

  describe "#upsert" do
    it "creates a comment carrying its tag when the pull request has none" do
      gh = FakeGh.new
      result = poster(gh).upsert(tag: tag, body: "in progress")

      post = request(gh, "POST")
      expect(post[:arguments]).to include("repos/powerhome/nitro-web/issues/42/comments")
      expect(post[:input].fetch("body")).to eq("in progress\n#{described_class.marker(tag)}\n")
      expect(result).to include("created comment 999")
    end

    it "updates the comment carrying the same tag instead of posting a second one" do
      gh = FakeGh.new(pages: [[{ "id" => 7, "body" => "older\n#{described_class.marker(tag)}" }]])
      result = poster(gh).upsert(tag: tag, body: "in progress")

      expect(request(gh, "PATCH")[:arguments])
        .to include("repos/powerhome/nitro-web/issues/comments/7")
      expect(request(gh, "POST")).to be_nil
      expect(result).to include("updated comment 7")
    end

    # Not recognising one would leave two status comments on the PR.
    it "adopts a comment left behind by the action this replaced" do
      legacy = described_class.legacy_marker(tag)
      gh = FakeGh.new(pages: [[{ "id" => 9, "body" => "older\n#{legacy}" }]])

      poster(gh).upsert(tag: tag, body: "in progress")

      patch = request(gh, "PATCH")
      expect(patch[:arguments]).to include("repos/powerhome/nitro-web/issues/comments/9")
      expect(patch[:input].fetch("body")).to include(described_class.marker(tag))
      expect(patch[:input].fetch("body")).not_to include(legacy)
    end

    it "keeps looking past a full page of comments" do
      filler = Array.new(described_class::PER_PAGE) { |index| { "id" => index, "body" => "chatter" } }
      gh = FakeGh.new(pages: [filler, [{ "id" => 500, "body" => described_class.marker(tag) }]])

      poster(gh).upsert(tag: tag, body: "in progress")

      expect(request(gh, "PATCH")[:arguments])
        .to include("repos/powerhome/nitro-web/issues/comments/500")
    end

    # A body read out of the environment is tagged with the locale's encoding, so the
    # em dash in every message this posts arrives as UTF-8 bytes tagged BINARY.
    it "sends a body that arrived from the environment as UTF-8" do
      gh = FakeGh.new
      binary = "\u2014 in progress".dup.force_encoding(Encoding::ASCII_8BIT)

      expect { poster(gh).upsert(tag: tag, body: binary) }.not_to output.to_stderr

      expect(request(gh, "POST")[:input].fetch("body")).to start_with("\u2014 in progress")
    end

    it "sends the body as input rather than an argument" do
      gh = FakeGh.new
      poster(gh).upsert(tag: tag, body: "a" * 5000)

      post = request(gh, "POST")
      expect(post[:arguments]).to include("--input", "-")
      expect(post[:arguments].join(" ")).not_to include("aaaa")
    end
  end

  describe "#create" do
    # The failure comment is untagged, so a second failure adds a second comment rather
    # than overwriting the first.
    it "posts an untagged comment without looking for an existing one" do
      gh = FakeGh.new
      result = poster(gh).create(body: ":x: failed")

      expect(request(gh, "GET")).to be_nil
      expect(request(gh, "POST")[:input].fetch("body")).to eq(":x: failed")
      expect(result).to include("created comment 999")
    end
  end

  describe "#delete" do
    it "removes the comment carrying the tag" do
      gh = FakeGh.new(pages: [[{ "id" => 12, "body" => described_class.marker(tag) }]])
      result = poster(gh).delete(tag: tag)

      expect(request(gh, "DELETE")[:arguments])
        .to include("repos/powerhome/nitro-web/issues/comments/12")
      expect(result).to include("deleted comment 12")
    end

    it "is a no-op when no comment carries the tag" do
      gh = FakeGh.new
      result = poster(gh).delete(tag: tag)

      expect(request(gh, "DELETE")).to be_nil
      expect(result).to eq("nothing to delete")
    end
  end

  describe "input it refuses" do
    it "rejects a tag that could break out of the marker" do
      gh = FakeGh.new
      expect { poster(gh).upsert(tag: 'x" --> <img src=q onerror=alert(1)>', body: "hi") }
        .to raise_error(/Invalid comment tag/)
      expect(gh.calls).to be_empty
    end

    it "rejects a repository that is not owner/name" do
      expect { described_class.new(repository: "nitro-web", pr_number: "1") }
        .to raise_error(/Invalid GITHUB_REPOSITORY/)
    end

    it "rejects a pull-request number that is not a number" do
      expect { described_class.new(repository: "powerhome/nitro-web", pr_number: "12; rm -rf /") }
        .to raise_error(ArgumentError)
    end
  end
end
