#!/usr/bin/env ruby
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rspec", "~> 3.13"
end

require "json"
require "rspec/autorun"

require_relative "github_review_poster"

RSpec.describe GitHubReviewPoster do
  let(:owner) { "acme" }
  let(:repo) { "widgets" }
  let(:pr_number) { 42 }
  let(:commit_sha) { "abc123" }
  let(:token) { "secret-token" }

  subject(:poster) do
    described_class.new(
      owner:,
      repo:,
      pr_number:,
      commit_sha:,
      token:
    )
  end

  def build_response(klass, code:, message:, body:)
    response = klass.new("1.1", code.to_s, message)
    allow(response).to receive(:body).and_return(body)
    response
  end

  def stub_post(response, host: "api.github.com", port: 443, use_ssl: true)
    captured_request = nil
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request) do |request|
      captured_request = request
      response
    end

    allow(Net::HTTP).to receive(:start).with(host, port, use_ssl:).and_yield(http)

    -> { captured_request }
  end

  describe "#post_batch_review" do
    it "posts a review with summary and inline comments" do
      response = build_response(
        Net::HTTPCreated,
        code: 201,
        message: "Created",
        body: { id: 1 }.to_json
      )
      request_for = stub_post(response)
      comments = [{ "path" => "a.rb", "line" => 7, "side" => "RIGHT", "body" => "Please fix" }]

      expect(poster.post_batch_review("Summary", comments)).to be_truthy

      request = request_for.call
      expect(request.path).to eq("/repos/acme/widgets/pulls/42/reviews")
      expect(request["Authorization"]).to eq("Bearer secret-token")
      expect(request["Accept"]).to eq("application/vnd.github+json")
      expect(request["X-GitHub-Api-Version"]).to eq("2022-11-28")
      expect(request["User-Agent"]).to eq("nitro-agentic-pr-review")
      expect(request.content_type).to eq("application/json")
      expect(JSON.parse(request.body)).to eq(
        "commit_id" => "abc123",
        "body" => "Summary",
        "event" => "COMMENT",
        "comments" => comments
      )
    end
  end

  describe "#post_summary_only" do
    it "returns false and logs the API error" do
      response = build_response(
        Net::HTTPUnprocessableEntity,
        code: 422,
        message: "Unprocessable Entity",
        body: { message: "Validation Failed", errors: [{ "field" => "line" }] }.to_json
      )
      stub_post(response)

      expect do
        expect(poster.post_summary_only("Summary")).to eq(false)
      end.to output(/Summary review failed: HTTP 422: Validation Failed/).to_stderr
    end
  end

  describe "#post_single_comment" do
    it "defaults side to RIGHT and posts to the comments endpoint" do
      response = build_response(
        Net::HTTPCreated,
        code: 201,
        message: "Created",
        body: { id: 2 }.to_json
      )
      request_for = stub_post(response, host: "github.example.com", port: 8443, use_ssl: true)
      comment = { "path" => "lib/test.rb", "line" => 3, "body" => "Nit: rename this" }
      allow(ENV).to receive(:fetch).with("GITHUB_API_URL", "https://api.github.com")
                                   .and_return("https://github.example.com:8443/api/v3")

      expect(poster.post_single_comment(comment)).to eq(true)

      request = request_for.call
      expect(request.path).to eq("/api/v3/repos/acme/widgets/pulls/42/comments")
      expect(JSON.parse(request.body)).to eq(
        "body" => "Nit: rename this",
        "commit_id" => "abc123",
        "path" => "lib/test.rb",
        "line" => 3,
        "side" => "RIGHT"
      )
    end
  end

end
