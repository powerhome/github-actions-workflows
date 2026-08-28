#!/usr/bin/env ruby

require "bundler"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "rubygems/package"
require "set"
require "tempfile"
require "tmpdir"
require "uri"
require "zlib"

DependencyChange = Struct.new(
  :ecosystem,
  :name,
  :old_version,
  :new_version,
  :source,
  :old_locator,
  :new_locator,
  :direct,
  :lockfiles,
  keyword_init: true
) do
  def key
    [ecosystem, name, old_version, new_version, source, old_locator, new_locator]
  end

  def to_h
    {
      "ecosystem" => ecosystem,
      "name" => name,
      "old_version" => old_version,
      "new_version" => new_version,
      "source" => source,
      "old_locator" => old_locator,
      "new_locator" => new_locator,
      "direct" => direct,
      "lockfiles" => lockfiles.sort,
    }
  end
end

class GitSnapshot
  def initialize(workspace:, base_sha:, head_sha:)
    @workspace = workspace
    @base_sha = base_sha
    @head_sha = head_sha
  end

  attr_reader :base_sha, :head_sha

  # pr.diff is a merge-base diff, so dependency evidence has to compare against the
  # merge base too. Reading the base tip instead would attribute changes made on the
  # base branch after the PR forked to the PR itself.
  def merge_base_sha
    @merge_base_sha ||= git("merge-base", base_sha, head_sha).strip
  end

  def changed_dependency_files
    stdout = git("diff", "--name-only", "#{merge_base_sha}..#{head_sha}")
    stdout.lines.map(&:strip).select do |path|
      path.end_with?("Gemfile.lock", "yarn.lock", "package.json")
    end
  end

  def paths_at(ref, suffix)
    git("ls-tree", "-r", "--name-only", ref).lines.map(&:strip).select do |path|
      path.end_with?(suffix)
    end
  end

  def read(ref, path)
    git("show", "#{ref}:#{path}")
  rescue RuntimeError
    nil
  end

private

  def git(*args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: @workspace)
    raise "git #{args.join(" ")} failed: #{stderr.strip}" unless status.success?

    stdout
  end
end

class BundlerChangeDetector
  def detect(path:, old_content:, new_content:, direct_names: Set.new)
    return [] unless old_content && new_content

    old_lock = Bundler::LockfileParser.new(old_content)
    new_lock = Bundler::LockfileParser.new(new_content)
    old_specs = external_specs(old_lock)
    new_specs = external_specs(new_lock)
    old_git_sources = git_sources(old_content)
    new_git_sources = git_sources(new_content)
    direct_names = direct_names | new_lock.dependencies.keys.to_set

    new_specs.filter_map do |name, new_spec|
      old_spec = old_specs[name]
      next unless old_spec

      build_change(
        path: path,
        name: name,
        old_spec: old_spec,
        new_spec: new_spec,
        old_git: old_git_sources[name],
        new_git: new_git_sources[name],
        direct: direct_names.include?(name)
      )
    end
  rescue Bundler::BundlerError, ArgumentError => e
    raise "Unable to parse #{path}: #{e.message}"
  end

