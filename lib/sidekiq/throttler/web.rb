require 'sidekiq/throttler'

module SidekiqThrottler
  # Hook into *Sidekiq::Web* Sinatra app which adds a replaces '/queues' page

  module Web
    VIEW_PATH = File.expand_path('../../../../web/views', __FILE__)

    def self.registered(app)
      
      app.instance_variable_get(:@routes)['GET'].reject! { |r| r.pattern == "/queues" }
      
      app.get "/queues" do
        @queues = Sidekiq::Queue.all

        erb File.read(File.join(VIEW_PATH, 'queues.erb'))
      end
    end
  end
end

require 'sidekiq/web' unless defined?(Sidekiq::Web)
Sidekiq::Web.register(SidekiqThrottler::Web)