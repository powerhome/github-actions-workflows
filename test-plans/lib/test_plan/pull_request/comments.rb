require "json"
require "open3"

require_relative "../runner_text"

module TestPlan
  module PullRequest
    # Replaces thollander/actions-comment-pull-request, which is pinned to Node 20 and
    # unmaintained since November 2024. Each mode it provided is one list plus one write.
    class Comments
      # The tag goes inside an HTML comment, so one holding "-->" or a quote would break
      # out of the marker. Restricting the shape is cheaper than escaping it.
      TAG_PATTERN = /\A[a-z][a-z0-9-]*\z/
      REPOSITORY_PATTERN = %r{\A[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\z}

      # Not named after this action: agentic-pr-review carries a copy of this client, and
      # an identical marker means a later extraction need not migrate comment identities.
      def self.marker(tag)
        %(<!-- powerhome/github-actions-workflows "#{tag}" -->)
      end

      # thollander's marker, still on open pull requests: not recognising one posts a
      # second test plan beside a stale one. The first upsert rewrites the body, so this
      # can go once those pull requests have cycled.
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
          created = request(
            "POST", "repos/#{@repository}/issues/#{@pull_request_number}/comments", body: content
          )
          "created comment #{created["id"]}"
        end
      end

      # The ordinary case: most runs never wrote the failure comment both paths clear.
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

      # Over stdin, never an argument: a rendered plan is tens of kilobytes.
      def request(method, path, body: nil)
        arguments = ["api", "--method", method, path]
        arguments += ["--header", "Accept: application/vnd.github+json"]
        input = nil

        if body
          arguments += ["--input", "-"]
          # An inline body out of the environment is tagged with the locale's encoding,
          # and JSON.generate on UTF-8 bytes tagged BINARY warns today and raises under
          # json 3.0. Both inline messages contain an em dash.
          input = JSON.generate("body" => RunnerText.utf8(body))
        end

        stdout = @runner.call(arguments, input)
        return nil if stdout.strip.empty?

        JSON.parse(stdout)
      end

      def capture(arguments, input)
        stdout, stderr, status = Open3.capture3("gh", *arguments, stdin_data: input.to_s)
        unless status.success?
          raise "gh #{arguments.first(3).join(" ")} failed: #{RunnerText.utf8(stderr).strip}"
        end

        RunnerText.utf8(stdout)
      end
    end
  end
end
