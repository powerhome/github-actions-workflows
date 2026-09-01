#!/usr/bin/env ruby

require "json"
require "open3"

# Replaces thollander/actions-comment-pull-request, which is pinned to Node 20 and
# unmaintained since November 2024.
#
# A deliberate copy of test-plans/lib/test_plan/pull_request/comments.rb: the two actions
# are versioned and consumed independently, so they do not share code. The marker format
# is identical on purpose -- a fix or the legacy-marker removal belongs in both.
class GitHubCommentPoster
  # The tag is carried in the comment body, inside an HTML comment -- so a tag holding
  # "-->" or a quote would break out of the marker. Restricting the shape is cheaper
  # than escaping it.
  TAG_PATTERN = /\A[a-z][a-z0-9-]*\z/
  REPOSITORY_PATTERN = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}

  def self.marker(tag)
    %(<!-- powerhome/github-actions-workflows "#{tag}" -->)
  end

  # thollander's marker. Its comments are still on open pull requests, and not
  # recognising one posts a second status comment beside a stale one. The first upsert
  # rewrites the body, so this can go once those pull requests have cycled.
  def self.legacy_marker(tag)
    %(<!-- thollander/actions-comment-pull-request "#{tag}" -->)
  end

  # per_page is the API maximum; MAX_PAGES only stops the loop running forever if the
  # API keeps answering with full pages.
  PER_PAGE = 100
  MAX_PAGES = 20

  def initialize(repository:, pr_number:, runner: nil)
    unless REPOSITORY_PATTERN.match?(repository.to_s)
      raise "Invalid GITHUB_REPOSITORY: #{repository.inspect}"
    end

    @repository = repository.to_s
    @pr_number = Integer(pr_number)
    @runner = runner || method(:capture)
  end

  def upsert(tag:, body:)
    validate_tag!(tag)
    content = "#{body.to_s.sub(/\n+\z/, "")}\n#{self.class.marker(tag)}\n"
    existing = find(tag)

    if existing
      request("PATCH", "repos/#{@repository}/issues/comments/#{existing}", body: content)
      "updated comment #{existing}"
    else
      "created comment #{post(content).fetch("id")}"
    end
  end

  # Untagged, so every call leaves a new comment. That is what the failure comment did
  # before this replaced the action, and a run that failed twice for different reasons
  # says more as two comments than as one overwritten.
  def create(body:)
    "created comment #{post(body.to_s).fetch("id")}"
  end

  # A missing comment is the ordinary case: the status comment is cleared on runs that
  # never got far enough to post it.
  def delete(tag:)
    validate_tag!(tag)
    existing = find(tag)
    return "nothing to delete" unless existing

    request("DELETE", "repos/#{@repository}/issues/comments/#{existing}")
    "deleted comment #{existing}"
  end

  private

  def validate_tag!(tag)
    raise "Invalid comment tag: #{tag.inspect}" unless TAG_PATTERN.match?(tag.to_s)
  end

  def post(content)
    request("POST", "repos/#{@repository}/issues/#{@pr_number}/comments", body: content)
  end

  def find(tag)
    markers = [self.class.marker(tag), self.class.legacy_marker(tag)]

    1.upto(MAX_PAGES) do |page|
      comments = request(
        "GET", "repos/#{@repository}/issues/#{@pr_number}/comments?per_page=#{PER_PAGE}&page=#{page}"
      )
      comments = [] unless comments.is_a?(Array)

      match = comments.find do |comment|
        body = comment["body"].to_s
        markers.any? { |marker| body.include?(marker) }
      end
      return match["id"] if match
      return nil if comments.length < PER_PAGE
    end

    nil
  end

  # The body goes over stdin, never an argument: a review summary is model-written text
  # of no fixed length.
  def request(method, path, body: nil)
    arguments = ["api", "--method", method, path, "--header", "Accept: application/vnd.github+json"]
    input = nil

    if body
      arguments += ["--input", "-"]
      # utf8 before generating: a body read out of the environment is tagged with the
      # locale's encoding, and JSON.generate on UTF-8 bytes tagged BINARY warns today and
      # raises under json 3.0. Both messages this posts contain an em dash.
      input = JSON.generate("body" => utf8(body))
    end

    stdout = @runner.call(arguments, input)
    return nil if stdout.strip.empty?

    JSON.parse(stdout)
  end

  # gh emits UTF-8 whatever the locale, but the pipe is tagged with the locale's
  # encoding -- US-ASCII when nothing sets LANG -- and JSON.parse then raises on the
  # first non-ASCII byte in a comment body.
  def capture(arguments, input)
    stdout, stderr, status = Open3.capture3("gh", *arguments, stdin_data: input.to_s)
    unless status.success?
      raise "gh #{arguments.first(3).join(" ")} failed: #{utf8(stderr).strip}"
    end

    utf8(stdout)
  end

  def utf8(text)
    text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end
end
