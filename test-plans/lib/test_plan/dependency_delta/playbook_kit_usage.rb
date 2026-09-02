require "open3"

require_relative "../command_output"
require_relative "../playbook/kit_facts"
require_relative "./call_site_sample"

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
      # A kit used this few times can be covered exhaustively, and the plan says so. Past
      # it the plan tests a sample and says that instead, so SAMPLE_SIZE has to leave
      # enough call sites to choose a few representative ones from.
      SAMPLE_SIZE = 8
      SEARCHED_EXTENSIONS = %w[*.erb *.rb *.haml *.tsx *.jsx *.ts *.js].freeze
      # A kit is two implementations sharing a name, and a release usually moves only one
      # of them. Naming which one halves what a tester has to reopen. A stylesheet, or an
      # extension nothing here recognises, moves both -- reported as both rather than
      # guessed at, because the cost of guessing wrong is a system nobody retests.
      RAILS_EXTENSIONS = %w[.rb .erb .haml].freeze
      REACT_EXTENSIONS = %w[.tsx .jsx .ts .js].freeze
      SEARCH_FAILED = "The search for this kit could not be run, so this section says " \
        "nothing about whether the kit is used here. Treat it as possibly used and see " \
        "the workflow run log for the reason."

      def self.disabled
        new(workspace: nil)
      end

      def initialize(workspace:)
        @workspace = workspace
        @kits = {}
        @evidence = {}
        @failures = []
      end

      # Called for every dependency the generator retrieves; ignores all but Playbook.
      def observe(change, diffs)
        return unless @workspace
        return unless PACKAGE_NAMES.include?(change.name)

        diffs.each do |diff|
          # A doc example or a test moving is not the kit changing. Playbook ships both
          # inside the kit directory, so without this a release that only refreshed the
          # docs site reported the kit as changed and sent testers looking for a
          # difference there is none of.
          next unless diff.evidence?

          kit = diff.path[KIT_PATH, 1]
          next unless kit

          (@kits[kit] ||= []) << diff.path
        end
      end

      # Empty unless the run raised Playbook, which is what shapes the plan by kit.
      def kits
        @kits.keys.sort
      end

      def report
        return nil if @kits.empty?

        sections = @kits.keys.sort.map { |kit| section(kit) }
        <<~REPORT
          # Playbook kits changed by this upgrade

          The upgrade changed #{@kits.length} #{@kits.length == 1 ? "kit" : "kits"}. Each section below
          names which side of the kit the release touched -- the Rails helper, the React
          component, or both -- and lists where this repository calls that side, so
          coverage starts from pages a tester can actually open. Paths are
          repository-relative, and the call sites listed for a kit are deliberately spread
          across components.

          #{sections.join("\n")}
        REPORT
      end

      # The facts the comment is rendered from. Built from the same evidence the report is
      # written from, so the plan and the provider cannot disagree about a kit's coverage.
      def facts
        Playbook::KitFacts.document(
          @kits.keys.sort.map do |kit|
            evidence = evidence_for(kit)
            {
              slug: kit,
              name: titleize(kit),
              coverage: evidence.coverage,
              call_sites: evidence.call_sites,
              systems_changed: evidence.systems_changed,
              systems_in_use: evidence.systems_in_use,
            }
          end
        )
      end

    private

      # No counts appear here on purpose. The provider used to be asked to copy one and
      # report it back, which is a number nobody could check; the coverage sentence carries
      # the same decision and there is nothing left to miscopy. The counts stay in the
      # facts file, the job summary and the run log.
      def section(kit)
        evidence = evidence_for(kit)
        heading = "#{titled(kit)} — changed in #{Playbook::KitFacts.systems_label(evidence.systems_changed)}"
        return "#{heading} · search failed\n\n#{SEARCH_FAILED}\n" unless evidence.searchable?

        sentence = Playbook::KitFacts.sentence(evidence.coverage)
        # Nothing renders this kit at all, which the sentence already says. Listing each
        # changed system to repeat it per system would say it twice.
        return "#{heading}\n\n#{sentence}\n" if evidence.systems_in_use.empty?

        body = evidence.systems_changed.map { |system| system_block(system, evidence) }

        "#{heading}\n\n#{sentence}\n\n#{body.join("\n")}"
      end

      def system_block(system, evidence)
        label = "**#{Playbook::KitFacts::SYSTEM_LABELS.fetch(system)} call sites**"
        paths = evidence.sampled(system)
        if paths.empty?
          return "#{label}\n\nThis upgrade changed the #{Playbook::KitFacts::SYSTEM_LABELS.fetch(system)} " \
            "side of this kit, but nothing in this repository renders it.\n"
        end

        "#{label}\n\n#{paths.map { |path| "- #{path}" }.join("\n")}\n"
      end

      KitEvidence = Struct.new(:systems_changed, :call_sites_by_system, keyword_init: true) do
        def searchable?
          call_sites_by_system.values.none?(&:nil?)
        end

        def systems_in_use
          systems_changed.select { |system| !call_sites_by_system[system].to_a.empty? }
        end

        # Counted across the systems the release actually touched, so a React-only change
        # to a kit with two React call sites and nine hundred Rails ones is exhaustible.
        def call_sites
          systems_changed.flat_map { |system| call_sites_by_system[system].to_a }.uniq.length
        end

        def coverage
          Playbook::KitFacts.coverage(call_sites: call_sites, searchable: searchable?)
        end

        # Spread before the slice, so eight pages out of a thousand buy breadth rather
        # than eight files from whichever component sorts first. Sorted after, so the
        # block reads in a stable order while still being chosen for breadth.
        def sampled(system)
          CallSiteSample.spread(call_sites_by_system[system].to_a).first(SAMPLE_SIZE).sort
        end
      end

      # Memoized because the report and the facts are built from it in the same run, and a
      # git grep over a monorepo of this size costs seconds rather than milliseconds.
      def evidence_for(kit)
        @evidence[kit] ||= begin
          systems = systems_changed(@kits.fetch(kit, []))
          KitEvidence.new(
            systems_changed: systems,
            # Only the systems the release touched: a Rails-only change stops paying for a
            # React search it has no use for.
            call_sites_by_system: systems.to_h { |system| [system, usage(kit, system)] }
          )
        end
      end

      def systems_changed(paths)
        systems = paths.flat_map { |path| systems_for(path) }.uniq
        Playbook::KitFacts::SYSTEMS.select { |system| systems.include?(system) }
      end

      def systems_for(path)
        case File.extname(path).downcase
        when *RAILS_EXTENSIONS then ["rails"]
        when *REACT_EXTENSIONS then ["react"]
        else Playbook::KitFacts::SYSTEMS
        end
      end

      # These are POSIX ERE for git grep, not Ruby regexps: \s and (?:...) are silently
      # unsupported there and match nothing at all, so they are written out longhand.
      #
      # Rails kits are called as pb_rails("kit"), pb_rails("kit/sub_template"), and for a
      # few kits pb_rails("pb_kit"). React kits are used as the camelized tag.
      def usage(kit, system)
        pattern =
          if system == "rails"
            %Q{pb_rails\\([[:space:]]*["'](pb_)?#{kit}["'/]}
          else
            %Q{<#{camelize(kit)}[[:space:]/>]}
          end

        found = git_grep(pattern)
        found&.sort
      end

      # Returns nil rather than an empty list when the search could not run. The two are
      # opposite claims: no matches tells a tester there is nothing to open, which is the
      # conclusion this file exists to support, so asserting it on the strength of a
      # failed search is worse than saying nothing.
      def git_grep(pattern)
        stdout, stderr, status = Open3.capture3(
          "git", "grep", "--no-color", "-l", "-E", pattern, "--", *SEARCHED_EXTENSIONS,
          chdir: @workspace
        )
        # git grep exits 1 when nothing matched, which is not an error here.
        unless [0, 1].include?(status.exitstatus)
          record_failure("git grep exited #{status.exitstatus}: #{CommandOutput.utf8(stderr)}")
          return nil
        end

        CommandOutput.utf8(stdout).lines.map(&:chomp).reject(&:empty?)
      rescue => e
        record_failure("git grep could not be run: #{e.class}: #{e.message}")
        nil
      end

      # Annotated on the run rather than carried into the report: the reason comes from
      # git's stderr, which quotes paths out of the workspace, and the report is read by
      # the agent as evidence.
      def record_failure(detail)
        detail = detail.to_s.strip.lines.first.to_s.strip[0, 200].to_s
        return if @failures.include?(detail)

        @failures << detail
        puts("::warning::Playbook kit usage search failed: #{detail}")
      end

      def titled(kit)
        "## #{titleize(kit)} (`#{kit}`)"
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
