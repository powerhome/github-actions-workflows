# frozen_string_literal: true

require_relative "spec_helper"

require "json"
require "tempfile"

require "agent_review_parser"

RSpec.describe AgentReviewParser do
  describe "#summary_body" do
    it "includes the version marker and summary text" do
      parsed = described_class.new({ "summary" => "Hello" }.to_json)
      expect(parsed.summary_body).to match(
        /\A<!-- agentic-pr-review #{described_class::REVIEW_POSTER_VERSION} -->\n\nHello\z/mo
      )
    end
  end

  describe "coverage warning" do
    def summary_for(payload, changed_files)
      described_class.new(payload.to_json, changed_files:).summary_body
    end

    it "adds nothing when the reviewer read every changed file" do
      expect(summary_for({ "summary" => "S", "files_reviewed" => 4 }, 4)).not_to include(":warning:")
    end

    it "adds nothing when the changed file count is unknown" do
      expect(summary_for({ "summary" => "S" }, nil)).not_to include(":warning:")
    end

    it "says how many files were read when that falls short" do
      body = summary_for({ "summary" => "S", "files_reviewed" => 2 }, 5)

      expect(body).to include("reading 2 of 5 changed files")
      expect(body).to match(/\A<!-- agentic-pr-review [\d.]+ -->\n\n:warning:.*\n\nS\z/)
    end

    it "says so when the reviewer reports no count" do
      expect(summary_for({ "summary" => "S" }, 5)).to include("did not report how many of the 5 changed files")
    end
  end

  describe "#inline_comments" do
    it "builds entries with severity prefix and metadata" do
      json = {
        "summary" => "S",
        "comments" => [
          { "path" => "a.rb", "body" => "fix", "line" => 2, "severity" => "high" },
        ],
      }.to_json
      parsed = described_class.new(json)
      expect(parsed.inline_comments.size).to eq(1)
      c = parsed.inline_comments.first
      expect(c["path"]).to eq("a.rb")
      expect(c["line"]).to eq(2)
      expect(c["side"]).to eq("RIGHT")
      expect(c["body"]).to match(/^\*\*Severity: high\*\*/)
      expect(c["body"]).to match(/fix\z/)
    end

    it "skips invalid comment rows" do
      json = {
        "summary" => "S",
        "comments" => [
          { "path" => "", "body" => "x", "line" => 1 },
          { "path" => "ok.rb", "body" => "good", "line" => 1 },
          { "path" => "bad.rb", "body" => "no line" },
        ],
      }.to_json
      parsed = described_class.new(json)
      expect(parsed.inline_comments.size).to eq(1)
      expect(parsed.inline_comments.first["path"]).to eq("ok.rb")
    end

    it "treats non-array comments as empty" do
      parsed = described_class.new({ "summary" => "S", "comments" => "nope" }.to_json)
      expect(parsed.inline_comments).to be_empty
    end

    it "truncates past the max and warns on stderr" do
      comments = (1..(described_class::MAX_INLINE_COMMENTS + 5)).map do |i|
        { "path" => "f.rb", "body" => "c#{i}", "line" => i }
      end
      json = { "summary" => "S", "comments" => comments }.to_json
      parsed = nil
      expect do
        parsed = described_class.new(json)
      end.to output(/truncating/).to_stderr
      expect(parsed.inline_comments.size).to eq(described_class::MAX_INLINE_COMMENTS)
    end
  end

  describe ".parse_file" do
    it "reads JSON from disk" do
      Tempfile.create(["review", ".json"]) do |f|
        f.write({ "summary" => "From file" }.to_json)
        f.flush
        parsed = described_class.parse_file(f.path)
        expect(parsed.summary_body).to include("From file")
      end
    end
  end

  describe "JSON extraction" do
    it "parses JSON wrapped in ```json fences" do
      raw = "```json\n#{{ "summary" => "fenced" }.to_json}\n```"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("fenced")
    end

    it "parses JSON wrapped in bare ``` fences" do
      raw = "```\n#{{ "summary" => "bare" }.to_json}\n```"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("bare")
    end

    it "handles surrounding whitespace with fences" do
      raw = "  \n```json\n#{{ "summary" => "padded" }.to_json}\n```\n  "
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("padded")
    end

    it "leaves plain JSON untouched" do
      raw = { "summary" => "plain" }.to_json
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("plain")
    end

    it "extracts JSON when the model emits text before the object" do
      raw = "Here is my review:\n#{{ "summary" => "prefixed" }.to_json}"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("prefixed")
    end

    it "extracts JSON when the model emits text after the object" do
      raw = "#{{ "summary" => "suffixed" }.to_json}\nI hope this helps!"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("suffixed")
    end

    it "extracts JSON when the model emits text before and after" do
      raw = "Sure, here you go:\n#{{ "summary" => "wrapped", "comments" => [] }.to_json}\nLet me know if you need more."
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("wrapped")
    end

    it "extracts JSON when the model wraps with prose and code fences" do
      raw = "Here is the review:\n```json\n#{{ "summary" => "both" }.to_json}\n```\nDone!"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("both")
    end
  end

  describe "validation" do
    it "rejects a non-object JSON root" do
      expect do
        described_class.new("[1]")
      end.to raise_error(RuntimeError, /JSON object/)
    end

    it "rejects an empty summary" do
      expect do
        described_class.new({ "summary" => "  " }.to_json)
      end.to raise_error(RuntimeError, /summary/)
    end
  end
end
