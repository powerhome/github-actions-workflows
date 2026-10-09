# frozen_string_literal: true

require_relative "spec_helper"

require "review_scope"

RSpec.describe ReviewScope do
  let(:head) { "b" * 40 }
  let(:last) { "a" * 40 }

  def decide(requested: "auto", event_name: "pull_request", last_reviewed_sha: last, ancestor: true)
    described_class.decide(
      requested:,
      event_name:,
      last_reviewed_sha:,
      head_sha: head,
      ancestor: ->(_sha) { ancestor }
    )
  end

  it "reviews only the new commits when the last-reviewed SHA is still in the history" do
    scope = decide

    expect(scope.mode).to eq("incremental")
    expect(scope).to be_incremental
    expect(scope.last_reviewed_sha).to eq(last)
  end

  it "does a full review on the first review" do
    expect(decide(last_reviewed_sha: nil).mode).to eq("full")
  end

  it "does a full review after a rebase or force-push" do
    scope = decide(ancestor: false)

    expect(scope.mode).to eq("full")
    expect(scope.reason).to include("no longer in the branch history")
    expect(scope.last_reviewed_sha).to be_nil
  end

  it "does a full review when triggered manually, whatever the stored SHA" do
    expect(decide(event_name: "issue_comment").mode).to eq("full")
    expect(decide(event_name: "workflow_dispatch").mode).to eq("full")
  end

  it "does a full review when the caller asks for one" do
    expect(decide(requested: "full").mode).to eq("full")
  end

  it "skips a head that was already reviewed" do
    expect(decide(last_reviewed_sha: head)).to be_skip
  end

  it "treats an empty scope as auto" do
    expect(decide(requested: "").mode).to eq("incremental")
  end

  it "rejects an unknown scope" do
    expect { decide(requested: "partial") }.to raise_error(RuntimeError, /Invalid review-scope/)
  end

  it "does not check ancestry when there is nothing to check" do
    ancestor = ->(_sha) { raise "should not be called" }

    expect(
      described_class.decide(requested: "auto", event_name: "pull_request", last_reviewed_sha: nil,
                             head_sha: head, ancestor:).mode
    ).to eq("full")
  end
end
