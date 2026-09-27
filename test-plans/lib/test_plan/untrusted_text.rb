module TestPlan
  # One policy for rendering text this action did not write into Markdown that GitHub
  # will render — the pull-request comment and the job summary alike.
  #
  # The sources are all outside our control: provider output, which pull-request content
  # influences; the pull-request title, which its author writes; and dependency names,
  # versions, and paths, which come from lockfiles the pull request can edit. Left raw,
  # any of them can carry an @mention that notifies people, a link or image pointing
  # anywhere, or inline HTML, published under the bot's name.
  #
  # The surrounding structure is always built by this action, so untrusted text never
  # needs to carry markup and is neutralised wholesale. The entities render as the
  # characters they replace, so a reader still sees exactly what was written; breaking
  # the scheme separator is what stops a bare URL from autolinking, which escaping
  # bracket syntax alone does not.
  #
  # Inline code is the one exception. A plan names routes and identifiers, and a reader
  # is better served seeing `/contact_center/menu` set apart from the prose around it. A
  # complete code span is passed through as written, because GitHub renders its contents
  # literally: no entity is decoded, no backslash honoured, no URL autolinked, no mention
  # resolved, and no tag interpreted. Escaping inside one publishes the escape itself —
  # `items[0]` would reach a reader as `items\[0\]` and `a < b` as `a &lt; b`.
  #
  # That holds only for backticks that actually close. A lone backtick, or a fence a
  # response opened and never closed, is not inline code and is neutralised like any
  # other markup, so a response cannot open a code block that swallows the plan below it.
  module UntrustedText
    # CommonMark's inline code span: a run of backticks, the text it encloses, and a run
    # of exactly the same length closing it. The lookarounds pin both runs to their full
    # length, so a span can never be closed by part of a longer run.
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

    # Everything outside a code span, where GitHub does resolve markup. Backticks reaching
    # here are the ones that closed nothing.
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
