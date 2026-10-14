# frozen_string_literal: true

require_relative "spec_helper"

require "review_prompt"

RSpec.describe ReviewPrompt do
  let(:base) { "Base prompt.\n" }
  let(:last) { "a" * 40 }
  let(:head) { "b" * 40 }
  let(:finding) do
    { "key" => "F1", "thread_id" => "T1", "comment_id" => 7, "url" => "u", "status" => "open",
      "path" => "a.rb", "line" => 3, "body" => "Severity: high\n\nBroken", }
  end

  def prompt(context, additional_instructions: "", incremental_diff: nil)
    described_class.new(base:, context:, additional_instructions:, incremental_diff:).to_s
  end

  let(:incremental) { { "mode" => "incremental", "last_reviewed_sha" => last, "head_sha" => head, "findings" => [] } }

  it "is the base prompt alone on a first full review" do
    expect(prompt({ "mode" => "full", "findings" => [] })).to eq("Base prompt.")
  end

  it "scopes an incremental review to the new commits" do
    text = prompt(incremental, incremental_diff: "+new line\n")

    expect(text).to include("## Scope of this review", "pr-incremental.diff", "`#{last}..#{head}`")
    expect(text).not_to include("## Earlier findings")
  end

  it "inlines the incremental diff between random markers" do
    text = prompt(incremental, incremental_diff: "diff --git a/x b/x\n+new line\n")
    nonce = text[/<pr_incremental_diff_(\h{16})>/, 1]

    expect(nonce).not_to be_nil
    expect(text).to include("<pr_incremental_diff_#{nonce}>\ndiff --git a/x b/x\n+new line\n" \
                            "</pr_incremental_diff_#{nonce}>")
    expect(prompt(incremental, incremental_diff: "+x\n")).not_to include("<pr_incremental_diff_#{nonce}>")
  end

  it "leaves a large incremental diff on disk" do
    big = "+#{'x' * described_class::MAX_INLINE_INCREMENTAL_DIFF}\n"
    text = prompt(incremental, incremental_diff: big)

    expect(text).to include("too large to include")
    expect(text).not_to include("<pr_incremental_diff_")
  end

  it "lists earlier findings without their thread or comment IDs" do
    text = prompt({ "mode" => "full", "findings" => [finding] })

    expect(text).to include("## Earlier findings", "resolved_findings", "regression_of", '"key": "F1"', "Broken")
    expect(text).not_to include("T1")
    expect(text).not_to include("## Scope of this review")
  end

  it "puts the PR comment's instructions last" do
    text = prompt({ "mode" => "full", "findings" => [finding] }, additional_instructions: "Focus on SQL")

    expect(text).to end_with("## Additional instructions from the PR comment\n\nFocus on SQL\n\n" \
                             "#{described_class::REMINDER}")
    expect(text.index("## Earlier findings")).to be < text.index("## Additional instructions")
  end
end
