require "json"
require "open3"

module TestPlan
  module PullRequest
    class Client
      QUERY = <<~GRAPHQL.freeze
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              baseRefOid
              headRefOid
              mergeable
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
  end
end
