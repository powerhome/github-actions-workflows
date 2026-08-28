#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "rspec/autorun"

require_relative "pull_request_preflight"

RSpec.describe PullRequestPreflight do
  class FakePullRequestClient
    attr_reader :calls

    def initialize(states)
      @states = states
      @calls = 0
    end

    def fetch
      state = @states.fetch([@calls, @states.length - 1].min)
      @calls += 1
      {
        "baseRefOid" => "base",
        "headRefOid" => "head",
        "mergeable" => state,
        "title" => "Example",
      }
    end
  end

  it "allows a mergeable pull request immediately" do
    client = FakePullRequestClient.new(["MERGEABLE"])
    result = described_class.new(client: client, sleeper: ->(_seconds) {}).run

    expect(result).to include("generate" => true, "blocked" => false, "blocked_reason" => "")
    expect(client.calls).to eq(1)
  end

  it "blocks a conflicting pull request without retrying" do
    client = FakePullRequestClient.new(["CONFLICTING"])
    result = described_class.new(client: client, sleeper: ->(_seconds) {}).run

    expect(result).to include(
      "generate" => false,
      "blocked" => true,
      "blocked_reason" => "conflicting"
    )
    expect(client.calls).to eq(1)
  end

  it "retries UNKNOWN and proceeds when GitHub finishes calculating" do
    client = FakePullRequestClient.new(["UNKNOWN", "UNKNOWN", "MERGEABLE"])
    sleeps = []
    result = described_class.new(client: client, sleeper: ->(seconds) { sleeps << seconds }).run

    expect(result["generate"]).to be(true)
    expect(client.calls).to eq(3)
    expect(sleeps).to eq([2, 2])
  end

  it "blocks after five UNKNOWN retries" do
    client = FakePullRequestClient.new(["UNKNOWN"])
    sleeps = []
    result = described_class.new(client: client, sleeper: ->(seconds) { sleeps << seconds }).run

    expect(result).to include(
      "generate" => false,
      "blocked" => true,
      "blocked_reason" => "unknown"
    )
    expect(client.calls).to eq(6)
    expect(sleeps).to eq([2, 2, 2, 2, 2])
  end

  it "rejects undocumented mergeability states" do
    client = FakePullRequestClient.new(["DIRTY"])
    expect do
      described_class.new(client: client, sleeper: ->(_seconds) {}).run
    end.to raise_error(RuntimeError, /Unexpected/)
  end
end
