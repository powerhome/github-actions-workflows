# frozen_string_literal: true

require "erb"
require "json"
require "net/http"
require "uri"

# The one command a review agent may run: it reads what changed in another repository
# between two refs, such as a dependency's old and new pinned SHA, branch or tag. It only
# sends GET requests to the GitHub API and checks every argument before building a path,
# so nothing an agent passes it can write to GitHub or reach another host.
class Upstream
  class UsageError < StandardError; end
  class RequestError < StandardError; end

  USAGE = <<~TEXT
    usage: upstream compare OWNER/REPO BASE HEAD [PATH]   commits and changes from BASE to HEAD
           upstream show OWNER/REPO REF PATH              a file at REF
           upstream ls OWNER/REPO REF [PATH]              a directory at REF
    REF, BASE and HEAD can be a commit SHA, a branch or a tag. PATH limits compare to files under it.
  TEXT

  # Output past this is cut, so one large upstream change can't crowd out the review.
  MAX_OUTPUT = 60_000
  MAX_COMMITS = 100

  REPO = %r{\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}\z}
  REF = %r{\A[A-Za-z0-9._/+@-]{1,250}\z}

  def initialize(token: nil, api_url: "https://api.github.com", http: nil)
    @token = token.to_s.empty? ? nil : token
    @api_url = api_url.chomp("/")
    @http = http || method(:get)
  end

  def run(args)
    command, *rest = args
    text =
      case command
      when "compare" then compare(*arity(rest, 3, 4))
      when "show" then show(*arity(rest, 3, 3))
      when "ls" then ls(*arity(rest, 2, 3))
      else raise UsageError, USAGE
      end
    truncate(text)
  end

  def compare(repo, base, head, path = nil)
    data = request(
      "/repos/#{repo!(repo)}/compare/#{escape(ref!(base))}...#{escape(ref!(head))}?per_page=#{MAX_COMMITS}"
    )
    prefix = path && "#{path!(path)}/"
    files = Array(data["files"])
    files = files.select { |file| file["filename"] == path || file["filename"].start_with?(prefix) } if path

    lines = ["#{repo} #{base}...#{head}: #{data['status']}, #{data['ahead_by']} commit(s) ahead, " \
             "#{data['behind_by']} behind"]
    lines << "" << "Commits:"
    Array(data["commits"]).each do |commit|
      message = commit.dig("commit", "message").to_s.lines.first.to_s.strip
      lines << "  #{commit['sha'].to_s[0, 12]} #{message}"
    end
    lines << "" << "Files#{" under #{path}" if path} (#{files.size}):"
    files.each do |file|
      lines << "" << "--- #{file['filename']} (#{file['status']}, +#{file['additions']} -#{file['deletions']})"
      lines << (file["patch"] || "(no patch: binary or too large)")
    end
    lines.join("\n")
  end

  def show(repo, ref, path)
    data = request("/repos/#{repo!(repo)}/contents/#{path!(path)}?ref=#{escape(ref!(ref))}", raw: true)
    return data if data.is_a?(String)

    raise UsageError, "#{path} is a directory at #{ref}; use: upstream ls #{repo} #{ref} #{path}"
  end

  def ls(repo, ref, path = nil)
    data = request("/repos/#{repo!(repo)}/contents/#{path ? path!(path) : ''}?ref=#{escape(ref!(ref))}")
    raise UsageError, "#{path} is a file at #{ref}; use: upstream show #{repo} #{ref} #{path}" unless data.is_a?(Array)

    data.map { |entry| "#{entry['type'] == 'dir' ? 'dir ' : 'file'} #{entry['path']}" }.join("\n")
  end

private

  def arity(args, min, max)
    raise UsageError, USAGE unless args.length.between?(min, max)

    args
  end

  def repo!(repo)
    owner, name = repo.to_s.split("/", 2)
    raise UsageError, "not an OWNER/REPO: #{repo.inspect}" unless REPO.match?(repo.to_s) && !%w[. ..].include?(name)

    "#{owner}/#{name}"
  end

  # Slashes are allowed for branch names like feature/x, and escaped when the ref goes into
  # the URL, so a ref can never become extra path segments.
  def ref!(ref)
    valid = REF.match?(ref.to_s) && !ref.include?("..") && !ref.start_with?("/", "-") && !ref.end_with?("/")
    raise UsageError, "not a ref: #{ref.inspect}" unless valid

    ref
  end

  # Each segment is escaped on its own, and . or .. is refused, so a path stays inside the
  # contents endpoint.
  def path!(path)
    segments = path.to_s.delete_prefix("/").delete_suffix("/").split("/", -1)
    if segments.empty? || segments.any? { |s| s.empty? || %w[. ..].include?(s) || s.match?(/[[:cntrl:]]/) }
      raise UsageError, "not a repository path: #{path.inspect}"
    end

    segments.map { |segment| escape(segment) }.join("/")
  end

  def escape(text)
    ERB::Util.url_encode(text)
  end

  # The raw media type returns a file as it is, and a directory as its JSON listing, which the
  # content type tells apart even when the file is itself JSON.
  def request(path, raw: false)
    status, body, type = @http.call(URI("#{@api_url}#{path}"), raw:)
    raise RequestError, "not found, or not readable with this token" if status == 404
    raise RequestError, "GitHub API answered #{status}: #{error_message(body)}" unless status == 200
    return body if raw && type.to_s.include?("vnd.github.raw")

    JSON.parse(body)
  rescue JSON::ParserError
    raise RequestError, "unexpected response from the GitHub API"
  end

  def error_message(body)
    JSON.parse(body.to_s)["message"]
  rescue JSON::ParserError
    body.to_s[0, 200]
  end

  def get(uri, raw:)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = raw ? "application/vnd.github.raw+json" : "application/vnd.github+json"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = "nitro-agentic-pr-review-upstream"
    request["Authorization"] = "Bearer #{@token}" if @token
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10,
                                                       read_timeout: 30) do |http|
      http.request(request)
    end
    [response.code.to_i, response.body.to_s, response["content-type"]]
  end

  def truncate(text)
    text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    return text if text.bytesize <= MAX_OUTPUT

    cut = text.byteslice(0, MAX_OUTPUT).scrub("")
    "#{cut}\n[upstream: output cut at #{MAX_OUTPUT} bytes of #{text.bytesize}. " \
      "Narrow it with a PATH, or read single files with show.]"
  end
end
