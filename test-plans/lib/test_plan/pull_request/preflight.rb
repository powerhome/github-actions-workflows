require_relative "./client"

module TestPlan
  module PullRequest
    class Preflight
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
  end
end
