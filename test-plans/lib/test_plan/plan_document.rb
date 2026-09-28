require_relative "untrusted_text"

module TestPlan
  # The heading, discard notice and escaping every plan shape renders identically. Shared
  # rather than copied, so the wording cannot drift between shapes that are not equally
  # covered.
  #
  # Includers set @profile_name, @pull_request_title and @generation_warning, each already
  # through normalize_text.
  module PlanDocument
    # Past this the notice stops being readable; the count still says how many there were.
    MAX_NAMED_DISCARDS = 5

  private

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

    # Overridden where a formatter drops parts of its own, so one notice accounts for
    # every omission and not only the parser's.
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
