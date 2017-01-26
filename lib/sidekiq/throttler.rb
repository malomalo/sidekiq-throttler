require 'sidekiq'
require 'sidekiq/fetch'

module Sidekiq
  @rate_limits = {}
  
  def self.rate_limit(queue, options)
    if options.keys.sort != [:at, :per]
      raise ArgumentError.new("Mising either :at or :per in options")
    end
    @rate_limits[queue.to_s] = options
  end

  def self.queue_rate_limited?(queue)
    @rate_limits.has_key?(queue.to_s)
  end

  def self.queue_rate(queue)
    redis { |conn| conn.scard("throttler:#{queue}_uuids") }
  end

  def self.queue_rate_limit(queue)
    @rate_limits[queue.to_s]
  end

  def self.queue_at_or_over_rate_limit?(queue)
    if queue_rate_limited?(queue)
      queue_rate(queue) >= queue_rate_limit(queue)[:at]
    else
      false
    end
  end

  def self.gc_rate_limit_data_for_queue(queue)
    return unless queue_rate_limited?(queue)

    limit = queue_rate_limit(queue)
    queue_key = "throttler:#{queue}_uuids"

    redis do |conn|
      conn.smembers(queue_key).each do |uuid|
        job_ended_at = conn.hmget("throttler:jobs:#{uuid}", "ended_at")[0]
        if job_ended_at && job_ended_at.to_i < Time.now.to_i - limit[:per]
          conn.srem(queue_key, uuid)
          conn.del("throttler:jobs:#{uuid}")
        end
      end
    end
  end

  module Throttler

    module Fetcher
      TIMEOUT = 1
      
      def retrieve_work
        queues_to_check = queues_cmd
        if queues_to_check.empty?
          sleep TIMEOUT
          nil
        else
          work = Sidekiq.redis { |conn| conn.brpop(*queues_to_check) }
          Sidekiq::BasicFetch::UnitOfWork.new(*work) if work
        end
      end

      def queues_cmd
        queues_to_check = super
        queues_to_check.pop unless @strictly_ordered_queues
        queues_to_check.map! {|q| q.sub(/^queue:/, '') }

        limited_queues = []
        open_queues = []
        queues_to_check.each do |q|
          if Sidekiq.queue_at_or_over_rate_limit?(q)
            limited_queues << q
          else
            open_queues << q
          end
        end
        limited_queues.each { |q| Sidekiq.gc_rate_limit_data_for_queue(q) }

        open_queues.map! { |q| "queue:#{q}" }
        open_queues.push(TIMEOUT) if !open_queues.empty? && !@strictly_ordered_queues
        open_queues
      end
    end

    class Middleware

      def initialize(options=nil)
        # options == { :foo => 1, :bar => 2 }
      end
       
      def call(worker, msg, queue)
        if Sidekiq.queue_rate_limited?(queue)
          Sidekiq.redis do |conn|
            conn.hmset("throttler:jobs:#{worker.jid}", "started_at", Time.now.to_i)
            conn.sadd("throttler:#{queue}_uuids", worker.jid)
          end
        end

        yield
      ensure
        if Sidekiq.queue_rate_limited?(queue)
          Sidekiq.redis { |conn| conn.hmset("throttler:jobs:#{worker.jid}", "ended_at", Time.now.to_i) }
        end
      end

    end
    
  end
end

class Sidekiq::Queue
  
  def throttled?
    if rate_limited?
      rate >= rate_limit
    else
      false
    end
  end
  
  def rate_limited?
    Sidekiq.queue_rate_limited?(name)
  end
  
  def rate_limit
    Sidekiq.queue_rate_limit(name)[:at]
  end
  
  def rate_limit_over
    Sidekiq.queue_rate_limit(name)[:per]
  end
  
  def rate
    @rate ||= Sidekiq.queue_rate(name)
  end
  
end

Sidekiq::BasicFetch.prepend(Sidekiq::Throttler::Fetcher)
Sidekiq.configure_server do |config|
  config.on(:startup) do
    config.server_middleware do |chain|
      chain.add Sidekiq::Throttler::Middleware
    end
  end
end
