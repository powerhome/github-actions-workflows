require_relative "../spec_helper"
require "test_plan/untrusted_text"

RSpec.describe TestPlan::UntrustedText do
  def escape(value)
    described_class.escape(value)
  end

  describe "outside a code span" do
    it "stops a mention from notifying anyone" do
      expect(escape("Ask @security about it")).to eq("Ask &#64;security about it")
    end

    it "stops inline HTML from rendering" do
      expect(escape(%(<img src="x" onerror="alert(1)">))).to start_with("&lt;img")
      expect(escape("<b>bold</b>")).not_to include("<")
    end

    it "stops link and image syntax from resolving" do
      expect(escape("![shot](https://example.test/x.png)")).to include("!\\[shot\\]")
    end

    # Breaking the scheme separator is what stops the autolinker; escaping the bracket
    # syntax alone leaves a bare URL clickable.
    it "stops a bare URL and a bare host from autolinking" do
      expect(escape("See https://example.test/path")).to eq("See https&#58;//example.test/path")
      expect(escape("See www.example.test")).to eq("See www&#46;example.test")
      expect(escape("ftp://example.test")).to eq("ftp&#58;//example.test")
    end

    it "escapes the ampersand first, so an entity it writes is not re-escaped" do
      expect(escape("Tom & Jerry <tag>")).to eq("Tom &amp; Jerry &lt;tag&gt;")
    end

    it "renders a non-string as empty rather than through to_s" do
      expect(escape(nil)).to eq("")
      expect(escape(42)).to eq("")
    end
  end

  # GitHub renders a code span's contents literally -- no entity decoded, no mention
  # resolved, no tag interpreted -- so escaping inside one publishes the escape itself.
  describe "inside a closed code span" do
    it "leaves the characters a reader was meant to see" do
      expect(escape("Confirm `a < b` holds")).to eq("Confirm `a < b` holds")
      expect(escape("Open `items[0]`")).to eq("Open `items[0]`")
      expect(escape("The `&` operator")).to eq("The `&` operator")
    end

    it "keeps a mention, a URL and a tag inert without escaping them" do
      expect(escape("Set `@user` in `<config>` at `https://example.test`"))
        .to eq("Set `@user` in `<config>` at `https://example.test`")
    end

    it "escapes the prose around a span and not the span" do
      expect(escape("Open `/menu` and check [link](https://example.test)."))
        .to eq("Open `/menu` and check \\[link\\](https&#58;//example.test).")
    end

    it "handles several spans on one line" do
      expect(escape("Mix `a[0]` and `b<c>` and <img>"))
        .to eq("Mix `a[0]` and `b<c>` and &lt;img&gt;")
    end

    it "supports a multi-backtick span holding a backtick" do
      expect(escape("`` ` ``")).to eq("`` ` ``")
    end
  end

  # A response cannot open a code block that swallows the plan rendered below it.
  describe "backticks that close nothing" do
    it "neutralises a lone backtick" do
      expect(escape("A lone ` backtick")).to eq("A lone &#96; backtick")
    end

    it "neutralises an unclosed fence" do
      expect(escape("```js")).to eq("&#96;&#96;&#96;js")
      expect(escape("```ruby\nSystem.exit")).to include("&#96;&#96;&#96;ruby")
    end

    it "neutralises a run that does not match the one that opened" do
      expect(escape("``a`")).to eq("&#96;&#96;a&#96;")
    end

    it "still escapes the markup around them" do
      expect(escape("` @team <img>")).to eq("&#96; &#64;team &lt;img&gt;")
    end
  end
end
