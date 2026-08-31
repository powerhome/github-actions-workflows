module TestPlan
  # Text read back from a subprocess is tagged with the locale's encoding, which is
  # US-ASCII when nothing sets LANG. Everything this action then does with that text --
  # scan, match, JSON.parse, writing it back out as UTF-8 -- raises on the first byte
  # above ASCII: an accented name in a gemspec, a non-ASCII path, an emoji in a pull
  # request title. The failure is the whole step, and it depends on the runner's
  # environment rather than on anything in the pull request.
  #
  # Git and the GitHub CLI emit UTF-8 whatever the locale, so the tag is corrected rather
  # than trusted. Bytes that are not valid UTF-8 are replaced rather than raised on: one
  # malformed file is not worth the rest of the evidence.
  module CommandOutput
    module_function

    def utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
