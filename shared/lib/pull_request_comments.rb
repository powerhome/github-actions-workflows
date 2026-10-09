# frozen_string_literal: true

require "json"
require "open3"

# Replaces thollander/actions-comment-pull-request, which is pinned to Node 20 and
# unmaintained since November 2024. Each mode it provided is one list plus one write.
class PullRequestComments
  # The tag goes inside an HTML comment, so one holding "-->" or a quote would break out
  # of the marker. Restricting the shape is cheaper than escaping it.
  TAG_PATTERN = /\A[a-z][a-z0-9-]*\z/
  REPOSITORY_PATTERN = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}

  # Named after the repository rather than either action, so every action here finds the
  # comments the others' tags left.
  def self.marker(tag)
    %(<!-- powerhome/github-actions-workflows "#{tag}" -->)
  end

  # thollander's marker, still on open pull requests: not recognising one posts a second
  # comment beside a stale one. The first upsert rewrites the body, so this can go once
  # those pull requests have cycled.
  def self.legacy_marker(tag)
    %(<!-- thollander/actions-comment-pull-request "#{tag}" -->)
  end

  # MAX_PAGES only stops the loop if the API keeps answering with full pages.
  PER_PAGE = 100
  MAX_PAGES = 20

  def initialize(repository:, pull_request_number:, runner: nil)
    unless REPOSITORY_PATTERN.match?(repository.to_s)
      raise "Invalid GITHUB_REPOSITORY: #{repository.inspect}"
    end

    @repository = repository.to_s
    @pull_request_number = Integer(pull_request_number)
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
      "created comment #{post(content)["id"]}"
    end
  end

  # Untagged, so every call leaves a new comment: a run that failed twice for different
  # reasons says more as two comments than as one overwritten.
  def create(body:)
    "created comment #{post(body.to_s)["id"]}"
  end

  # A missing comment is the ordinary case: most runs never wrote the comment they clear.
  def delete(tag:)
    validate_tag!(tag)
    existing = find(tag)
    return "nothing to delete" unless existing

    request("DELETE", "repos/#{@repository}/issues/comments/#{existing}")
    "deleted comment #{existing}"
  end

  # Subprocess output is tagged with the locale's encoding, US-ASCII when nothing sets
  # LANG, and JSON then raises on the first byte above ASCII. gh emits UTF-8 whatever the
  # locale, so the tag is corrected rather than trusted.
  def self.utf8(text)
    text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
  end

private

  def validate_tag!(tag)
    raise "Invalid comment tag: #{tag.inspect}" unless TAG_PATTERN.match?(tag.to_s)
  end

  def post(content)
    request("POST", "repos/#{@repository}/issues/#{@pull_request_number}/comments", body: content)
  end

  def find(tag)
    markers = [self.class.marker(tag), self.class.legacy_marker(tag)]

    1.upto(MAX_PAGES) do |page|
      comments = request(
        "GET",
        "repos/#{@repository}/issues/#{@pull_request_number}/comments" \
          "?per_page=#{PER_PAGE}&page=#{page}"
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

  # Over stdin, never an argument: a rendered plan or a review summary runs to tens of
  # kilobytes.
  def request(method, path, body: nil)
    arguments = ["api", "--method", method, path]
    arguments += ["--header", "Accept: application/vnd.github+json"]
    input = nil

    if body
      arguments += ["--input", "-"]
      # An inline body out of the environment is tagged with the locale's encoding, and
      # JSON.generate on UTF-8 bytes tagged BINARY warns today and raises under json 3.0.
      # The inline messages contain an em dash.
      input = JSON.generate("body" => self.class.utf8(body))
    end

    stdout = @runner.call(arguments, input)
    return nil if stdout.strip.empty?

    JSON.parse(stdout)
  end

  def capture(arguments, input)
    stdout, stderr, status = Open3.capture3("gh", *arguments, stdin_data: input.to_s)
    unless status.success?
      raise "gh #{arguments.first(3).join(" ")} failed: #{self.class.utf8(stderr).strip}"
    end

    self.class.utf8(stdout)
  end
end