private

  def external_specs(lock)
    lock.specs.each_with_object({}) do |spec, specs|
      next if spec.source.is_a?(Bundler::Source::Path) && !spec.source.is_a?(Bundler::Source::Git)

      current = specs[spec.name]
      specs[spec.name] = spec if current.nil? || spec.version > current.version
    end
  end

  def build_change(path:, name:, old_spec:, new_spec:, old_git:, new_git:, direct:)
    if new_git
      old_revision = old_git && old_git["revision"]
      new_revision = new_git["revision"]
      return if old_revision.to_s.empty? || new_revision.to_s.empty? || old_revision == new_revision

      return DependencyChange.new(
        ecosystem: "bundler",
        name: name,
        old_version: old_revision,
        new_version: new_revision,
        source: "git",
        old_locator: old_git["remote"],
        new_locator: new_git["remote"],
        direct: direct,
        lockfiles: [path]
      )
    end

    return unless new_spec.version > old_spec.version

    DependencyChange.new(
      ecosystem: "bundler",
      name: name,
      old_version: old_spec.version.to_s,
      new_version: new_spec.version.to_s,
      source: "rubygems",
      old_locator: rubygems_remote(old_spec.source),
      new_locator: rubygems_remote(new_spec.source),
      direct: direct,
      lockfiles: [path]
    )
  end

  def source_options(source)
    source.respond_to?(:options) ? source.options.transform_keys(&:to_s) : {}
  end

  def rubygems_remote(source)
    Array(source_options(source)["remotes"]).first.to_s
  end

  def git_sources(content)
    content.scan(/^GIT\n(.*?)(?=^[A-Z][A-Z ]*\n|\z)/m).each_with_object({}) do |(block), sources|
      remote = block[/^  remote:\s*(.+)$/, 1]
      revision = block[/^  revision:\s*(.+)$/, 1]
      specs = block.split(/^  specs:\s*$\n/, 2).last.to_s
      specs.scan(/^    ([^\s(]+) \(/).flatten.each do |name|
        sources[name] = { "remote" => remote, "revision" => revision }
      end
    end
  end
end

YarnRecord = Struct.new(:name, :version, :resolved, keyword_init: true)

class YarnLockParser
  def initialize(content)
    @content = content.to_s
  end

  def records
    output = []
    selectors = []
    version = nil
    resolved = nil

    flush = lambda do
      package_names(selectors).each do |name|
        output << YarnRecord.new(name: name, version: version, resolved: resolved) if version
      end
    end

    @content.each_line do |line|
      if !line.start_with?(" ", "#", "\n") && line.rstrip.end_with?(":")
        flush.call
        selectors = parse_selectors(line.rstrip.delete_suffix(":"))
        version = nil
        resolved = nil
      elsif (match = line.match(/^  version\s+"([^"]+)"/))
        version = match[1]
      elsif (match = line.match(/^  resolved\s+"([^"]+)"/))
        resolved = match[1]
      end
    end
    flush.call
    output
  end

private

  def parse_selectors(header)
    header.scan(/"([^"]+)"|([^,\s]+)/).map { |quoted, bare| quoted || bare }
  end

  def package_names(selectors)
    selectors.filter_map do |selector|
      if selector.start_with?("@")
        separator = selector.index("@", 1)
        selector[0...separator] if separator
      else
        selector.split("@", 2).first
      end
    end.uniq
  end
end

class YarnChangeDetector
  def detect(path:, old_content:, new_content:, direct_names:, workspace_names:)
    return [] unless old_content && new_content

    old_by_name = YarnLockParser.new(old_content).records.group_by(&:name)
    new_by_name = YarnLockParser.new(new_content).records.group_by(&:name)

    new_by_name.flat_map do |name, new_records|
      next [] if workspace_names.include?(name)

      old_records = old_by_name.fetch(name, [])
      version_changes(path, name, old_records, new_records, direct_names.include?(name)) +
        git_changes(path, name, old_records, new_records, direct_names.include?(name))
    end
  end

private

  def version_changes(path, name, old_records, new_records, direct)
    old_versions = old_records.map(&:version).uniq
    new_versions = new_records.map(&:version).uniq
    removed = old_versions - new_versions
    added = new_versions - old_versions

    added.filter_map do |new_version|
      old_version = removed.select { |candidate| version(candidate) < version(new_version) }.max_by { |candidate| version(candidate) }
      next unless old_version

      old_record = old_records.find { |record| record.version == old_version }
      new_record = new_records.find { |record| record.version == new_version }
      next if git_locator?(old_record&.resolved) || git_locator?(new_record&.resolved)

      DependencyChange.new(
        ecosystem: "yarn",
        name: name,
        old_version: old_version,
        new_version: new_version,
        source: "npm",
        old_locator: old_record&.resolved,
        new_locator: new_record&.resolved,
        direct: direct,
        lockfiles: [path]
      )
    rescue ArgumentError
      nil
    end
  end

  def git_changes(path, name, old_records, new_records, direct)
    old_git = old_records.select { |record| git_locator?(record.resolved) }
    new_git = new_records.select { |record| git_locator?(record.resolved) }

    pair_git_records(old_git, new_git).filter_map do |old_record, new_record|
      next if old_record.resolved == new_record.resolved

      DependencyChange.new(
        ecosystem: "yarn",
        name: name,
        old_version: git_revision(old_record.resolved),
        new_version: git_revision(new_record.resolved),
        source: "git",
        old_locator: old_record.resolved,
        new_locator: new_record.resolved,
        direct: direct,
        lockfiles: [path]
      )
    end
  end

  # A Git dependency can move revision with or without changing its declared version,
  # and version_changes deliberately ignores Git records. Match same-version records
  # first, then pair whatever is left in version order so a simultaneous version and
  # revision bump is still reported instead of dropped.
  def pair_git_records(old_git, new_git)
    remaining_old = old_git.dup
    pairs = []
    unmatched_new = []

    new_git.each do |new_record|
      index = remaining_old.index { |candidate| candidate.version == new_record.version }
      if index
        pairs << [remaining_old.delete_at(index), new_record]
      else
        unmatched_new << new_record
      end
    end

    leftover_old = remaining_old.sort_by { |record| record.version.to_s }
    unmatched_new.sort_by { |record| record.version.to_s }.each_with_index do |new_record, index|
      old_record = leftover_old[index]
      pairs << [old_record, new_record] if old_record
    end

    pairs
  end

  def version(value)
    normalized = value.to_s.sub(/\Av/, "").split("+", 2).first
    Gem::Version.new(normalized)
  end

  def git_locator?(value)
    value.to_s.match?(%r{(?:github\.com|git\+|\.git#)})
  end

  def git_revision(value)
    locator = value.to_s
    return locator.split("#", 2).last if locator.include?("#")

    # yarn v1 resolves `github:owner/repo#ref` to a codeload tarball URL whose last
    # path segment is the revision, with no fragment to split on.
    match = locator.match(%r{codeload\.github\.com/[^/]+/[^/]+/(?:tar\.gz|zip)/(.+)\z})
    match ? match[1] : locator
  end
end

class DependencyChangeDetector
  LockfileProblem = Struct.new(:path, :message, keyword_init: true) do
    def to_h
      { "lockfile" => path, "warning" => message }
    end
  end

  attr_reader :problems

  def initialize(snapshot)
    @snapshot = snapshot
    @problems = []
  end

  def detect
    changed = @snapshot.changed_dependency_files
    direct_names, workspace_names = package_names
    ruby_direct_names = ruby_dependency_names
    changes = []

    changed.grep(/Gemfile\.lock\z/).each do |path|
      changes.concat(
        detecting(path) do
          BundlerChangeDetector.new.detect(
            path: path,
            old_content: @snapshot.read(@snapshot.merge_base_sha, path),
            new_content: @snapshot.read(@snapshot.head_sha, path),
            direct_names: ruby_direct_names
          )
        end
      )
    end

    changed.grep(/yarn\.lock\z/).each do |path|
      changes.concat(
        detecting(path) do
          YarnChangeDetector.new.detect(
            path: path,
            old_content: @snapshot.read(@snapshot.merge_base_sha, path),
            new_content: @snapshot.read(@snapshot.head_sha, path),
            direct_names: direct_names,
            workspace_names: workspace_names
          )
        end
      )
    end

    deduplicate(changes)
  end

private

  # An unreadable lockfile costs us evidence for that file only. Recording it as a
  # warning keeps the rest of the delta, and the test plan itself, intact.
  def detecting(path)
    yield
  rescue => e
    @problems << LockfileProblem.new(path: path, message: e.message)
    []
  end

  def package_names
    direct = Set.new
    local = Set.new
    packages = []

    @snapshot.paths_at(@snapshot.head_sha, "package.json").each do |path|
      content = @snapshot.read(@snapshot.head_sha, path)
      next unless content

      package = JSON.parse(content)
      packages << [path, package] if package.is_a?(Hash)
    rescue JSON::ParserError
      next
    end

    workspace_patterns = packages.flat_map { |_path, package| workspace_patterns(package) }
    packages.each do |path, package|
      if package["name"] && (path.start_with?("components/") || workspace_path?(path, workspace_patterns))
        local << package["name"]
      end

      %w[dependencies devDependencies optionalDependencies peerDependencies].each do |field|
        requirements = package[field]
        next unless requirements.is_a?(Hash)

        requirements.each do |name, requirement|
          direct << name
          local << name if local_requirement?(requirement)
        end
      end
    end

    [direct, local]
  end

  def workspace_patterns(package)
    workspaces = package["workspaces"]
    case workspaces
    when Array
      workspaces
    when Hash
      Array(workspaces["packages"])
    else
      []
    end
  end

  def workspace_path?(package_json_path, patterns)
    package_directory = File.dirname(package_json_path)
    patterns.any? do |pattern|
      File.fnmatch?(pattern.to_s, package_directory, File::FNM_PATHNAME | File::FNM_EXTGLOB)
    end
  end

  def local_requirement?(requirement)
    requirement.to_s.match?(%r{\A(?:file|link|workspace):})
  end

  def ruby_dependency_names
    paths = @snapshot.paths_at(@snapshot.head_sha, "Gemfile") +
      @snapshot.paths_at(@snapshot.head_sha, ".gemspec")

    paths.each_with_object(Set.new) do |path, names|
      content = @snapshot.read(@snapshot.head_sha, path).to_s
      content.scan(/\bgem\s*(?:\()?\s*["']([^"']+)["']/).flatten.each { |name| names << name }
      content.scan(/\badd_(?:runtime_)?dependency\s*(?:\()?\s*["']([^"']+)["']/).flatten.each { |name| names << name }
    end
  end

  def deduplicate(changes)
    changes.each_with_object({}) do |change, unique|
      if (existing = unique[change.key])
        existing.direct ||= change.direct
        existing.lockfiles |= change.lockfiles
      else
        unique[change.key] = change
      end
    end.values
  end
end

class PublicDownloader
  MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024
  ALLOWED_HOSTS = %w[codeload.github.com registry.npmjs.org rubygems.org].freeze

  def download(url, destination, redirects: 3)
    raise "Too many redirects while downloading #{url}" if redirects.negative?

    uri = URI.parse(url)
    unless uri.is_a?(URI::HTTPS) && ALLOWED_HOSTS.include?(uri.host)
      raise "Public dependency URL is not allowlisted: #{url}"
    end

    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      http.request(request) do |response|
        case response
        when Net::HTTPSuccess
          bytes = 0
          File.open(destination, "wb") do |file|
            response.read_body do |chunk|
              bytes += chunk.bytesize
              raise "Dependency download exceeds 50 MiB: #{url}" if bytes > MAX_DOWNLOAD_BYTES

              file.write(chunk)
            end
          end
        when Net::HTTPRedirection
          return download(URI.join(uri, response.fetch("location")).to_s, destination, redirects: redirects - 1)
        else
          raise "Dependency download failed (#{response.code}): #{url}"
        end
      end
    end
    destination
  end

  def npm_tarball(name, version)
    encoded_name = URI.encode_www_form_component(name)
    metadata_url = "https://registry.npmjs.org/#{encoded_name}/#{URI.encode_www_form_component(version)}"
    Tempfile.create(["npm-metadata", ".json"]) do |metadata|
      download(metadata_url, metadata.path)
      payload = JSON.parse(File.read(metadata.path, encoding: Encoding::UTF_8))
      tarball = payload.dig("dist", "tarball")
      raise "npm metadata did not include a tarball for #{name}@#{version}" if tarball.to_s.empty?

      tarball
    end
  end
end

class SafeTarExtractor
  MAX_EXTRACTED_BYTES = 100 * 1024 * 1024
  MAX_FILES = 20_000

  def extract_gzip(path, destination)
    Zlib::GzipReader.open(path) do |gzip|
      Gem::Package::TarReader.new(gzip) { |tar| extract_entries(tar, destination) }
    end
  end

  def extract_gem(path, destination)
    Tempfile.create(["gem-data", ".tar.gz"]) do |data_archive|
      File.open(path, "rb") do |gem_file|
        Gem::Package::TarReader.new(gem_file) do |tar|
          entry = tar.find { |candidate| candidate.full_name == "data.tar.gz" }
          raise "Gem archive does not contain data.tar.gz" unless entry
          raise "Gem data archive exceeds 50 MiB" if entry.header.size > PublicDownloader::MAX_DOWNLOAD_BYTES

          data_archive.write(entry.read)
          data_archive.flush
        end
      end
      extract_gzip(data_archive.path, destination)
    end
  end

private

  def extract_entries(tar, destination)
    total_bytes = 0
    files = 0
    root = File.expand_path(destination)

    tar.each do |entry|
      relative = safe_relative_path(entry.full_name)
      next if relative == "."

      target = File.expand_path(relative, root)
      raise "Archive entry escapes extraction root: #{entry.full_name}" unless target.start_with?("#{root}#{File::SEPARATOR}")

      if entry.directory?
        FileUtils.mkdir_p(target)
      elsif entry.file?
        files += 1
        total_bytes += entry.header.size
        raise "Archive contains more than #{MAX_FILES} files" if files > MAX_FILES
        raise "Archive expands beyond 100 MiB" if total_bytes > MAX_EXTRACTED_BYTES

        FileUtils.mkdir_p(File.dirname(target))
        File.open(target, "wb") { |file| IO.copy_stream(entry, file) }
      else
        raise "Archive contains unsupported link or device entry: #{entry.full_name}"
      end
    end
  end

  def safe_relative_path(value)
    path = Pathname.new(value)
    clean = path.cleanpath.to_s
    if path.absolute? || clean == ".." || clean.start_with?("../")
      raise "Unsafe archive path: #{value}"
    end

    clean
  end
end

class SourceDiffBuilder
  CHANGELOG_PATTERN = %r{(?:^|/)(?:change(?:log|s)?|history|release(?:s|_notes)?|upgrade(?:_guide)?)(?:\.|/|$)}i
  TEST_PATTERN = %r{(?:^|/)(?:test|tests|spec|specs|__tests__)(?:/|$)}i
  DOC_PATTERN = %r{(?:^|/)(?:docs?|readme)(?:\.|/|$)}i
  GENERATED_PATTERN = %r{(?:^|/)(?:vendor|dist|build|coverage|node_modules)(?:/|$)|(?:\.min\.|\.map\z)}i

  def build(old_root, new_root)
    paths = (files(old_root) | files(new_root)).sort_by { |path| [priority(path), path] }
    paths.filter_map do |path|
      old_path = File.join(old_root, path)
      new_path = File.join(new_root, path)
      next if same_file?(old_path, new_path)
      next if binary?(old_path) || binary?(new_path)

      unified_diff(path, old_path, new_path)
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

  def priority(path)
    return 0 if path.match?(CHANGELOG_PATTERN)
    return 2 if path.match?(TEST_PATTERN)
    return 3 if path.match?(DOC_PATTERN)
    return 4 if path.match?(GENERATED_PATTERN)

    1
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

    stdout.empty? ? nil : stdout
  end
end

class PublicDependencyRetriever
  def initialize(downloader: PublicDownloader.new, extractor: SafeTarExtractor.new)
    @downloader = downloader
    @extractor = extractor
  end

  def retrieve(change)
    Dir.mktmpdir("test-plan-dependency") do |directory|
      old_root = File.join(directory, "old")
      new_root = File.join(directory, "new")
      FileUtils.mkdir_p([old_root, new_root])

      case change.source
      when "rubygems"
        retrieve_gems(change, directory, old_root, new_root)
      when "npm"
        retrieve_npm(change, directory, old_root, new_root)
      when "git"
        retrieve_git(change, directory, old_root, new_root)
      else
        raise "Unsupported public dependency source: #{change.source}"
      end

      SourceDiffBuilder.new.build(content_root(old_root), content_root(new_root))
    end
  end

private

  def retrieve_gems(change, directory, old_root, new_root)
    old_archive = File.join(directory, "old.gem")
    new_archive = File.join(directory, "new.gem")
    @downloader.download(rubygem_url(change.name, change.old_version), old_archive)
    @downloader.download(rubygem_url(change.name, change.new_version), new_archive)
    @extractor.extract_gem(old_archive, old_root)
    @extractor.extract_gem(new_archive, new_root)
  end

  def retrieve_npm(change, directory, old_root, new_root)
    old_archive = File.join(directory, "old.tgz")
    new_archive = File.join(directory, "new.tgz")
    @downloader.download(@downloader.npm_tarball(change.name, change.old_version), old_archive)
    @downloader.download(@downloader.npm_tarball(change.name, change.new_version), new_archive)
    @extractor.extract_gzip(old_archive, old_root)
    @extractor.extract_gzip(new_archive, new_root)
  end

  def retrieve_git(change, directory, old_root, new_root)
    repository = github_repository(change.new_locator) || github_repository(change.old_locator)
    raise "Git dependency is not a public GitHub repository" unless repository

    old_archive = File.join(directory, "old.tgz")
    new_archive = File.join(directory, "new.tgz")
    @downloader.download(github_archive_url(repository, change.old_version), old_archive)
    @downloader.download(github_archive_url(repository, change.new_version), new_archive)
    @extractor.extract_gzip(old_archive, old_root)
    @extractor.extract_gzip(new_archive, new_root)
  end

  def rubygem_url(name, version)
    "https://rubygems.org/downloads/#{URI.encode_www_form_component(name)}-#{URI.encode_www_form_component(version)}.gem"
  end

  def github_repository(locator)
    value = locator.to_s
    codeload = value.match(%r{codeload\.github\.com/([^/]+)/([^/]+)/(?:tar\.gz|zip)/})
    return "#{codeload[1]}/#{codeload[2]}" if codeload

    match = value.match(%r{github\.com[:/]([^/]+)/([^/#]+?)(?:\.git)?(?:#|\z)})
    match && "#{match[1]}/#{match[2]}"
  end

  def github_archive_url(repository, revision)
    "https://codeload.github.com/#{repository}/tar.gz/#{URI.encode_www_form_component(revision)}"
  end

  def content_root(root)
    entries = Dir.children(root)
    return root unless entries.length == 1

    candidate = File.join(root, entries.first)
    File.directory?(candidate) ? candidate : root
  end
end

class DependencyDeltaGenerator
  FULL_LIMIT = 10 * 1024 * 1024
  CONTEXT_PER_DEPENDENCY_LIMIT = 100 * 1024
  CONTEXT_TOTAL_LIMIT = 500 * 1024

  def initialize(changes:, retriever: PublicDependencyRetriever.new, problems: [])
    @changes = changes.sort_by { |change| [change.direct ? 0 : 1, change.source == "git" ? 0 : 1, change.name] }
    @retriever = retriever
    @problems = problems
  end

  def generate
    full = +""
    context = +""
    entries = []

    @changes.each do |change|
      entry = change.to_h
      begin
        chunks = @retriever.retrieve(change)
        entry["status"] = "retrieved"
        entry["changed_files"] = chunks.length
        entry["warnings"] = []
        header = dependency_header(change)
        full_truncated = append_chunks(full, header, chunks, FULL_LIMIT)
        dependency_context = +""
        dependency_truncated = append_chunks(
          dependency_context,
          header,
          chunks,
          CONTEXT_PER_DEPENDENCY_LIMIT
        )
        total_truncated = append_text(context, dependency_context, CONTEXT_TOTAL_LIMIT)
        if full_truncated || dependency_truncated || total_truncated
          entry["status"] = "truncated"
          entry["warnings"] << "The dependency delta exceeded a configured context or artifact limit."
        end
      rescue => e
        entry["status"] = "unavailable"
        entry["changed_files"] = 0
        entry["warnings"] = [e.message]
      end
      entries << entry
    end

    lockfile_warnings = @problems.map(&:to_h)

    {
      manifest: {
        "version" => 1,
        "dependencies" => entries,
        "lockfile_warnings" => lockfile_warnings,
        "warning_count" => entries.count { |entry| entry.fetch("status") != "retrieved" } +
          lockfile_warnings.length,
      },
      full: full,
      context: context,
    }
  end

private

  def dependency_header(change)
    "\n## #{change.ecosystem}: #{change.name} (#{change.old_version} -> #{change.new_version})\n\n"
  end

  def append_chunks(target, header, chunks, limit)
    truncated = false
    return true if target.bytesize + header.bytesize > limit

    target << header
    chunks.each do |chunk|
      if target.bytesize + chunk.bytesize > limit
        truncated = true
        next
      end
      target << chunk << "\n"
    end
    truncated
  end

  def append_text(target, text, limit)
    return true if target.bytesize + text.bytesize > limit

    target << text
    false
  end
end

class DependencyDeltaCommand
  WARNING_MESSAGE = "Some external dependency evidence could not be collected completely; see the workflow run and dependency manifest."

  def run
    workspace = ENV.fetch("GITHUB_WORKSPACE")
    snapshot = GitSnapshot.new(
      workspace: workspace,
      base_sha: ENV.fetch("BASE_SHA"),
      head_sha: ENV.fetch("HEAD_SHA")
    )
    detector = DependencyChangeDetector.new(snapshot)
    changes = detector.detect
    result = DependencyDeltaGenerator.new(changes: changes, problems: detector.problems).generate

    manifest_path = ENV.fetch("DEPENDENCY_DELTA_MANIFEST_PATH")
    full_path = ENV.fetch("DEPENDENCY_DELTA_FULL_PATH")
    context_path = ENV.fetch("DEPENDENCY_DELTA_CONTEXT_PATH")
    File.write(manifest_path, JSON.pretty_generate(result.fetch(:manifest)) + "\n")
    File.write(full_path, result.fetch(:full))
    File.write(context_path, result.fetch(:context))

    warning_count = result.dig(:manifest, "warning_count")
    write_outputs(changes.length, warning_count)
    write_summary(result.fetch(:manifest))
    puts("::warning::#{WARNING_MESSAGE}") if warning_count.positive?
  end

private

  def write_outputs(change_count, warning_count)
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a", encoding: Encoding::UTF_8) do |output|
      output.puts("change_count=#{change_count}")
      output.puts("warning_count=#{warning_count}")
      output.puts("generation_warning=#{warning_count.positive? ? WARNING_MESSAGE : ""}")
    end
  end

  def write_summary(manifest)
    summary_path = ENV["GITHUB_STEP_SUMMARY"]
    return if summary_path.to_s.empty?

    dependencies = manifest.fetch("dependencies")
    lockfile_warnings = manifest.fetch("lockfile_warnings")
    File.open(summary_path, "a", encoding: Encoding::UTF_8) do |summary|
      summary.puts("## External dependency delta")
      if dependencies.empty?
        summary.puts("No raised external Bundler or Yarn dependencies were detected.")
      else
        dependencies.each do |entry|
          summary.puts("- `#{entry.fetch("name")}`: #{entry.fetch("old_version")} -> #{entry.fetch("new_version")} (#{entry.fetch("status")})")
          entry.fetch("warnings").each { |warning| summary.puts("  - #{warning}") }
        end
      end

      lockfile_warnings.each do |warning|
        summary.puts("- `#{warning.fetch("lockfile")}`: not analyzed")
        summary.puts("  - #{warning.fetch("warning")}")
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    DependencyDeltaCommand.new.run
  rescue KeyError => e
    warn "Missing required environment variable: #{e.message}"
    exit 1
  rescue => e
    warn "Dependency delta generation failed: #{e.message}"
    exit 1
  end
end
