require "fileutils"
require "json"
require "securerandom"
require "sinatra/base"
require "time"
require "zip"

module ImageOptimizer
  ROOT = File.expand_path("..", __dir__)
  PROJECT_ROOT = File.expand_path("../..", __dir__)
  DATA_DIR = File.join(ROOT, "storage")
  JOBS_DIR = File.join(DATA_DIR, "jobs")
  UPLOADS_DIR = File.join(DATA_DIR, "uploads")
  OUTPUTS_DIR = File.join(DATA_DIR, "outputs")
  NATIVE_EXE = ENV.fetch(
    "IMAGE_OPTIMIZER_BIN",
    File.join(PROJECT_ROOT, "native", "build", "Release", "image_optimizer.exe")
  )

  FileUtils.mkdir_p([JOBS_DIR, UPLOADS_DIR, OUTPUTS_DIR])

  class JobStore
    def self.create(settings:, files:)
      id = SecureRandom.uuid
      now = Time.now.utc.iso8601
      job = {
        "id" => id,
        "status" => "queued",
        "created_at" => now,
        "updated_at" => now,
        "settings" => settings,
        "files" => files,
        "errors" => []
      }
      write(job)
      job
    end

    def self.find(id)
      path = path_for(id)
      return nil unless File.file?(path)

      JSON.parse(File.read(path))
    end

    def self.update(id)
      job = find(id)
      return nil unless job

      yield job
      job["updated_at"] = Time.now.utc.iso8601
      write(job)
      job
    end

    def self.write(job)
      File.write(path_for(job.fetch("id")), JSON.pretty_generate(job))
    end

    def self.path_for(id)
      File.join(JOBS_DIR, "#{id}.json")
    end
  end

  class Processor
    FORMAT_EXTENSIONS = {
      "jpeg" => ".jpg",
      "png" => ".png",
      "bmp" => ".bmp",
      "tiff" => ".tif"
    }.freeze
    KEEP_EXTENSIONS = %w[.jpg .jpeg .png .bmp .tif .tiff].freeze

    def self.start(job_id)
      Thread.new { new(job_id).run }
    end

    def initialize(job_id)
      @job_id = job_id
    end

    def run
      JobStore.update(@job_id) { |job| job["status"] = "processing" }
      ensure_native_available!

      job = JobStore.find(@job_id)
      job.fetch("files").each_with_index do |file, index|
        process_file(file, job.fetch("settings"), index)
      end

      final = JobStore.find(@job_id)
      status = final["files"].all? { |file| file["status"] == "done" } ? "done" : "failed"
      JobStore.update(@job_id) { |job| job["status"] = status }
    rescue StandardError => error
      JobStore.update(@job_id) do |job|
        job["status"] = "failed"
        job["errors"] << error.message
      end
    end

    private

    def process_file(file, settings, index)
      input_path = file.fetch("original_path")
      output_name = output_filename(file.fetch("name"), settings.fetch("format"), index)
      output_path = File.join(OUTPUTS_DIR, @job_id, output_name)
      FileUtils.mkdir_p(File.dirname(output_path))

      command = [
        NATIVE_EXE,
        "--input", input_path,
        "--output", output_path,
        "--format", settings.fetch("format"),
        "--quality", settings.fetch("quality").to_s
      ]
      command.concat(["--max-width", settings["max_width"].to_s]) if settings["max_width"]
      command.concat(["--max-height", settings["max_height"].to_s]) if settings["max_height"]

      stdout, stderr, status = run_command(command)
      metadata = JSON.parse(stdout)

      JobStore.update(@job_id) do |job|
        target = job["files"].find { |candidate| candidate["id"] == file["id"] }
        target["status"] = status.success? ? "done" : "failed"
        target["output_name"] = output_name
        target["output_path"] = output_path
        target["output_size"] = File.size?(output_path) || 0
        target["metadata"] = metadata
        target["error"] = stderr.strip unless status.success?
      end
    rescue StandardError => error
      JobStore.update(@job_id) do |job|
        target = job["files"].find { |candidate| candidate["id"] == file["id"] }
        target["status"] = "failed"
        target["error"] = error.message
      end
    end

    def run_command(command)
      require "open3"

      Open3.capture3(*command)
    end

    def output_filename(original_name, target_format, index)
      base = File.basename(original_name, ".*").gsub(/[^a-zA-Z0-9._-]/, "-")
      ext = if target_format == "keep"
        original_ext = File.extname(original_name).downcase
        KEEP_EXTENSIONS.include?(original_ext) ? original_ext : ".png"
      else
        FORMAT_EXTENSIONS.fetch(target_format)
      end
      "#{index + 1}-#{base}-optimized#{ext.downcase}"
    end

    def ensure_native_available!
      return if File.executable?(NATIVE_EXE) || File.file?(NATIVE_EXE)

      raise "Native optimizer was not found at #{NATIVE_EXE}. Build it with `cmake -S native -B native/build` and `cmake --build native/build --config Release`."
    end
  end

  class Server < Sinatra::Base
    set :bind, "0.0.0.0"
    set :show_exceptions, false

    before do
      headers(
        "Access-Control-Allow-Origin" => ENV.fetch("FRONTEND_ORIGIN", "http://localhost:5173"),
        "Access-Control-Allow-Methods" => "GET,POST,OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type"
      )
      content_type :json
    end

    options "*" do
      204
    end

    get "/api/health" do
      { ok: true, native_optimizer: File.file?(NATIVE_EXE) }.to_json
    end

    post "/api/jobs" do
      uploads = Array(params["images"])
      halt 400, { error: "Upload at least one image." }.to_json if uploads.empty?

      settings = normalized_settings(params)
      job_upload_dir = File.join(UPLOADS_DIR, SecureRandom.uuid)
      FileUtils.mkdir_p(job_upload_dir)

      files = uploads.each_with_index.map do |upload, index|
        tempfile = upload.fetch(:tempfile)
        filename = "#{index + 1}-#{sanitize_filename(upload.fetch(:filename))}"
        stored_path = File.join(job_upload_dir, filename)
        FileUtils.copy_file(tempfile.path, stored_path)
        {
          "id" => SecureRandom.uuid,
          "name" => filename,
          "status" => "queued",
          "original_path" => stored_path,
          "original_size" => File.size(stored_path)
        }
      end

      job = JobStore.create(settings: settings, files: files)
      Processor.start(job.fetch("id"))
      status 202
      public_job(job).to_json
    end

    get "/api/jobs/:id" do
      job = JobStore.find(params["id"])
      halt 404, { error: "Job not found." }.to_json unless job

      public_job(job).to_json
    end

    get "/api/files/:job_id/:kind/:filename" do
      job = JobStore.find(params["job_id"])
      halt 404 unless job

      file = job["files"].find do |candidate|
        [candidate["name"], candidate["output_name"]].include?(params["filename"])
      end
      halt 404 unless file

      path = case params["kind"]
      when "original" then file["original_path"]
      when "optimized" then file["output_path"]
      else halt 404
      end
      halt 404 unless path && File.file?(path)

      content_type mime_for(path)
      send_file path, disposition: "inline"
    end

    get "/api/jobs/:id/export" do
      job = JobStore.find(params["id"])
      halt 404, { error: "Job not found." }.to_json unless job

      zip_path = File.join(OUTPUTS_DIR, "#{job["id"]}.zip")
      Zip::File.open(zip_path, create: true) do |zip|
        job["files"].each do |file|
          next unless file["status"] == "done" && File.file?(file["output_path"])

          zip.add(file["output_name"], file["output_path"]) unless zip.find_entry(file["output_name"])
        end
      end

      content_type "application/zip"
      send_file zip_path, filename: "optimized-images-#{job["id"]}.zip", disposition: "attachment"
    end

    error do
      status 500
      { error: env["sinatra.error"].message }.to_json
    end

    helpers do
      def normalized_settings(params)
        {
          "format" => allowed_format(params["format"]),
          "quality" => clamp_integer(params["quality"], 1, 100, 82),
          "max_width" => optional_positive_integer(params["max_width"]),
          "max_height" => optional_positive_integer(params["max_height"])
        }
      end

      def allowed_format(value)
        value = value.to_s.downcase
        %w[keep jpeg png bmp tiff].include?(value) ? value : "keep"
      end

      def clamp_integer(value, min, max, fallback)
        integer = Integer(value || fallback)
        [[integer, min].max, max].min
      rescue ArgumentError, TypeError
        fallback
      end

      def optional_positive_integer(value)
        integer = Integer(value)
        integer.positive? ? integer : nil
      rescue ArgumentError, TypeError
        nil
      end

      def sanitize_filename(filename)
        cleaned = File.basename(filename).gsub(/[^a-zA-Z0-9._-]/, "-")
        cleaned.empty? ? "image" : cleaned
      end

      def public_job(job)
        api_job = Marshal.load(Marshal.dump(job))
        api_job["files"].each do |file|
          file["original_url"] = "/api/files/#{job["id"]}/original/#{file["name"]}"
          file["optimized_url"] = "/api/files/#{job["id"]}/optimized/#{file["output_name"]}" if file["output_name"]
          file.delete("original_path")
          file.delete("output_path")
        end
        api_job
      end

      def mime_for(path)
        case File.extname(path).downcase
        when ".jpg", ".jpeg" then "image/jpeg"
        when ".png" then "image/png"
        when ".bmp" then "image/bmp"
        when ".gif" then "image/gif"
        when ".tif", ".tiff" then "image/tiff"
        else "application/octet-stream"
        end
      end
    end
  end
end
