require 'yaml'
require 'curb'
require 'json'
require_relative 'sony_ci_basic'

class SonyCiAdmin < SonyCiBasic
  include Enumerable

  # Upload a document to Ci. Underlying API treats large and small files
  # differently, but this should treat both alike.
  def upload(file_path, log_file)
    Uploader.new(self, file_path, log_file).upload
  end

  # Just the names of items in the workspace. This may include directories.
  def list_names
    list.map { |item| item['name'] } - ['Workspace']
    # A self reference is present even in an empty workspace.
  end

  # Full metadata for a windowed set of items.
  def list(limit = 50, offset = 0)
    Lister.new(self).list(limit, offset)
  end

  # Iterate over all items.
  def each
    Lister.new(self).each { |asset| yield asset }
  end

  # Delete items by asset ID.
  def delete(asset_id)
    Deleter.new(self).delete(asset_id)
  end

  # Get detailed metadata by asset ID.
  def detail(asset_id)
    Detailer.new(self).detail(asset_id)
  end

  def multi_details(asset_ids, fields)
    Detailer.new(self).multi_details(asset_ids, fields)
  end

  class Detailer < SonyCiClient #:nodoc:
    def initialize(ci)
      @ci = ci
    end

    def detail(asset_id)
      curl = Curl::Easy.http_get('https:'"//api.cimediacloud.com/assets/#{asset_id}") do |c|
        add_headers(c)
      end
      handle_errors(curl)
      JSON.parse(curl.body_str)
    end

    def multi_details(asset_ids, fields)
      curl = Curl::Easy.http_post('https:''//api.cimediacloud.com/assets/details/bulk',
                                  JSON.generate('assetIds' => asset_ids,
                                                'fields' => fields)
                                 ) do |c|
        add_headers(c, 'application/json')
      end
      handle_errors(curl)
      JSON.parse(curl.body_str)
    end
  end

  class Deleter < SonyCiClient #:nodoc:
    def initialize(ci)
      @ci = ci
    end

    def delete(asset_id)
      curl = Curl::Easy.http_delete('https:'"//api.cimediacloud.com/assets/#{asset_id}") do |c|
        add_headers(c)
      end
      handle_errors(curl)
    end
  end

  class Lister < SonyCiClient #:nodoc:
    include Enumerable

    def initialize(ci)
      @ci = ci
    end

    def list(limit, offset)
      curl = Curl::Easy.http_get('https:''//api.cimediacloud.com/workspaces/' \
                                 "#{@ci.workspace_id}/contents?limit=#{limit}&offset=#{offset}") do |c|
        add_headers(c)
      end
      handle_errors(curl)
      JSON.parse(curl.body_str)['items']
    end

    def each
      limit = 5 # Small chunks so it's easy to spot windowing problems
      offset = 0
      loop do
        assets = list(limit, offset)
        break if assets.empty?
        assets.each { |asset| yield asset }
        offset += limit
      end
    end
  end

  class Uploader < SonyCiClient #:nodoc:
    def initialize(ci, path, log_path)
      @ci = ci
      @path = path
      @log_file = File.open(log_path, 'a')
    end

    def upload
      file = File.new(@path)
      if file.size >= 5 * 1024 * 1024
        initiate_multipart_upload(file)
        part = 0
        part = do_multipart_upload_part(file, part) while part
        complete_multipart_upload
      else
        singlepart_upload(file)
      end

      row = [Time.now, File.basename(@path), @asset_id,
             @ci.detail(@asset_id).to_s.gsub("\n", ' ')]
      @log_file.write(row.join("\t") + "\n")
      @log_file.flush

      @asset_id
    end

    private

    SINGLEPART_URI = 'https://io.cimediacloud.com/upload'
    MULTIPART_URI = 'https://io.cimediacloud.com/upload/multipart'

    def singlepart_upload(file)
      params = [
        Curl::PostField.file('filename', file.path, File.basename(file.path)),
        Curl::PostField.content('metadata', JSON.generate('workspaceId' => @ci.workspace_id))
      ]
      curl = Curl::Easy.http_post(SINGLEPART_URI, params) do |c|
        c.multipart_form_post = true
        add_headers(c)
      end
      handle_errors(curl)
      @asset_id = JSON.parse(curl.body_str)['assetId']
    end

    def initiate_multipart_upload(file)
      params = JSON.generate('name' => File.basename(file),
                             'size' => file.size,
                             'workspaceId' => @ci.workspace_id)
      curl = Curl::Easy.http_post(MULTIPART_URI, params) do |c|
        add_headers(c, 'application/json')
      end
      handle_errors(curl)
      @asset_id = JSON.parse(curl.body_str)['assetId']
    end

    CHUNK_SIZE = 10 * 1024 * 1024

    def do_multipart_upload_part(file, part)
      fragment = file.read(CHUNK_SIZE)
      return unless fragment
      curl = Curl::Easy.http_put("#{MULTIPART_URI}/#{@asset_id}/#{part + 1}", fragment) do |c|
        add_headers(c, 'application/octet-stream')
      end
      handle_errors(curl)
      part + 1
    end

    def complete_multipart_upload
      curl = Curl::Easy.http_post("#{MULTIPART_URI}/#{@asset_id}/complete") do |c|
        add_headers(c)
      end
      handle_errors(curl)
    end
  end
end
