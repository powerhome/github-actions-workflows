require_relative "../../spec_helper"
require "test_plan/dependency_delta/git_snapshot"

require "open3"
require "tmpdir"

describe TestPlan::DependencyDelta::GitSnapshot do
  def git(directory, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: directory)
    raise "git #{args.join(" ")} failed: #{stderr}" unless status.success?

    stdout
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
