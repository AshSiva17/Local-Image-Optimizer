# Used only by tests. Production always invokes the configured WIC executable directly.
require "rbconfig"
module FixtureCommand
  def run_command(command)
    super([RbConfig.ruby, File.expand_path("../fixtures/optimizer.rb", __dir__), *command.drop(1)])
  end
end
ImageOptimizer::Processor.prepend(FixtureCommand)
