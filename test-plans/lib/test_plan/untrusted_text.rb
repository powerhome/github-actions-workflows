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
  # The surrounding structure is built by this action. Backticks are retained for
  # inline code; other markup is neutralised. The entities render as the characters
  # they replace, while breaking the scheme separator stops bare URLs from autolinking.
  module UntrustedText
    module_function

    def escape(value)
      return "" unless value.is_a?(String)

      value
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
        .gsub("@", "&#64;")
        .gsub(/([\[\]])/) { "\\#{Regexp.last_match(1)}" }
        .gsub(%r{\b(https?|ftp)://}i) { "#{Regexp.last_match(1)}&#58;//" }
        .gsub(/\bwww\./i) { "www&#46;" }
    end
  end
end
