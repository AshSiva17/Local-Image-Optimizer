require "rbconfig"
ENV['IMAGE_OPTIMIZER_BIN'] = RbConfig.ruby
require 'rack/tempfile_reaper'
require_relative '../../app/server'
require_relative 'fixture_command'
use Rack::TempfileReaper
run ImageOptimizer::Server
