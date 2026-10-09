# frozen_string_literal: true

require_relative "spec_helper"

require "diff_lines"

RSpec.describe DiffLines do
  let(:diff) do
    <<~DIFF
      diff --git a/lib/a.rb b/lib/a.rb
      index 111..222 100644
      --- a/lib/a.rb
      +++ b/lib/a.rb
      @@ -1,4 +1,5 @@
       one
      -two
      +TWO
      +two and a half
       three

      @@ -10,2 +11,3 @@ def foo
       ten
      +++ an added line that looks like a header
       eleven
      diff --git a/old.rb b/old.rb
      deleted file mode 100644
      --- a/old.rb
      +++ /dev/null
      @@ -1 +0,0 @@
      -gone
      diff --git "a/sp\\303\\251cial.rb" "b/sp\\303\\251cial.rb"
      new file mode 100644
      --- /dev/null
      +++ "b/sp\\303\\251cial.rb"
      @@ -0,0 +1 @@
      +new
      \\ No newline at end of file
    DIFF
  end

  describe ".added" do
    it "numbers added lines on the new side, by path" do
      added = described_class.added(diff)

      expect(added.keys).to contain_exactly("lib/a.rb", "spécial.rb")
      expect(added["lib/a.rb"].to_a.sort).to eq([2, 3, 12])
      expect(added["spécial.rb"].to_a).to eq([1])
    end

    it "is empty for an empty diff" do
      expect(described_class.added("")).to eq({})
    end
  end

  describe ".intersect" do
    it "keeps only the lines both diffs add" do
      left = { "a.rb" => Set[1, 2, 3], "b.rb" => Set[5] }
      right = { "a.rb" => Set[2, 3, 4], "c.rb" => Set[1] }

      expect(described_class.intersect(left, right)).to eq("a.rb" => Set[2, 3])
    end
  end
end
