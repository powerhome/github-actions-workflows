require_relative "untrusted_text"

module TestPlan
  # The parts every plan shape renders identically: the heading testers find the comment
  # by, the notice naming what the response cost, and the escaping every provider-derived
  # string goes through.
  #
  # Shared rather than copied. Three formatters each carrying their own heading and their
  # own discard notice is three places for the wording to drift, and the copies were not
  # equally covered -- a change to the discard truncation could reach one plan shape and
  # not the others without a spec noticing.
  #
  # Includers set @profile_name, @pull_request_title, and @generation_warning, each
  # already through normalize_text.
  module PlanDocument
    # Past this the notice stops being readable, and the count still says how many there
    # were.
    MAX_NAMED_DISCARDS = 5

  private

    # The sections every plan opens with, in order: what it is, then anything that
    # qualifies what follows.
    def preamble
      sections = [heading]
      sections << "> ⚠️ #{@generation_warning}" unless @generation_warning.empty?
      sections << discarded_notice unless discarded.empty?
      sections
    end

    def heading
      name = @profile_name.empty? ? "Test Plan" : @profile_name
      title_suffix = @pull_request_title.empty? ? "" : ": #{sanitize(@pull_request_title)}"
      "## ✅ #{name}#{title_suffix}"
    end

    # Everything the response offered that the plan could not publish. Overridden where a
    # formatter drops parts of its own, so one notice accounts for every omission rather
    # than only the ones the parser made.
    def discarded
      @parsed.discarded
    end

    def discarded_notice
      reasons = discarded
      count = reasons.length
      lines = ["> ⚠️ #{count} #{count == 1 ? "part" : "parts"} of the generated response could not be used:"]
      reasons.first(MAX_NAMED_DISCARDS).each { |reason| lines << "> - #{sanitize(reason)}" }
      lines << "> - ...and #{count - MAX_NAMED_DISCARDS} more" if count > MAX_NAMED_DISCARDS
      lines.join("\n")
    end

    def sanitize(value)
      UntrustedText.escape(value)
    end

    def normalize_text(value)
      value.to_s.strip.gsub(/\s+/, " ")
    end
  end
end
