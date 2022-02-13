require "json"
require "colorize"

module SecTester
  class Scan
    BASE_URL = ENV["NEXPLOIT_URL"]? || "https://app.neuralegion.com"

    getter repeater : String

    @scan_id : String?
    @running : Bool = false
    @issues : Array(String) = Array(String).new

    def initialize(@token : String)
      @repeater = create_repeater
    end

    private def get_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["Authorization"] = "Api-Key #{@token}"
      headers["Content-Type"] = "application/json"
      headers["Accept"] = "application/json"
      headers["Host"] = URI.parse(BASE_URL).host.to_s

      Log.debug { "Setting headers: #{headers}" }

      headers
    end

    def start(scan_name : String, tests : String | Array(String)?, target : Target) : String
      new_scan_url = "#{BASE_URL}/api/v1/scans"

      file_id = upload_archive(target)

      # The API supports only Nil or Array(String) so we normalize the input
      tests = [tests] if tests.is_a?(String)

      body = {
        "name":                 scan_name,
        "module":               "dast",
        "tests":                tests,
        "fileId":               file_id,
        "repeaters":            [@repeater],
        "attackParamLocations": ["body", "query", "fragment"],
        "discoveryTypes":       ["archive"],
      }.to_json

      Log.debug { "Sending body request: #{body}" }

      response = send_with_retry(method: "POST", url: new_scan_url, body: body)
      raise SecTester::Error.new("Error starting scan: #{response.body.to_s}") unless response.status.success?
      @scan_id = JSON.parse(response.body.to_s)["id"].to_s
    end

    def poll(on_issue : Bool = false, timeout : Time::Span? = nil, interval : Time::Span = 30.seconds)
      raise SecTester::Error.new("Cannot poll scan results without scan_id, make sure to 'start' the scan before polling") unless @scan_id

      time_started = Time.monotonic

      loop do
        sleep interval

        Log.debug { "Polling scan #{@scan_id} - passed #{Time.monotonic - time_started}" }
        response = poll_call
        response_json = JSON.parse(response.body.to_s)

        if on_issue
          if response_json["issuesLength"].as_i > 0
            Log.warn { "Scan has #{response_json["issuesLength"]} issues, stop polling".colorize.red }
            stop
            get_issues.each do |issue|
              message = String.build do |str|
                str << "\n"
                str << "Name: ".colorize.cyan.bold
                str << issue["name"].colorize.white.bold
                str << "\n"
                str << "Severity: ".colorize.cyan.bold
                str << color_severity(issue["severity"].as_s)
                str << "\n"
                str << "Remediation: ".colorize.cyan.bold
                str << issue["remedy"].to_s.gsub("\n", " ").colorize.white.bold
                str << "\n"
                str << "Details: ".colorize.cyan.bold
                str << issue["details"].to_s.gsub("\n", " ").colorize.white.bold
                str << "\n"
                str << "Extra Details: ".colorize.cyan.bold
                issue["comments"].as_a.each do |comment|
                  str << comment.to_s.gsub("\n", " ").colorize.white.bold
                  str << "\n"
                end
                str << "\n"
                str << "Link to Issue: ".colorize.cyan.bold
                str << "#{BASE_URL}/scans/#{@scan_id}/issues/#{issue["id"]}".colorize.blue.bold
                str << "\n"
                str << "External Resources: ".colorize.cyan.bold
                str << issue["resources"].as_a.join(", ").colorize.blue.bold
                str << "\n"
              end
              Log.warn { message }
              raise IssueFound.new(message)
            end
          end
        end

        if (response_json["status"] == "done")
          Log.info { "Scan done, stop polling".colorize.green }
          stop
          break
        end

        if timeout
          if (Time.monotonic - time_started) > timeout
            Log.warn { "Scan timed out, stop polling".colorize.yellow }
            stop
          end
        end
      end
    end

    def stop
      raise SecTester::Error.new("Cannot stop scan without scan_id, make sure to 'start' the scan before stopping") unless @scan_id
      stop_url = "#{BASE_URL}/api/v1/scans/#{@scan_id}/stop"

      Log.debug { "Stopping scan #{@scan_id}" }
      headers = get_headers
      # Stop Scan
      send_with_retry(method: "GET", url: stop_url)
      # Remove Repeater
      remove_repeater
    end

    private def color_severity(severity : String)
      case severity.downcase
      when "low"
        severity.colorize.blue.bold
      when "medium"
        severity.colorize.yellow.bold
      when "high"
        severity.colorize.red.bold
      else
        severity
      end
    end

    private def upload_archive(target : Target, discard : Bool = true) : String # this returns an archive ID
      archive_url = "#{BASE_URL}/api/v1/files?discard=#{discard}"

      headers = get_headers
      body_io = IO::Memory.new
      file_io = IO::Memory.new(target.to_har)
      multipart_headers = HTTP::Headers.new
      multipart_headers["Content-Type"] = "application/har+json"
      HTTP::FormData.build(body_io, MIME::Multipart.generate_boundary) do |builder|
        builder.file(
          "file",
          file_io,
          HTTP::FormData::FileMetadata.new(filename: "#{Random::Secure.hex}.har"),
          multipart_headers
        )
        headers["Content-Type"] = builder.content_type
      end

      response = send_with_retry(method: "POST", url: archive_url, headers: headers, body: body_io.to_s)

      Log.debug { "Uploaded archive to #{BASE_URL}/api/v1/files?discard=#{discard} response: #{response.body.to_s}" }
      JSON.parse(response.body.to_s)["id"].to_s
    end

    # Auto generate repeater for the scan
    private def create_repeater : String
      repeater_url = "#{BASE_URL}/api/v1/repeaters"
      repeater_name = Random::Secure.hex

      body = {
        "active":      true,
        "description": "Auto generated repeater",
        "name":        repeater_name,
      }.to_json

      # Create a repeater
      send_with_retry(method: "POST", url: repeater_url, body: body)

      # Fetch repeater ID by name
      response = send_with_retry(method: "GET", url: repeater_url)
      repeater_id = JSON.parse(response.body.to_s).as_a.find { |repeater| repeater["name"] == repeater_name }.try &.["id"].to_s
      raise SecTester::Error.new("Error creating repeater: #{response.body.to_s}") unless repeater_id
      repeater_id
    end

    private def remove_repeater
      repeater_url = "#{BASE_URL}/api/v1/repeaters/#{@repeater}"

      send_with_retry(method: "DELETE", url: repeater_url)
    end

    private def get_issues : Array(JSON::Any)
      issues_url = "#{BASE_URL}/api/v1/scans/#{@scan_id}/issues"

      response = send_with_retry("GET", issues_url)
      JSON.parse(response.body.to_s).as_a
    end

    private def poll_call : HTTP::Client::Response
      poll_url = "#{BASE_URL}/api/v1/scans/#{@scan_id}"

      send_with_retry("GET", poll_url)
    end

    private def send_with_retry(method : String, url : String, headers : HTTP::Headers = get_headers, body : HTTP::Client::BodyType = nil) : HTTP::Client::Response
      response = HTTP::Client.exec(
        method: method,
        url: url,
        headers: headers,
        body: body
      )

      5.times do
        if response.status_code >= 500
          Log.error { "Retrying #{method} #{url} - #{response.status_code} - #{response.body.to_s}" }
          sleep 5
          response = HTTP::Client.exec(
            method: method,
            url: url,
            headers: headers,
            body: body
          )
        else
          break
        end
      end

      response
    end
  end
end
