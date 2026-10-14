# frozen_string_literal: true

module TestPlan
  # A plan written from part of the diff reads as a complete one, so a shortfall is said at
  # the top of the comment instead of being left for the reader to notice.
  module CoverageWarning
  module_function

    def for(files_reviewed:, changed_files:)
      changed = Integer(changed_files.to_s, exception: false)
      return "" unless changed&.positive?
      return "" if files_reviewed && files_reviewed >= changed

      if files_reviewed.nil?
        "The test plan did not report how many of the #{changed} changed files it read, so it may be partial."
      else
        "The test plan reported reading #{files_reviewed} of #{changed} changed files. The rest are not covered."
      end
    end
  end
end
