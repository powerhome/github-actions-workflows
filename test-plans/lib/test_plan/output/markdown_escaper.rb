# frozen_string_literal: true

module TestPlan
  module Output
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
    # cannot open a fence that swallows the plan below it. Neither is one behind a
    # backslash, which Markdown may read as escaped -- see CODE_SPAN.
    module MarkdownEscaper
      # CommonMark's inline code span. The lookarounds pin both runs to their full length,
      # so a span can never be closed by part of a longer run.
      #
      # A backslash disqualifies an opening run as surely as a backtick does. Markdown reads
      # \` as an escaped backtick, so it opens nothing, and the rest of what looked like a
      # span is ordinary text: \``@team`` was passed through whole and the mention notified
      # people. An escaped backslash does leave a real span, but telling the two apart means
      # counting backslashes, and over-escaping costs only formatting.
      CODE_SPAN = /(?<![`\\])(`+)(?!`)(.+?)(?<!`)\1(?!`)/

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
          # An entity renders as a backslash without acting as one, so provider text cannot
          # escape the markup this adds, or the delimiter of a span it sits in front of.
          .gsub("\\", "&#92;")
          .gsub(/([\[\]])/) { "\\#{Regexp.last_match(1)}" }
          .gsub(%r{\b(https?|ftp)://}i) { "#{Regexp.last_match(1)}&#58;//" }
          .gsub(/\bwww\./i) { "www&#46;" }
      end
    end
  end
end
