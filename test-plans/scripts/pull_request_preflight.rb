#!/usr/bin/env ruby

require "json"
require "open3"

class GitHubPullRequestClient
  QUERY = <<~GRAPHQL.freeze
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          baseRefOid
          headRefOid
          mergeable
          state
          title
        }
      }
    }
  GRAPHQL

  def initialize(repository:, pull_request_number:)
    @owner, @name = repository.split("/", 2)
    @pull_request_number = Integer(pull_request_number)
    raise "Invalid GITHUB_REPOSITORY: #{repository.inspect}" if @owner.to_s.empty? || @name.to_s.empty?
  end

  def fetch
    stdout, stderr, status = Open3.capture3(
      "gh", "api", "graphql",
      "-f", "query=#{QUERY}",
      "-F", "owner=#{@owner}",
      "-F", "name=#{@name}",
      "-F", "number=#{@pull_request_number}"
    )
    raise "GitHub pull-request query failed: #{stderr.strip}" unless status.success?

    payload = JSON.parse(stdout).dig("data", "repository", "pullRequest")
    raise "Pull request #{@pull_request_number} was not found" unless payload.is_a?(Hash)

    payload
  end
end

class PullRequestPreflight
  MAX_UNKNOWN_RETRIES = 5
  RETRY_DELAY_SECONDS = 2
  VALID_STATES = %w[MERGEABLE CONFLICTING UNKNOWN].freeze

  def initialize(client:, sleeper: ->(seconds) { sleep(seconds) })
    @client = client
    @sleeper = sleeper
  end

  def run
    pull_request = nil

    (MAX_UNKNOWN_RETRIES + 1).times do |attempt|
      pull_request = @client.fetch
      mergeable = pull_request.fetch("mergeable")
      raise "Unexpected pull-request mergeable state: #{mergeable}" unless VALID_STATES.include?(mergeable)

      break unless mergeable == "UNKNOWN"
      @sleeper.call(RETRY_DELAY_SECONDS) if attempt < MAX_UNKNOWN_RETRIES
    end

    mergeable = pull_request.fetch("mergeable")
    pull_request.merge(
      "generate" => mergeable == "MERGEABLE",
      "blocked" => mergeable != "MERGEABLE",
      "blocked_reason" => blocked_reason(mergeable)
    )
  end

private

  def blocked_reason(mergeable)
    {
      "MERGEABLE" => "",
      "CONFLICTING" => "conflicting",
      "UNKNOWN" => "unknown",
    }.fetch(mergeable)
  end
end

class PullRequestPreflightCommand
  def run
    client = GitHubPullRequestClient.new(
      repository: ENV.fetch("GITHUB_REPOSITORY"),
      pull_request_number: ENV.fetch("PR_NUMBER")
    )
    result = PullRequestPreflight.new(client: client).run

    File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
      output.puts("base_sha=#{result.fetch("baseRefOid")}")
      output.puts("head_sha=#{result.fetch("headRefOid")}")
      output.puts("title=#{normalize_line(result.fetch("title"))}")
      output.puts("mergeable=#{result.fetch("mergeable")}")
      output.puts("generate=#{result.fetch("generate")}")
      output.puts("blocked=#{result.fetch("blocked")}")
      output.puts("blocked_reason=#{result.fetch("blocked_reason")}")
    end
  end

private

  def normalize_line(value)
    value.to_s.gsub(/[\r\n]+/, " ").strip
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    PullRequestPreflightCommand.new.run
  rescue JSON::ParserError => e
    warn "GitHub pull-request response was not valid JSON: #{e.message}"
    exit 1
  rescue KeyError => e
    warn "Missing required value: #{e.message}"
    exit 1
  rescue => e
    warn e.message
    exit 1
  end
end
