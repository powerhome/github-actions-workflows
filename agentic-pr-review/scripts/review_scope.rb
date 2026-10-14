#!/usr/bin/env ruby
# frozen_string_literal: true

# Decides whether a run reviews the whole pull request, only what was pushed since the
# bot's last review, or nothing at all.
class ReviewScope
  SCOPES = %w[auto full].freeze
  # Someone asked for these runs, so they review everything rather than the latest push.
  MANUAL_EVENTS = %w[issue_comment workflow_dispatch].freeze

  attr_reader :mode, :reason, :last_reviewed_sha

  # ancestor: called with the last-reviewed SHA, true when it is still in the head's history.
  def self.decide(requested:, event_name:, last_reviewed_sha:, head_sha:, ancestor:)
    requested = requested.to_s.empty? ? "auto" : requested.to_s
    unless SCOPES.include?(requested)
      raise "Invalid review-scope: #{requested.inspect} (expected one of #{SCOPES.join(', ')})"
    end

    return new("full", "a full review was requested") if requested == "full"
    return new("full", "the review was triggered manually (#{event_name})") if MANUAL_EVENTS.include?(event_name)
    return new("full", "no earlier review records the head it covered") if last_reviewed_sha.nil?
    return new("skip", "#{head_sha} was already reviewed", last_reviewed_sha) if last_reviewed_sha == head_sha
    unless ancestor.call(last_reviewed_sha)
      return new("full", "#{last_reviewed_sha} is no longer in the branch history (rebase or force-push)")
    end

    new("incremental", "reviewing #{last_reviewed_sha}..#{head_sha}", last_reviewed_sha)
  end

  def initialize(mode, reason, last_reviewed_sha = nil)
    @mode = mode
    @reason = reason
    @last_reviewed_sha = last_reviewed_sha
  end

  def incremental?
    mode == "incremental"
  end

  def skip?
    mode == "skip"
  end
end
