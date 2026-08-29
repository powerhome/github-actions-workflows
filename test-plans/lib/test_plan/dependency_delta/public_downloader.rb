require "json"
require "net/http"
require "tempfile"
require "uri"

module TestPlan
  module DependencyDelta
    class PublicDownloader
      MAX_DOWNLOAD_BYTES = 50 * 1024 * 1024
      ALLOWED_HOSTS = %w[
        codeload.github.com
        raw.githubusercontent.com
        registry.npmjs.org
        rubygems.org
      ].freeze

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

      # The version document carries both dist -- which proves whether a lockfile entry
      # is this public package -- and repository, which says where its changelog lives.
      # One fetch serves both.
      def npm_version(name, version)
        encoded_name = URI.encode_www_form_component(name)
        metadata_url = "https://registry.npmjs.org/#{encoded_name}/#{URI.encode_www_form_component(version)}"
        Tempfile.create(["npm-metadata", ".json"]) do |metadata|
          download(metadata_url, metadata.path)
          JSON.parse(File.read(metadata.path, encoding: Encoding::UTF_8))
        end
      end

      def npm_dist(name, version)
        dist = npm_version(name, version)["dist"]
        raise "npm metadata did not include a tarball for #{name}@#{version}" if dist.to_h["tarball"].to_s.empty?

        dist
      end
    end
  end
end
