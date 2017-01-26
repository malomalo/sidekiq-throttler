require 'test_helper'

class Sidekiq::JobTest < ActiveSupport::TestCase

  class MyJob
    include Sidekiq::Worker
    sidekiq_options queue: 'myqueue'
    
    def perform
    end
  end
  
  class MyOtherJob
    include Sidekiq::Worker
    sidekiq_options queue: 'other_queue'
    
    def perform
    end
  end

  class MyErrorJob
    include Sidekiq::Worker
    sidekiq_options queue: 'myqueue'
    
    def perform
      raise ArgumentError
    end
  end

  test "Sidekiq::Job::perform on unthrottled job" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)

    jid = MyOtherJob.perform_async
    
    travel_to Time.now do
      redis_expects(:hmset).with("throttler:jobs:#{jid}", "started_at", Time.now.to_i).never
      redis_expects(:sadd).with("throttler:myqueue_jids", jid).never
      redis_expects(:hmset).with("throttler:jobs:#{jid}", "ended_at", Time.now.to_i).never
      
      MyOtherJob.perform_one#fetch_and_execute_job(:myqueue)
    end
  end

  test "Sidekiq::Job::perform on throttled job" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)

    jid = MyJob.perform_async
    
    travel_to Time.now do
      redis_expects(:hmset).with("throttler:jobs:#{jid}", "started_at", Time.now.to_i).once
      redis_expects(:sadd).with("throttler:myqueue_jids", jid).once
      redis_expects(:hmset).with("throttler:jobs:#{jid}", "ended_at", Time.now.to_i).once

      MyJob.perform_one
    end
  end

  test "Sidekiq::Job::perform on throttled job with job that throws error" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)

    jid = MyErrorJob.perform_async

    travel_to Time.now do
      redis_expects(:hmset).with("throttler:jobs:#{jid}", "started_at", Time.now.to_i).once
      redis_expects(:sadd).with("throttler:myqueue_jids", jid).once
      redis_expects(:hmset).with("throttler:jobs:#{jid}", "ended_at", Time.now.to_i).once

      assert_raises(ArgumentError) {
        MyErrorJob.perform_one
      }
    end
  end
  
end

