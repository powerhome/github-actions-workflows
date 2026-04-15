#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "rspec/autorun"
require "tempfile"

require_relative "agent_review_parser"

RSpec.describe AgentReviewParser do
  describe "#summary_body" do
    it "includes the version marker and summary text" do
      parsed = described_class.new({ "summary" => "Hello" }.to_json)
      expect(parsed.summary_body).to match(
        /\A<!-- agentic-pr-review #{described_class::REVIEW_POSTER_VERSION} -->\n\nHello\z/mo
      )
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

  describe "code fence stripping" do
    it "parses JSON wrapped in ```json fences" do
      raw = "```json\n#{{"summary" => "fenced"}.to_json}\n```"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("fenced")
    end

    it "parses JSON wrapped in bare ``` fences" do
      raw = "```\n#{{"summary" => "bare"}.to_json}\n```"
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("bare")
    end

    it "handles surrounding whitespace with fences" do
      raw = "  \n```json\n#{{"summary" => "padded"}.to_json}\n```\n  "
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("padded")
    end

    it "leaves plain JSON untouched" do
      raw = {"summary" => "plain"}.to_json
      parsed = described_class.new(raw)
      expect(parsed.summary_body).to include("plain")
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
