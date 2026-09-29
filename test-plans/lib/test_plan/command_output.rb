module TestPlan
  # Subprocess output is tagged with the locale's encoding, US-ASCII when nothing sets
  # LANG, and everything done with it then raises on the first byte above ASCII -- an
  # accented name in a gemspec, an emoji in a title -- failing the step on the runner's
  # environment rather than on anything in the pull request.
  #
  # Git and the GitHub CLI emit UTF-8 whatever the locale, so the tag is corrected rather
  # than trusted. Invalid bytes are replaced: one malformed file is not worth the rest of
  # the evidence.
  module CommandOutput
  module_function

    def utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
