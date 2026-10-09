# frozen_string_literal: true

require_relative "spec_helper"

require "set"

require "review_triage"

RSpec.describe ReviewTriage do
  let(:findings) do
    [
      { "key" => "F1", "thread_id" => "T1", "status" => "open", "path" => "a.rb", "line" => 10,
        "url" => "https://github.test/c/1", },
      { "key" => "F2", "thread_id" => "T2", "status" => "resolved", "path" => "a.rb", "line" => 20,
        "url" => "https://github.test/c/2", },
      { "key" => "F3", "thread_id" => "T3", "status" => "dismissed", "path" => "b.rb", "line" => nil,
        "url" => "https://github.test/c/3", },
    ]
  end

  def comment(path, line, body = "issue", regression_of: nil)
    entry = { "path" => path, "line" => line, "body" => body, "side" => "RIGHT" }
    entry["regression_of"] = regression_of if regression_of
    entry
  end

  def triage(comments, resolved_keys: [], allowed_lines: nil)
    described_class.new(comments:, resolved_keys:, findings:, allowed_lines:)
  end

  it "passes new comments through without the regression_of key" do
    result = triage([comment("c.rb", 1)])

    expect(result.comments).to eq([comment("c.rb", 1)])
  end

  it "drops a comment on the line of a thread that is still open" do
    result = nil
    expect { result = triage([comment("a.rb", 10)]) }.to output(/repeats F1/).to_stderr

    expect(result.comments).to be_empty
  end

  it "keeps a comment on an open thread's line when that thread is being resolved" do
    result = triage([comment("a.rb", 10)], resolved_keys: ["F1"])

    expect(result.comments.size).to eq(1)
  end

  it "links a regression to the resolved thread it repeats" do
    result = triage([comment("a.rb", 21, "back", regression_of: "F2")])

    expect(result.comments.size).to eq(1)
    expect(result.comments.first["body"]).to include("back", "[an earlier thread](https://github.test/c/2)")
    expect(result.comments.first).not_to have_key("regression_of")
  end

  it "does not treat a comment as a regression of a thread that is open or dismissed" do
    result = nil
    expect do
      result = triage([comment("a.rb", 10, regression_of: "F1"), comment("b.rb", 3, regression_of: "F3")])
    end.to output(/repeats F1/).to_stderr

    expect(result.comments.map { |c| c["path"] }).to eq(["b.rb"])
    expect(result.comments.first["body"]).not_to include("earlier thread")
  end

  it "drops comments off the allowed lines" do
    allowed = { "c.rb" => Set[5] }
    result = nil
    expect do
      result = triage([comment("c.rb", 5), comment("c.rb", 6), comment("d.rb", 1)], allowed_lines: allowed)
    end.to output(/not on a line changed since the last review/).to_stderr

    expect(result.comments.map { |c| [c["path"], c["line"]] }).to eq([["c.rb", 5]])
  end

  it "resolves only open threads, once each, and ignores unknown keys" do
    result = triage([], resolved_keys: %w[F1 F1 F2 F3 F9])

    expect(result.threads_to_resolve.map { |f| f["thread_id"] }).to eq(["T1"])
  end
end
