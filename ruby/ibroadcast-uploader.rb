#!/usr/bin/ruby

## This script requires the multipart-post gem

require 'net/http'
require 'net/http/post/multipart'
require 'cgi'
require 'json'
require 'rqrcode'
require 'stringio'
require 'time'
require 'mime-types'

class OAuthError < StandardError
  attr_reader :code

  def initialize(code, message)
    super(message)
    @code = code
  end
end


class IBroadcastUploader

  def initialize()
    @TOKEN_FILE = File.join(File.dirname(__FILE__), 'ibroadcast-uploader.json')
    @VERSION = "0.3"
    @CLIENT = 'ruby uploader script'
    @USER_AGENT = "#{@CLIENT} #{@VERSION}"
    @DEVICE_NAME = @CLIENT
    @CLIENT_ID = "de4ce836a9fb11f0bc7fb49691aa2236"
  end

  def load_token()
    token = nil
    begin
      data = JSON.parse(File.read(@TOKEN_FILE))
      token = data['token']
    rescue
      # Do nothing
    end

    return token
  end

  def save_token(token)
    begin
      File.open(@TOKEN_FILE, 'w') do |f|
        f.write(JSON.dump({ token: token }))
      end
    rescue => e
      puts "Warning, unable to save token to ibroadcast-uploader.json: #{e.message}"
    end
  end

  def login(token)
    device_code = nil

    token = refresh_token_if_necessary(token)

    while token.nil?
      if device_code.nil?
        begin
          device_code = oauth_device_code
          device_code['expires_at'] = Time.now.to_i + device_code['expires_in']

          # Generate QR Code
          qrcode = RQRCode::QRCode.new(device_code['verification_uri_complete'])
          qrcode.as_ansi.each_line { |line| puts line }

          puts "\nTo authorize, scan the QR code or enter code #{device_code['user_code']} at: #{device_code['verification_uri']}"
          puts "\nWaiting for authorization..."

        rescue => e
          puts "Unable to get device code: #{e.message}"
          return nil
        end
      end

      if device_code['expires_at'] <= Time.now.to_i
        puts 'Device code timed out!'
        device_code = nil
        next
      end

      begin
        token = oauth_token(device_code['device_code'])
        token['expires_at'] = Time.now.to_i + token['expires_in']
      rescue OAuthError => e
        if e.code == 'authorization_pending'
          sleep device_code['interval']
          next
        end

        puts "Authorization error: #{e.message}"
        return nil
      end

      break
    end

    token
  end

  def oauth_device_code
    puts 'Getting device code...'

    uri = URI('https://oauth.ibroadcast.com/device/code')
    uri.query = URI.encode_www_form({
      client_id: @CLIENT_ID,
      scope: 'user.account:read user.upload'
    })

    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = @USER_AGENT

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    json = JSON.parse(res.body)

    raise OAuthError.new(json['error'], json['error_description']) unless res.is_a?(Net::HTTPSuccess)

    json
  end

  def oauth_token(code)
    uri = URI('https://oauth.ibroadcast.com/token')

    req = Net::HTTP::Post.new(uri)
    req.set_form_data({
      client_id: @CLIENT_ID,
      grant_type: 'device_code',
      device_code: code
    })
    req['User-Agent'] = @USER_AGENT

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    json = JSON.parse(res.body)

    raise OAuthError.new(json['error'], json['error_description']) unless res.is_a?(Net::HTTPSuccess)

    json
  end

  def refresh_token(refresh_token)
    puts 'Refreshing token...'

    uri = URI('https://oauth.ibroadcast.com/token')

    req = Net::HTTP::Post.new(uri)
    req.set_form_data({
      client_id: @CLIENT_ID,
      grant_type: 'refresh_token',
      refresh_token: refresh_token
    })
    req['User-Agent'] = @USER_AGENT

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    json = JSON.parse(res.body)

    raise OAuthError.new(json['error'], json['error_description']) unless res.is_a?(Net::HTTPSuccess)

    json
  end

  def refresh_token_if_necessary(token)
    return nil if token.nil?

    if token['expires_at'] <= Time.now.to_i
      begin
        token = refresh_token(token['refresh_token'])
        token['expires_at'] = Time.now.to_i + token['expires_in']
        save_token(token)
      rescue OAuthError => e
        puts "Authorization error, please log in again: #{e.message}"
        token = nil
      end
    end

    return token
  end

  ## performs a login request, gets user id, access token and supported formats
  def get_supported_types(token)
    body = {
      'mode' => 'status',
      'supported_types' => 1,
      'version' => @VERSION,
      'client' => @CLIENT,
      'device_name' => @DEVICE_NAME,
      'user_agent' => @USER_AGENT
    }

    ## Create the client and perform the initial request
    uri = URI("https://api.ibroadcast.com/s/JSON/" + body['mode'])
    req = Net::HTTP::Post.new(uri.path)
    
    req.body = body.to_json

    req['Authorization'] = "#{token['token_type']} #{token['access_token']}"
    req['User-Agent'] = @USER_AGENT
    req['Content-Type'] = "application/json"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    ## Parse the resulting json
    @login_data = JSON.parse(response.body)

    unless @login_data['user'] && @login_data['user']['id']
      raise StandardError.new @login_data['message']
    end

  end


  ## prompts for user action and initiates upload
  def upload(token)
    puts "Fetching account info..."

    get_supported_types(token)

    ## Create an array of supported extensions
    @supported = @login_data['supported'].map { |e| e['extension']}

    puts "Searching for files..."

    ## Get files from cwd
    files = list_files(Dir.pwd)

    if confirm(files)
      upload_files(files, token)
    end
  end

  private

  ## returns an array of absolute file paths of supported file formats in the given directory
  def list_files(dir)
    files = []

    Dir.foreach(dir) do |entry|
      ## skip hidden
      next if entry =~ /^\./

      ## get full path
      path = File.join(dir, entry)

      if File.directory? path ## if this is a directory
        files += list_files(path) ## recursively add subdirectories
      elsif @supported.include? File.extname(path) ## if file has a supported extension
        files << path
      end
    end

    return files
  end

  ## prompts for input - list files and/or upload
  ## returns true if user gives ok to upload
  def confirm(files)
    puts "Found #{files.count} files. Press 'L' to list, or 'U' to start the upload."
    input = $stdin.gets

    if input.upcase.start_with? 'L'
      ## print list of files found
      puts "\nListing found, supported files"
      files.each { |path| puts " - " + path}

      puts "Press 'U' to start the upload if this looks reasonable."

      input2 = $stdin.gets
      if input2.upcase.start_with? 'U'
        puts "Starting upload"
        return true
      else
        puts "aborted."
        return false
      end

    elsif input.upcase.start_with? 'U'
      puts "Starting upload"
      return true
    else
      puts "aborted."
      return false
    end
  end

  ## returns an array of MD5 sums of present files in hex form
  def get_md5(token)
    ## Create the client and perform the initial request
    uri = URI("https://upload.ibroadcast.com/")
    req = Net::HTTP::Post.new(uri.path)
    
    req['Authorization'] = "#{token['token_type']} #{token['access_token']}"
    req['User-Agent'] = @USER_AGENT

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    ## Parse and return response
    JSON.parse(response.body)['md5']
  end

  def upload_files(files, token)
    md5 = get_md5(token)

    files.each do |file|
      digest = Digest::MD5.hexdigest(File.read(file))

      ## create http client
      uri = URI("https://upload.ibroadcast.com/")

      puts "Uploading: #{file}"
      if !md5.include?(digest) ## check against uploaded md5 list

        ## not in uploaded md5 list, post file to server
        headers = {}
        headers['Authorization'] = "#{token['token_type']} #{token['access_token']}"
        headers['User-Agent'] = @USER_AGENT

        request = Net::HTTP::Post::Multipart.new(uri.path, {
          'method' => 'ruby uploader',
          'file_path' => file,
          'file' => UploadIO.new(File.new(file), MIME::Types.type_for(File.basename(file)).first.to_s, filename = File.basename(file))
        }, headers)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end

        if response.code == '401'
          token = refresh_token_if_necessary(token)
          response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
        end

        if response.code == '200'
          puts " Done!"
        else
          puts " Failed."
        end

      else
        puts " skipping, already uploaded"
      end
    end
  end
end

begin
  uploader = IBroadcastUploader.new() ## create uploader with email and password

  token = uploader.load_token()
  token = uploader.login(token)
  uploader.save_token(token)
  uploader.upload(token)
rescue Exception => e
  puts e.message
end
