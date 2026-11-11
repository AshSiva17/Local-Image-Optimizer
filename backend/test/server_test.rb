require "tmpdir"
require "fileutils"
require "minitest/autorun"
require "minitest/mock"
require "rack/test"
require "rbconfig"
require "rack/tempfile_reaper"
require "stringio"

TEST_STORAGE = Dir.mktmpdir("image-optimizer-test")
ENV["IMAGE_OPTIMIZER_STORAGE"] = TEST_STORAGE
ENV["IMAGE_OPTIMIZER_BIN"] = RbConfig.ruby
ENV["RACK_ENV"] = "test"
require_relative "../app/server"
Minitest.after_run { ImageOptimizer::STORAGE_LOCK.close; FileUtils.remove_entry(TEST_STORAGE) }

# Exercise the real subprocess runner with a deterministic stand-in for WIC.
require_relative 'support/fixture_command'

class ServerTest < Minitest::Test
  include Rack::Test::Methods
  def app = Rack::TempfileReaper.new(ImageOptimizer::Server)

  def upload(name, content = "image")
    path = File.join(TEST_STORAGE, name)
    File.binwrite(path, content)
    Rack::Test::UploadedFile.new(path, "image/png", true)
  end

  def create_job(images)
    post "/api/jobs", { "images" => images, "max_width" => "1800", "max_height" => "1800", "quality" => "100", "format" => "png" }
    assert_equal 202, last_response.status, last_response.body
    JSON.parse(last_response.body)
  end

  def finish(id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      get "/api/jobs/#{id}"
      job = JSON.parse(last_response.body)
      return job if %w[done failed].include?(job["status"])
      raise "Job timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def test_batch_status_download_and_repeatable_zip
    job = finish(create_job([upload("a.png"), upload("b.png")]).fetch("id"))
    assert_equal "done", job["status"]
    assert_equal 100, job.dig("settings", "quality")
    file = job["files"].first
    refute file.key?("original_path")
    refute file["metadata"].key?("input")
    get "#{file['optimized_url']}?download=1"
    assert_equal "optimized-image", last_response.body
    assert_includes last_response.headers["content-disposition"], "attachment"
    2.times do
      get "/api/jobs/#{job['id']}/export"
      assert_equal 200, last_response.status, last_response.body
      archive = Zip::File.open_buffer(last_response.body)
      assert_equal job["files"].map { |f| f["output_name"] }.sort, archive.entries.map(&:name).sort
      archive.close
    end
  end

  def test_binary_upload_preserves_control_bytes_and_original_download
    bytes = "\x89PNG\r\n\x1a\n\x00\xff\r\n".b
    job = finish(create_job([upload('binary.png', bytes)])['id'])
    assert_equal 'done', job['status'], job.inspect
    file = job['files'].first
    assert_equal bytes.bytesize, file['original_size']
    get file['original_url']
    assert_equal 200, last_response.status
    assert_equal bytes, last_response.body.b
    stored = ImageOptimizer::JobStore.find(job['id'])
    assert_equal bytes, File.binread(stored['files'].first['original_path'])
  end

  def test_partial_failure_preserves_error_and_successful_export
    job = finish(create_job([upload("good.png"), upload("bad.png", "corrupt")]).fetch("id"))
    assert_equal "failed", job["status"]
    assert_equal %w[done failed], job["files"].map { |f| f["status"] }
    assert_includes job["files"].last["error"], "Failed to decode"
    get "/api/jobs/#{job['id']}/export"
    assert_equal 200, last_response.status
    Zip::File.open_buffer(last_response.body) { |zip| assert_equal 1, zip.entries.length }
  end

  def test_rejects_invalid_uploads_and_missing_jobs
    post "/api/jobs", {}
    assert_equal 400, last_response.status
    post "/api/jobs", { "images" => [upload("a.gif")] }
    assert_equal 400, last_response.status
    post "/api/jobs", { "images" => [upload("empty.png", "")] }
    assert_equal 413, last_response.status
    get "/api/jobs/unknown"
    assert_equal 404, last_response.status
  end

  def test_export_rejects_unfinished_or_empty_job
    job = ImageOptimizer::JobStore.create(settings: {}, files: [])
    get "/api/jobs/#{job['id']}/export"
    assert_equal 409, last_response.status
    ImageOptimizer::JobStore.update(job['id']) { |j| j['status'] = 'failed' }
    get "/api/jobs/#{job['id']}/export"
    assert_equal 409, last_response.status
  end

  def test_restart_marks_interrupted_files_failed_and_cleans_crash_temps
    isolated = Dir.mktmpdir('restart-', TEST_STORAGE)
    server = File.expand_path('../app/server', __dir__)
    program = <<~RUBY
      require #{server.inspect}
      original_dir = File.join(ImageOptimizer::UPLOADS_DIR, SecureRandom.uuid)
      orphan_dir = File.join(ImageOptimizer::UPLOADS_DIR, SecureRandom.uuid)
      retained_dir = File.join(ImageOptimizer::UPLOADS_DIR, SecureRandom.uuid)
      [original_dir, orphan_dir, retained_dir].each { |dir| Dir.mkdir(dir) }
      [original_dir, orphan_dir].each { |dir| File.write(File.join(dir, '.uploading'), '') }
      original = File.join(original_dir, 'preserved.png')
      File.write(original, 'original')
      File.write(File.join(retained_dir, 'unmarked.png'), 'retained')
      job = ImageOptimizer::JobStore.create(settings: {}, files: [{ 'id' => 'interrupted', 'status' => 'processing', 'original_path' => original }])
      Dir.mkdir(File.join(ImageOptimizer::OUTPUTS_DIR, job['id']))
      File.write(File.join(ImageOptimizer::OUTPUTS_DIR, job['id'], '.processing-crash.png'), 'partial')
      puts job['id']
    RUBY
    env = { 'IMAGE_OPTIMIZER_STORAGE' => isolated }
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-e', program)
    assert status.success?, stderr
    id = stdout.strip
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-r', server, '-e', "puts JSON.generate(ImageOptimizer::JobStore.find(#{id.inspect}))")
    assert status.success?, stderr
    restored = JSON.parse(stdout)
    assert_equal 'failed', restored['status']
    assert_equal 'failed', restored['files'].first['status']
    assert_includes restored['errors'].first, 'Server restarted'
    assert_empty Dir.glob(File.join(isolated, 'outputs', '*', '.processing-*'))
    assert_equal 2, Dir.children(File.join(isolated, 'uploads')).length
    assert_empty Dir.glob(File.join(isolated, 'uploads', '*', '.uploading'))
    assert_equal 'original', File.read(restored['files'].first['original_path'])
  end

  def test_second_api_process_cannot_recover_live_jobs
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-r', File.expand_path('../app/server', __dir__), '-e', 'nil')
    refute status.success?
    assert_includes stderr, 'Another API process'
  end

  def test_duplicate_posts_are_isolated_and_duplicate_queue_entries_are_ignored
    first = create_job([upload('same.png', 'slow')])
    5.times { ImageOptimizer::Processor.start(first['id']) }
    second = create_job([upload('same.png')])
    refute_equal first['id'], second['id']
    [first, second].each do |job|
      assert_equal 'done', finish(job['id'])['status']
      stored = ImageOptimizer::JobStore.find(job['id'])
      assert_equal 'x', File.read(stored['files'].first['original_path'] + '.runs')
    end
  end

  def test_worker_survives_crash_bad_json_missing_output_and_timeout
    previous = ENV['IMAGE_OPTIMIZER_TIMEOUT']
    ENV['IMAGE_OPTIMIZER_TIMEOUT'] = '2'
    job = finish(create_job(%w[crash malformed nooutput hang good].map { |mode| upload("#{mode}.png", mode) })['id'])
    assert_equal %w[failed failed failed failed done], job['files'].map { |file| file['status'] }, job['files'].map { |file| [file['name'], file['error']] }.inspect
    assert_includes job['files'][3]['error'], 'processing timeout'
    assert_empty Dir.glob(File.join(ImageOptimizer::OUTPUTS_DIR, job['id'], '.processing-*'))
    assert_equal 1, Dir.children(File.join(ImageOptimizer::OUTPUTS_DIR, job['id'])).length
    assert_equal 'done', finish(create_job([upload('after-failure.png')])['id'])['status']
  ensure
    ENV['IMAGE_OPTIMIZER_TIMEOUT'] = previous
  end

  def test_upload_names_and_download_routes_cannot_traverse
    image = Rack::Test::UploadedFile.new(StringIO.new('image'), 'image/png', original_filename: '..\\..\\escape.png')
    job = finish(create_job([image])['id'])
    file = job['files'].first
    assert_match(/\A[0-9]+-[a-zA-Z0-9._-]+\z/, file['name'])
    get "/api/files/#{job['id']}/optimized/#{file['name']}"
    assert_equal 404, last_response.status
    get '/api/jobs/%2e%2e%2foutside'
    assert_equal 404, last_response.status
    get "/api/files/#{job['id']}/original/%2e%2e%2fserver.lock"
    assert_equal 404, last_response.status
    external = File.join(TEST_STORAGE, 'secret.png')
    File.write(external, 'secret')
    ImageOptimizer::JobStore.update(job['id']) { |j| j['files'].first['output_path'] = external }
    get file['optimized_url']
    assert_equal 404, last_response.status
    get "/api/jobs/#{job['id']}/export"
    assert_equal 409, last_response.status
  end

  def test_strict_settings_and_rejected_request_tempfiles_are_cleaned
    before = Dir.children(ImageOptimizer::UPLOADS_DIR)
    [{ 'quality' => '0' }, { 'max_width' => '-2' }, { 'format' => 'gif' }].each do |invalid|
      post '/api/jobs', { 'images' => [upload('invalid-settings.png')] }.merge(invalid)
      assert_equal 400, last_response.status
      assert last_request.env.fetch('rack.tempfiles').all?(&:closed?)
    end
    assert_equal before, Dir.children(ImageOptimizer::UPLOADS_DIR)
  end

  def test_queue_rejection_rolls_back_upload_and_job_files
    before_uploads = Dir.children(ImageOptimizer::UPLOADS_DIR)
    before_jobs = Dir.children(ImageOptimizer::JOBS_DIR)
    ImageOptimizer::Processor.stub(:start, ->(*) { raise ImageOptimizer::QueueFull, 'Queue full' }) do
      post '/api/jobs', { 'images' => [upload('queue-full.png')] }
      assert_equal 503, last_response.status
    end
    assert_equal before_uploads, Dir.children(ImageOptimizer::UPLOADS_DIR)
    assert_equal before_jobs, Dir.children(ImageOptimizer::JOBS_DIR)
  end

  def test_failed_export_cleans_temp_archive_and_rejects_symlinks
    job = finish(create_job([upload('archive.png')])['id'])
    file = job['files'].first
    ImageOptimizer::JobStore.update(job['id']) { |j| j['files'].first['output_name'] = '../unsafe.png' }
    get "/api/jobs/#{job['id']}/export"
    assert_equal 500, last_response.status
    assert_empty Dir.glob(File.join(ImageOptimizer::OUTPUTS_DIR, 'export-*.zip'))
    ImageOptimizer::JobStore.update(job['id']) { |j| j['files'].first['output_name'] = file['output_name'] }
    link = File.join(ImageOptimizer::OUTPUTS_DIR, "#{job['id']}.zip")
    begin
      File.symlink(File.join(TEST_STORAGE, 'secret.txt'), link)
    rescue NotImplementedError, Errno::EACCES, Errno::EPERM
      skip 'This platform/account cannot create symlinks.'
    end
    get "/api/jobs/#{job['id']}/export"
    assert_equal 404, last_response.status
  end

  def test_atomic_store_under_polling
    job = ImageOptimizer::JobStore.create(settings: {}, files: [])
    writers = 4.times.map { Thread.new { 50.times { ImageOptimizer::JobStore.update(job['id']) { |j| j['counter'] = (j['counter'] || 0) + 1 } } } }
    200.times { assert_equal job['id'], ImageOptimizer::JobStore.find(job['id'])['id'] }
    writers.each(&:value)
    assert_equal 200, ImageOptimizer::JobStore.find(job['id'])['counter']
  end
end
