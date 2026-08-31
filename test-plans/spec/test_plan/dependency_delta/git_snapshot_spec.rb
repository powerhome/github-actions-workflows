require_relative "../../spec_helper"
require "test_plan/dependency_delta"

require "open3"
require "tmpdir"

RSpec.describe TestPlan::DependencyDelta::GitSnapshot do
  def git(directory, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: directory)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?

    stdout
  end

  def with_external_encoding(encoding)
    original = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = original
    $VERBOSE = verbose
  end

  # A runner that sets no LANG leaves Ruby with a US-ASCII default external encoding, and
  # every scan, match and JSON.parse downstream then raises on the first byte above ASCII
  # in a manifest. The whole delta step failed, on the environment rather than on anything
  # in the pull request. Git emits UTF-8 regardless, so the tag is corrected, not trusted.
  it "reads git output as UTF-8 whatever the locale says" do
    Dir.mktmpdir do |directory|
      git(directory, "init", "--initial-branch", "main", ".")
      git(directory, "config", "user.email", "test@example.com")
      git(directory, "config", "user.name", "Test")

      File.write(File.join(directory, "widget.gemspec"), <<~SPEC, encoding: Encoding::UTF_8)
        Gem::Specification.new do |spec|
          spec.authors = ["Renée Dupré"]
          spec.add_dependency "rack"
        end
      SPEC
      git(directory, "add", ".")
      git(directory, "commit", "-m", "widget")
      head_sha = git(directory, "rev-parse", "HEAD").strip

      snapshot = described_class.new(workspace: directory, base_sha: head_sha, head_sha: head_sha)
      content = with_external_encoding(Encoding::US_ASCII) do
        snapshot.read(head_sha, "widget.gemspec")
      end

      expect(content.encoding).to eq(Encoding::UTF_8)
      expect(content).to be_valid_encoding
      expect(content).to include("Renée Dupré")
      # The scan that aborted the step; under US-ASCII this raised rather than matching.
      expect(content.scan(/add_dependency "([^"]+)"/).flatten).to eq(["rack"])
    end
  end

  it "resolves the merge base and reads the old side from it" do
    Dir.mktmpdir do |directory|
      git(directory, "init", "--initial-branch", "main", ".")
      git(directory, "config", "user.email", "test@example.com")
      git(directory, "config", "user.name", "Test")

      File.write(File.join(directory, "Gemfile.lock"), "fork point\n")
      git(directory, "add", ".")
      git(directory, "commit", "-m", "fork point")
      fork_point = git(directory, "rev-parse", "HEAD").strip

      git(directory, "checkout", "-b", "feature")
      File.write(File.join(directory, "Gemfile.lock"), "head\n")
      git(directory, "commit", "-am", "head")
      head_sha = git(directory, "rev-parse", "HEAD").strip

      git(directory, "checkout", "main")
      File.write(File.join(directory, "Gemfile.lock"), "base tip\n")
      git(directory, "commit", "-am", "base tip")
      base_sha = git(directory, "rev-parse", "HEAD").strip

      snapshot = described_class.new(workspace: directory, base_sha: base_sha, head_sha: head_sha)

      expect(snapshot.merge_base_sha).to eq(fork_point)
      expect(snapshot.read(snapshot.merge_base_sha, "Gemfile.lock")).to eq("fork point\n")
      expect(snapshot.changed_dependency_files).to eq(["Gemfile.lock"])
    end
  end

  it "matches dependency files on whole path segments" do
    Dir.mktmpdir do |directory|
      git(directory, "init", "--initial-branch", "main", ".")
      git(directory, "config", "user.email", "test@example.com")
      git(directory, "config", "user.name", "Test")

      {
        "package.json" => "{}",
        "components/widget/package.json" => "{}",
        "docs/my-package.json" => "{}",
        "config/custom-Gemfile" => "",
        "Gemfile" => "",
        "widget.gemspec" => "",
      }.each do |path, content|
        FileUtils.mkdir_p(File.join(directory, File.dirname(path)))
        File.write(File.join(directory, path), content)
      end
      git(directory, "add", ".")
      git(directory, "commit", "-m", "fixtures")
      head_sha = git(directory, "rev-parse", "HEAD").strip

      snapshot = described_class.new(workspace: directory, base_sha: head_sha, head_sha: head_sha)

      expect(snapshot.paths_at(head_sha, "package.json"))
        .to contain_exactly("package.json", "components/widget/package.json")
      expect(snapshot.paths_at(head_sha, "Gemfile")).to eq(["Gemfile"])
      expect(snapshot.paths_at(head_sha, ".gemspec")).to eq(["widget.gemspec"])
    end
  end
end
