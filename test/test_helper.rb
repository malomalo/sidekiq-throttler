require 'bundler/setup'
require "bundler/gem_tasks"
Bundler.require(:development)

require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
end

# To make testing/debugging easier, test within this source tree versus an
# installed gem
$LOAD_PATH << File.expand_path('../lib', __FILE__)

require 'sidekiq'
require 'sidekiq/processor'
require 'sidekiq/manager'
require 'sidekiq/throttler'
require 'sidekiq/testing'

require "minitest/autorun"
require 'minitest/unit'
require 'minitest/reporters'
require "mocha"
require "mocha/mini_test"
require 'active_support'
require 'active_support/core_ext'
require 'active_support/testing/time_helpers'

ActiveSupport.test_order = :random
Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
Sidekiq.configure_server do |config|
  pool_size = 1
end
Sidekiq::Testing.server_middleware do |chain|
  chain.add Sidekiq::Throttler::Middleware
end

class ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers
  
  # File 'lib/active_support/testing/declarative.rb'
  def self.test(name, &block)
    test_name = "test_#{name.gsub(/\s+/, '_')}".to_sym
    defined = method_defined? test_name
    raise "#{test_name} is already defined in #{self}" if defined
    if block_given?
      define_method(test_name, &block)
    else
      define_method(test_name) do
        skip "No implementation provided for #{name}"
      end
    end
  end
  
  set_callback(:setup, :before) do
    Sidekiq.instance_variable_set(:@rate_limits, {})
  end
  
  def redis_expects(cmd)
    Redis.any_instance.expects(cmd)
  end
  
  def fetch_job(*queues)
    Sidekiq::BasicFetch.new({queues: queues}).retrieve_work
  end
  
end
