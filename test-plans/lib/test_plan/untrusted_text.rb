module TestPlan
  # One policy for every string this action did not write -- provider output, the
  # pull-request title, and names and paths out of lockfiles the pull request can edit --
  # rendered into Markdown GitHub will resolve. Left raw, any of them can carry a mention
  # that notifies people, a link or image pointing anywhere, or inline HTML, under the
  # bot's name. This action builds the surrounding structure, so all of it is neutralised.
  #
  # Entities render as the characters they replace; breaking the scheme separator is what
  # stops a bare URL autolinking, which escaping bracket syntax alone does not.
  #
  # Inline code is the exception, so a plan can set a route apart from its prose. A closed
  # code span passes through as written because GitHub renders its contents literally --
  # no entity decoded, no mention resolved, no URL autolinked, no tag interpreted -- so
  # escaping inside one publishes the escape itself: `items[0]` as `items\[0\]`.
  #
  # A backtick that closes nothing is not inline code and is neutralised, so a response
  # cannot open a fence that swallows the plan below it.
  module UntrustedText
    # CommonMark's inline code span. The lookarounds pin both runs to their full length,
    # so a span can never be closed by part of a longer run.
    CODE_SPAN = /(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)/

    module_function

    def escape(value)
      return "" unless value.is_a?(String)

      escaped = +""
      remainder = value

      while (match = CODE_SPAN.match(remainder))
        escaped << escape_markup(match.pre_match) << match[0]
        remainder = match.post_match
      end

      escaped << escape_markup(remainder)
    end

    # Backticks reaching here closed nothing.
    def escape_markup(value)
      value
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub("@", "&#64;")
        .gsub("`", "&#96;")
        .gsub(/([\[\]])/) { "\\#{Regexp.last_match(1)}" }
        .gsub(%r{\b(https?|ftp)://}i) { "#{Regexp.last_match(1)}&#58;//" }
        .gsub(/\bwww\./i) { "www&#46;" }
    end
  end
end
