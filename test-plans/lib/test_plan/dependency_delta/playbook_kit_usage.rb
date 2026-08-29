require "open3"

module TestPlan
  module DependencyDelta
    # A Playbook version bump is the PR shape this whole delta exists for, and it is the
    # one where pr.diff says least: every file in such a bump is a lockfile. The
    # changelog tells the model which kits moved, but not the only thing a tester needs
    # -- which pages to open.
    #
    # Answering that means resolving a kit across every call site in a large
    # application. The agent could search for them, but at that scale it is slow and
    # unreliable, so the search happens here and the answer is handed over as evidence.
    #
    # The kits are taken from the gem's own changed file paths rather than the changelog
    # prose: every kit lives in app/pb_kits/playbook/pb_<kit>/, which is exact, where
    # matching release-note headings is guesswork. On the 17.0.0 -> 17.1.0 delta the
    # paths yield materially more kits than the prose does.
    class PlaybookKitUsage
      PACKAGE_NAMES = %w[playbook_ui playbook-ui].freeze
      KIT_PATH = %r{(?:\A|/)app/pb_kits/playbook/pb_([a-z0-9_]+)/}
      # Past this a list stops being a set of pages to visit and becomes noise; the count
      # still tells the model the kit is everywhere.
      MAX_LISTED_FILES = 25
      SEARCHED_EXTENSIONS = %w[*.erb *.rb *.haml *.tsx *.jsx *.ts *.js].freeze

      def self.disabled
        new(workspace: nil)
      end

      def initialize(workspace:)
        @workspace = workspace
        @kits = {}
      end

      # Called for every dependency the generator retrieves; ignores all but Playbook.
      def observe(change, diffs)
        return unless @workspace
        return unless PACKAGE_NAMES.include?(change.name)

        diffs.each do |diff|
          kit = diff.path[KIT_PATH, 1]
          next unless kit

          (@kits[kit] ||= []) << "#{change.ecosystem}:#{change.name}"
        end
      end

      def report
        return nil if @kits.empty?

        sections = @kits.keys.sort.map { |kit| section(kit) }
        <<~REPORT
          # Playbook kits changed by this upgrade

          The upgrade changed #{@kits.length} #{@kits.length == 1 ? "kit" : "kits"}. Each section below
          lists where this repository uses that kit, so coverage can start from the pages
          a tester can actually open. Paths are repository-relative.

          A kit used in more than #{MAX_LISTED_FILES} files is reported as a count only. Those are
          shared building blocks; cover a representative page rather than every one.

          #{sections.join("\n")}
        REPORT
      end

    private

      def section(kit)
        files = usage(kit)
        heading = "## #{titleize(kit)} (`#{kit}`) — #{files.length} #{files.length == 1 ? "file" : "files"}"

        return "#{heading}\n\nUsed too widely to list. Cover a representative page.\n" if files.length > MAX_LISTED_FILES
        return "#{heading}\n\nNo usage found in this repository.\n" if files.empty?

        "#{heading}\n\n#{files.map { |file| "- #{file}" }.join("\n")}\n"
      end

      # These are POSIX ERE for git grep, not Ruby regexps: \s and (?:...) are silently
      # unsupported there and match nothing at all, so they are written out longhand.
      #
      # Rails kits are called as pb_rails("kit"), pb_rails("kit/sub_template"), and for a
      # few kits pb_rails("pb_kit"). React kits are used as the camelized tag.
      def usage(kit)
        rails = %Q{pb_rails\\([[:space:]]*["'](pb_)?#{kit}["'/]}
        react = %Q{<#{camelize(kit)}[[:space:]/>]}

        (git_grep(rails) | git_grep(react)).sort
      end

      def git_grep(pattern)
        stdout, _stderr, status = Open3.capture3(
          "git", "grep", "--no-color", "-l", "-E", pattern, "--", *SEARCHED_EXTENSIONS,
          chdir: @workspace
        )
        # git grep exits 1 when nothing matched, which is not an error here.
        return [] unless [0, 1].include?(status.exitstatus)

        stdout.lines.map(&:chomp).reject(&:empty?)
      rescue
        []
      end

      def camelize(kit)
        kit.split("_").map(&:capitalize).join
      end

      def titleize(kit)
        kit.split("_").map(&:capitalize).join(" ")
      end
    end
  end
end
