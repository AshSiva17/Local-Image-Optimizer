require "rack/tempfile_reaper"
require_relative "app/server"

use Rack::TempfileReaper
run ImageOptimizer::Server
