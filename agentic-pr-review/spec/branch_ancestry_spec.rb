# frozen_string_literal: true

require_relative "spec_helper"

require "open3"
require "tmpdir"

require "branch_ancestry"

RSpec.describe BranchAncestry do
  let(:api) { instance_double(GitHubApi) }

  # A real shallow clone of a branch that was reviewed at F1, then got F2, a merge from main,
  # and F3. Cloned to depth 3, it holds F3, the merge, F2 and main's commit, but not F1.
  around do |example|
    Dir.mktmpdir do |root|
      @origin = File.join(root, "origin")
      @clone = File.join(root, "clone")
      build_origin
      git(root, "clone", "--quiet", "--depth=3", "--branch=feature", "file://#{@origin}", @clone)
      example.run
    end
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=Spec", "-c", "user.email=spec@example.test",
                                  "-c", "init.defaultBranch=main", *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?

    out.strip
  end

  def commit(message)
    File.write(File.join(@origin, "#{message}.txt"), message)
    git(@origin, "add", ".")
    git(@origin, "commit", "--quiet", "-m", message)
    git(@origin, "rev-parse", "HEAD")
  end

  def build_origin
    Dir.mkdir(@origin)
    git(@origin, "init", "--quiet")
    git(@origin, "config", "uploadpack.allowAnySHA1InWant", "true")
    commit("base")
    git(@origin, "checkout", "--quiet", "-b", "feature")
    @f1 = commit("f1")
    commit("f2")
    git(@origin, "checkout", "--quiet", "main")
    commit("main2")
    git(@origin, "checkout", "--quiet", "feature")
    git(@origin, "merge", "--quiet", "--no-edit", "main")
    @f3 = commit("f3")
  end

  def ancestry
    described_class.new(api:, owner: "acme", repo: "widgets", git_dir: @clone)
  end

  def stub_compare(status)
    allow(api).to receive(:get).with("/repos/acme/widgets/compare/#{@f1}...#{@f3}?per_page=1")
                               .and_return("status" => status)
  end

  it "counts a commit behind a merge from the base as an ancestor, which git alone can't see here" do
    stub_compare("ahead")

    expect(ancestry.ancestor?(@f1, @f3)).to be(true)
    # Fetched for the incremental diff, but the shallow boundary still hides the path to it.
    expect(system("git", "-C", @clone, "merge-base", "--is-ancestor", @f1, @f3, err: File::NULL)).to be(false)
    expect(git(@clone, "diff", "--name-only", @f1, @f3).lines.map(&:strip)).to contain_exactly(
      "f2.txt", "f3.txt", "main2.txt"
    )
  end

  it "is false for a rewritten branch" do
    stub_compare("diverged")

    expect(ancestry.ancestor?(@f1, @f3)).to be(false)
  end

  it "is false when the compare fails" do
    allow(api).to receive(:get).and_raise(GitHubApi::RequestError, "HTTP 404: Not Found")

    expect { expect(ancestry.ancestor?(@f1, @f3)).to be(false) }.to output(/compare .* failed/).to_stderr
  end

  it "is false, without asking the API, when the commit can't be fetched" do
    expect(api).not_to receive(:get)

    expect(ancestry.ancestor?("0" * 40, @f3)).to be(false)
  end
end
