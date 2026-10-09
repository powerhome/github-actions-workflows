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

    it "records the reviewed head SHA in the marker" do
      sha = "a" * 40
      parsed = described_class.new({ "summary" => "Hello" }.to_json, head_sha: sha)

      expect(parsed.summary_body).to start_with(
        "<!-- agentic-pr-review #{described_class::REVIEW_POSTER_VERSION} head=#{sha} -->\n\n"
      )
      expect(described_class.reviewed_sha(parsed.summary_body)).to eq(sha)
    end
  end

  describe ".reviewed_sha" do
    it "is nil for a marker from before head= was recorded" do
      body = "<!-- agentic-pr-review 1.0.0 -->\n\nOld review"

      expect(described_class.marker?(body)).to be(true)
      expect(described_class.reviewed_sha(body)).to be_nil
    end

    it "is nil for a body with no marker" do
      expect(described_class.marker?("Looks good")).to be(false)
      expect(described_class.reviewed_sha("Looks good")).to be_nil
    end

    it "ignores a head= value that is not a full SHA" do
      expect(described_class.reviewed_sha("<!-- agentic-pr-review 1.1.0 head=--upload-pack=x -->")).to be_nil
    end
  end

  describe "#resolved_findings" do
    it "returns the stripped, unique keys" do
      parsed = described_class.new({ "summary" => "S", "resolved_findings" => ["F1", " F2 ", "F1", ""] }.to_json)
      expect(parsed.resolved_findings).to eq(%w[F1 F2])
    end

    it "is empty when the agent leaves it out or sends a non-array" do
      expect(described_class.new({ "summary" => "S" }.to_json).resolved_findings).to eq([])
      expect(described_class.new({ "summary" => "S", "resolved_findings" => "F1" }.to_json).resolved_findings).to eq([])
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

    it "keeps regression_of only when the agent sets it" do
      json = {
        "summary" => "S",
        "comments" => [
          { "path" => "a.rb", "body" => "back again", "line" => 2, "regression_of" => "F3" },
          { "path" => "b.rb", "body" => "new", "line" => 4, "regression_of" => " " },
        ],
      }.to_json
      parsed = described_class.new(json)

      expect(parsed.inline_comments.map { |c| c["regression_of"] }).to eq(["F3", nil])
      expect(parsed.inline_comments.last).not_to have_key("regression_of")
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
