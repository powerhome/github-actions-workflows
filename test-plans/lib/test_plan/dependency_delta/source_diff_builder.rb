require "digest"
require "open3"

module TestPlan
  module DependencyDelta
    class SourceDiffBuilder
      PRIORITY_CHANGELOG = 0
      PRIORITY_RUNTIME = 1
      PRIORITY_TEST = 2
      PRIORITY_DOC = 3
      PRIORITY_GENERATED = 4

      CHANGELOG_PATTERN = %r{(?:^|/)(?:change(?:log|s)?|history|release(?:s|_notes)?|upgrade(?:_guide)?)(?:\.|/|$)}i
      # Directory segments, plus colocated names like avatar.test.js and widget_spec.rb.
      # Matching only on directories scored Playbook's colocated tests as runtime source,
      # so they competed with real source for the context budget.
      TEST_PATTERN = %r{
        (?:^|/)(?:test|tests|spec|specs|__tests__)(?:/|$)
        |
        [._-](?:test|spec)\.[^/]+\z
      }xi
      DOC_PATTERN = %r{(?:^|/)(?:docs?|readme)(?:\.|/|$)}i
      GENERATED_PATTERN = %r{(?:^|/)(?:vendor|dist|build|coverage|node_modules)(?:/|$)|(?:\.min\.|\.map\z)}i

      def build(old_root, new_root)
        paths = (files(old_root) | files(new_root)).sort_by { |path| [priority(path), path] }
        paths.filter_map do |path|
          old_path = File.join(old_root, path)
          new_path = File.join(new_root, path)
          next if same_file?(old_path, new_path)

          if binary?(old_path) || binary?(new_path)
            binary_marker(path, old_path, new_path)
          else
            unified_diff(path, old_path, new_path)
          end
        end
      end

    private

      def files(root)
        return [] unless Dir.exist?(root)

        Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select do |path|
          next false if path == "." || path == ".."

          File.file?(File.join(root, path)) && !File.symlink?(File.join(root, path))
        end
      end

      # Generated is decided before test and documentation, because a name like
      # dist/widget.test.js or build/docs/readme.md is build output whatever its suffix
      # suggests. Classifying it as a test left generated?(that) false, which sent a
      # linked release's bundles to the provider despite the exclusion. Changelogs stay
      # first: one shipped inside dist/ is still the release notes.
      def priority(path)
        return PRIORITY_CHANGELOG if path.match?(CHANGELOG_PATTERN)
        return PRIORITY_GENERATED if path.match?(GENERATED_PATTERN)
        return PRIORITY_TEST if path.match?(TEST_PATTERN)
        return PRIORITY_DOC if path.match?(DOC_PATTERN)

        PRIORITY_RUNTIME
      end

      # A binary file has no readable diff, but dropping it left an icon, an image, or a
      # font changing with nothing to show for it -- absent from the artifact and from
      # every omission list, against the promise that what is dropped gets named. The
      # marker costs a line and keeps the change countable.
      def binary_marker(path, old_path, new_path)
        state =
          if !File.file?(old_path) then "was added"
          elsif !File.file?(new_path) then "was removed"
          else "changed"
          end

        SourceDiff.new(
          path: path,
          diff: "Binary file #{path} #{state} (#{File.size(File.file?(new_path) ? new_path : old_path)} bytes)\n",
          priority: priority(path)
        )
      end

      def same_file?(old_path, new_path)
        File.file?(old_path) && File.file?(new_path) && Digest::SHA256.file(old_path) == Digest::SHA256.file(new_path)
      end

      def binary?(path)
        return false unless File.file?(path)

        File.open(path, "rb") { |file| file.read(8192).to_s.include?("\0") }
      end

      def unified_diff(relative, old_path, new_path)
        old_input = File.file?(old_path) ? old_path : "/dev/null"
        new_input = File.file?(new_path) ? new_path : "/dev/null"
        stdout, stderr, status = Open3.capture3(
          "diff", "-u",
          "--label", "a/#{relative}",
          "--label", "b/#{relative}",
          old_input, new_input
        )
        raise "diff failed for #{relative}: #{stderr.strip}" unless [0, 1].include?(status.exitstatus)

        stdout.empty? ? nil : SourceDiff.new(path: relative, diff: stdout, priority: priority(relative))
      end
    end
  end
end
