require "fileutils"
require "json"
require "securerandom"
require "sinatra/base"
require "time"
require "tempfile"
require "thread"
require "monitor"
require "set"
require "open3"
require "timeout"
require "zip"

module ImageOptimizer
  ROOT = File.expand_path("..", __dir__)
  PROJECT_ROOT = File.expand_path("../..", __dir__)
  DATA_DIR = ENV.fetch("IMAGE_OPTIMIZER_STORAGE", File.join(ROOT, "storage"))
  JOBS_DIR = File.join(DATA_DIR, "jobs")
  UPLOADS_DIR = File.join(DATA_DIR, "uploads")
  OUTPUTS_DIR = File.join(DATA_DIR, "outputs")
  NATIVE_EXE = ENV.fetch(
    "IMAGE_OPTIMIZER_BIN",
    File.join(PROJECT_ROOT, "native", "build", "Release", "image_optimizer.exe")
  )

  FileUtils.mkdir_p([JOBS_DIR, UPLOADS_DIR, OUTPUTS_DIR])
  # Hold for the process lifetime. Recovery must never touch a live worker's jobs.
  STORAGE_LOCK = File.open(File.join(DATA_DIR, "server.lock"), "a")
  unless STORAGE_LOCK.flock(File::LOCK_EX | File::LOCK_NB)
    raise "Another API process is already using #{DATA_DIR}. Run one API process per storage directory."
  end
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  def self.safe_file?(path, root)
    return false unless path && File.file?(path) && !File.symlink?(path)

    File.realpath(path).start_with?(File.realpath(root) + File::SEPARATOR)
  rescue SystemCallError
    false
  end

  class JobStore
    # Windows cannot reliably open a file while another thread replaces it.
    # Reentrancy lets update hold one lock across its find/write transaction.
    LOCK = Monitor.new

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
      LOCK.synchronize { read(id) }
    end

    def self.read(id)
      return nil unless id.to_s.match?(UUID)

      path = path_for(id)
      return nil unless ImageOptimizer.safe_file?(path, JOBS_DIR)

      job = JSON.parse(File.read(path))
      return nil unless job.is_a?(Hash) && job["id"] == id && job["files"].is_a?(Array)
      job
    rescue JSON::ParserError => error
      warn "Unreadable job #{id}: #{error.message}"
      nil
    end

    def self.update(id)
      LOCK.synchronize do
        job = find(id)
        return nil unless job

        yield job
        job["updated_at"] = Time.now.utc.iso8601
        write(job)
        job
      end
    end

    def self.write(job)
      LOCK.synchronize { persist(job) }
    end

    def self.persist(job)
      Tempfile.create(["job-", ".json"], JOBS_DIR) do |temp|
        temp.write(JSON.pretty_generate(job))
        temp.close
        File.rename(temp.path, path_for(job.fetch("id")))
      end
    end

    def self.path_for(id)
      raise ArgumentError, "Invalid job ID" unless id.to_s.match?(UUID)

      File.join(JOBS_DIR, "#{id}.json")
    end

    private_class_method :read, :persist
  end

  class QueueFull < StandardError; end

  class Processor
    FORMAT_EXTENSIONS = {
      "jpeg" => ".jpg",
      "png" => ".png",
      "bmp" => ".bmp",
      "tiff" => ".tif"
    }.freeze
    KEEP_EXTENSIONS = %w[.jpg .jpeg .png .bmp .tif .tiff].freeze

    QUEUE_LOCK = Mutex.new
    PENDING = Set.new

    def self.start(job_id)
      QUEUE_LOCK.synchronize do
        job = JobStore.find(job_id)
        return unless job && job["status"] == "queued"
        return if PENDING.include?(job_id)
        PENDING.add(job_id)
        begin
          queue.push(job_id, true)
        rescue ThreadError
          PENDING.delete(job_id)
          raise QueueFull, "Processing queue is full. Try again later."
        end
      end
    end

    def self.queue
      return @queue if @worker&.alive?

      @queue ||= SizedQueue.new(16)
      @worker = Thread.new do
        loop do
          id = @queue.pop
          begin
            new(id).run
          rescue StandardError => error
            warn "Worker error for #{id}: #{error.message}"
          ensure
            QUEUE_LOCK.synchronize { PENDING.delete(id) }
          end
        end
      end
      @queue
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
        job["files"].each do |file|
          next if %w[done failed].include?(file["status"])
          file["status"] = "failed"
          file["error"] = error.message
        end
      end
    end

    private

    def process_file(file, settings, index)
      JobStore.update(@job_id) do |job|
        job["files"][index]["status"] = "processing"
      end
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

      # Preserve the extension for --format keep. Never publish partial native output.
      Tempfile.create([".processing-", File.extname(output_path)], File.dirname(output_path)) do |temp|
        temp.close
        File.unlink(temp.path)
        command[command.index("--output") + 1] = temp.path
        stdout, stderr, status = run_command(command)
        raise(stderr.strip.empty? ? "Native optimizer failed (exit #{status.exitstatus})." : stderr.strip) unless status.success?
        metadata = JSON.parse(stdout)
        raise "Native optimizer produced no output." unless ImageOptimizer.safe_file?(temp.path, OUTPUTS_DIR) && File.size?(temp.path)
        unless metadata.is_a?(Hash) && metadata["width"].is_a?(Integer) && metadata["width"].positive? &&
            metadata["height"].is_a?(Integer) && metadata["height"].positive? && FORMAT_EXTENSIONS.key?(metadata["format"])
          raise "Native optimizer returned invalid metadata."
        end
        metadata = metadata.select { |key, _| %w[format original_width original_height width height input_size output_size savings_percent].include?(key) }
        if settings["format"] == "keep"
          output_name = output_filename(file.fetch("name"), metadata.fetch("format"), index)
          output_path = File.join(OUTPUTS_DIR, @job_id, output_name)
        end
        File.rename(temp.path, output_path)
        JobStore.update(@job_id) do |job|
          target = job["files"][index]
          target.merge!("status" => "done", "output_name" => output_name, "output_path" => output_path,
            "output_size" => File.size(output_path), "metadata" => metadata)
        end
      end
    rescue StandardError => error
      FileUtils.rm_f(output_path) if output_path
      JobStore.update(@job_id) do |job|
        target = job["files"][index]
        target["status"] = "failed"
        target["error"] = error.message
      end
    end

    def run_command(command)
      limit = Float(ENV.fetch("IMAGE_OPTIMIZER_TIMEOUT", "120"))
      raise "Processing timeout must be positive." unless limit.positive? && limit.finite?

      Open3.popen3(*command) do |stdin, stdout, stderr, wait|
        stdin.close
        # Drain both pipes, but retain at most 64 KiB each.
        readers = [stdout, stderr].map do |pipe|
          Thread.new do
            result = +""
            while (chunk = pipe.read(4096))
              result << chunk.byteslice(0, [65_536 - result.bytesize, 0].max)
            end
            result
          end
        end
        begin
          status = Timeout.timeout(limit) { wait.value }
          [readers[0].value, readers[1].value, status]
        rescue Timeout::Error
          begin
            Process.kill("KILL", wait.pid)
          rescue Errno::ESRCH
            # The process exited between the timeout and termination.
          end
          wait.value
          raise "Native optimizer exceeded the #{limit}s processing timeout."
        ensure
          readers.each(&:join)
        end
      end
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

  [File.join(JOBS_DIR, "job-*.json"), File.join(OUTPUTS_DIR, "export-*.zip"),
    File.join(OUTPUTS_DIR, "*", ".processing-*")].each do |pattern|
    Dir.glob(pattern).each { |path| FileUtils.rm_f(path) }
  end

  # Only directories explicitly marked as unfinished uploads are candidates for cleanup.
  referenced_uploads = Dir.glob(File.join(JOBS_DIR, "*.json")).filter_map do |path|
    job = JobStore.find(File.basename(path, ".json"))
    job && job["files"].filter_map { |file| File.dirname(file["original_path"]) if file["original_path"] }
  end.flatten.to_set
  Dir.glob(File.join(UPLOADS_DIR, "*", ".uploading")).each do |marker|
    directory = File.dirname(marker)
    next if File.symlink?(directory) || !File.basename(directory).match?(UUID)
    if referenced_uploads.include?(directory)
      FileUtils.rm_f(marker)
    else
      FileUtils.remove_entry_secure(directory)
    end
  end

  # The queue is in-process. Explicitly fail interrupted work after a restart.
  Dir.glob(File.join(JOBS_DIR, "*.json")).each do |path|
    id = File.basename(path, ".json")
    job = JobStore.find(id)
    next unless job && %w[queued processing].include?(job["status"])

    JobStore.update(id) do |interrupted|
      interrupted["status"] = "failed"
      interrupted["errors"] << "Server restarted before this job completed. Submit the batch again."
      interrupted["files"].each do |file|
        next if %w[done failed].include?(file["status"])
        file["status"] = "failed"
        file["error"] = "Interrupted by server restart."
      end
    end
  end

  class Server < Sinatra::Base
    set :bind, "127.0.0.1"
    set :show_exceptions, false
    set :raise_errors, false
    EXPORT_LOCK = Mutex.new

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

      halt 400, { error: "A batch supports at most 50 images." }.to_json if uploads.length > 50
      uploads.each do |upload|
        valid = upload.is_a?(Hash) && upload[:tempfile].respond_to?(:path) &&
          Processor::KEEP_EXTENSIONS.include?(File.extname(upload[:filename].to_s).downcase)
        halt 400, { error: "Upload JPEG, PNG, BMP, or TIFF files." }.to_json unless valid
        halt 413, { error: "Each image must be between 1 byte and 50 MB." }.to_json unless File.size(upload[:tempfile].path).between?(1, 50 * 1024 * 1024)
      end
      settings = normalized_settings(params)
      accepted = false
      job_upload_dir = File.join(UPLOADS_DIR, SecureRandom.uuid)
      FileUtils.mkdir_p(job_upload_dir)

      begin
        marker = File.join(job_upload_dir, ".uploading")
        File.write(marker, "")
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
        File.unlink(marker)
        Processor.start(job.fetch("id"))
        accepted = true
        status 202
        public_job(job).to_json
      rescue QueueFull => error
        halt 503, { error: error.message }.to_json
      ensure
        unless accepted
          FileUtils.remove_entry(job_upload_dir) if File.directory?(job_upload_dir)
          FileUtils.rm_f(JobStore.path_for(job["id"])) if job
        end
      end
    end

    get "/api/jobs/:id" do
      job = JobStore.find(params["id"])
      halt 404, { error: "Job not found." }.to_json unless job

      public_job(job).to_json
    end

    get "/api/files/:job_id/:kind/:filename" do
      job = JobStore.find(params["job_id"])
      halt 404 unless job

      key = { "original" => "name", "optimized" => "output_name" }[params["kind"]]
      halt 404 unless key
      file = job["files"].find { |candidate| candidate[key] == params["filename"] }
      halt 404 unless file
      halt 404 if params["kind"] == "optimized" && file["status"] != "done"
      path = file[params["kind"] == "original" ? "original_path" : "output_path"]
      root = params["kind"] == "original" ? UPLOADS_DIR : OUTPUTS_DIR
      halt 404 unless ImageOptimizer.safe_file?(path, root)

      content_type mime_for(path)
      disposition = params["download"] == "1" ? "attachment" : "inline"
      send_file path, filename: File.basename(path), disposition: disposition
    end

    get "/api/jobs/:id/export" do
      job = JobStore.find(params["id"])
      halt 404, { error: "Job not found." }.to_json unless job

      halt 409, { error: "Wait for the job to finish before exporting." }.to_json unless %w[done failed].include?(job["status"])
      completed = job["files"].select { |file| file["status"] == "done" && ImageOptimizer.safe_file?(file["output_path"], OUTPUTS_DIR) }
      halt 409, { error: "No successful outputs to export." }.to_json if completed.empty?

      zip_path = File.join(OUTPUTS_DIR, "#{job['id']}.zip")
      EXPORT_LOCK.synchronize do
        halt 404 if File.symlink?(zip_path)
        unless File.file?(zip_path)
          Tempfile.create(["export-", ".zip"], OUTPUTS_DIR) do |temp|
            temp.close
            Zip::OutputStream.open(temp.path) do |zip|
              completed.each do |file|
                name = file["output_name"]
                raise "Unsafe archive entry." unless name && name.match?(/\A[a-zA-Z0-9._-]+\z/) && !%w[. ..].include?(name)
                zip.put_next_entry(name)
                File.open(file["output_path"], "rb") do |input|
                  while (chunk = input.read(64 * 1024))
                    zip.write(chunk)
                  end
                end
              end
            end
            File.rename(temp.path, zip_path)
          end
        end
      end
      content_type "application/zip"
      send_file zip_path, filename: "optimized-images-#{job['id']}.zip", disposition: "attachment"
    end

    error do
      status 500
      warn "API error: #{env["sinatra.error"].message}"
      { error: "The API could not complete the request." }.to_json
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
        value = value.nil? ? "keep" : value.to_s.downcase
        halt 400, { error: "Unsupported output format." }.to_json unless %w[keep jpeg png bmp tiff].include?(value)
        value
      end

      def clamp_integer(value, min, max, fallback)
        integer = Integer(value || fallback)
        halt 400, { error: "Quality must be an integer from 1 to 100." }.to_json unless integer.between?(min, max)
        integer
      rescue ArgumentError, TypeError
        halt 400, { error: "Quality must be an integer from 1 to 100." }.to_json
      end

      def optional_positive_integer(value)
        return nil if value.nil? || value == ""
        integer = Integer(value)
        halt 400, { error: "Dimensions must be integers from 1 to 100000." }.to_json unless integer.between?(1, 100_000)
        integer
      rescue ArgumentError, TypeError
        halt 400, { error: "Dimensions must be integers from 1 to 100000." }.to_json
      end

      def sanitize_filename(filename)
        cleaned = File.basename(filename.tr("\\", "/")).gsub(/[^a-zA-Z0-9._-]/, "-")
        return "image" if cleaned.empty?
        extension = File.extname(cleaned)
        "#{File.basename(cleaned, extension).byteslice(0, 64)}#{extension}"
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
