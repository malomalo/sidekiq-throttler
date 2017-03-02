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
    redis { |conn| conn.hlen("throttler:#{queue}_jids") }
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
    queue_key = "throttler:#{queue}_jids"

    redis do |conn|
      removeable_jids = []
      conn.hgetall(queue_key).each do |jid, time|
        if time.start_with?('S')
        elsif time.start_with?('E') && time[1..-1].to_i < Time.now.to_i - limit[:per]
          removeable_jids << jid
        end
      end
      
      conn.hdel(queue_key, removeable_jids) unless removeable_jids.empty?
    end
  end

  module Throttler

    module Fetcher
      TIMEOUT = 2
      
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
        queues_to_check.pop
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
        open_queues.push(TIMEOUT) if !open_queues.empty?
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
            conn.hmset("throttler:#{queue}_jids", worker.jid, "S#{Time.now.to_i}")
          end
        end

        yield
      ensure
        if Sidekiq.queue_rate_limited?(queue)
          Sidekiq.redis { |conn| conn.hmset("throttler:#{queue}_jids", worker.jid, "E#{Time.now.to_i}") }
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
    Sidekiq.gc_rate_limit_data_for_queue(name)
    Sidekiq.queue_rate(name)
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
