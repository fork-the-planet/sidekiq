# frozen_string_literal: true

require "bundler/setup"
Bundler.require(:default, :test)

require "minitest/pride"
require "maxitest/autorun"
require "maxitest/threads"

$TESTING = true
# disable minitest/parallel threads
ENV["MT_CPU"] = "0"
ENV["N"] = "0"
# Disable any stupid backtrace cleansers
ENV["BACKTRACE"] = "1"

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/test/"
    add_filter "/myapp/"
    minimum_coverage 90
  end
end

ENV["REDIS_URL"] ||= "redis://localhost:6379/0"
NULL_LOGGER = Logger.new(IO::NULL)

def reset!
  # tidy up any open but unreferenced Redis connections so we don't run out of file handles
  if Sidekiq.default_configuration.instance_variable_defined?(:@redis)
    existing_pool = Sidekiq.default_configuration.instance_variable_get(:@redis)
    existing_pool&.shutdown(&:close)
  end

  RedisClient.new(url: ENV["REDIS_URL"]).call("flushdb")
  cfg = Sidekiq::Config.new
  cfg[:backtrace_cleaner] = Sidekiq::Config::DEFAULTS[:backtrace_cleaner]
  cfg.logger = NULL_LOGGER
  cfg.logger.level = Logger::WARN
  Sidekiq.instance_variable_set :@config, cfg
  cfg
end

def capture_logging(cfg, lvl = Logger::INFO)
  old = cfg.logger
  begin
    out = StringIO.new
    logger = ::Logger.new(out)
    logger.level = lvl
    logger.formatter = Sidekiq::Logger::Formatters::Pretty.new
    cfg.logger = logger
    yield logger
    out.string
  ensure
    cfg.logger = old
  end
end

Signal.trap("TTIN") do
  Thread.list.each do |thread|
    puts "Thread TID-#{(thread.object_id ^ ::Process.pid).to_s(36)} #{thread.name}"
    if thread.backtrace
      puts thread.backtrace.join("\n")
    else
      puts "<no backtrace available>"
    end
  end
end

require "active_job"

# Require adapter class before setting the adapter.
require "sidekiq/rails"

# need to force this since we aren't booting a Rails app
ActiveJob::Base.queue_adapter = :sidekiq
ActiveJob::Base.logger = nil
ActiveJob::Base.send(:include, ::Sidekiq::Job::Options) unless ActiveJob::Base.respond_to?(:sidekiq_options)

require "sidekiq/web"
Sidekiq::Web.configure do |cfg|
  cfg[:csrf] = false
end
