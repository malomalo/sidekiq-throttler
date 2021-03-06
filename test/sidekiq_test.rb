require 'test_helper'

class SidekiqTest < ActiveSupport::TestCase

  test "Sidekiq::rate_limit" do
    Sidekiq.rate_limit(:myqueue, at: 10, per: 1)

    assert_equal Sidekiq.instance_variable_get(:@rate_limits), {
      'myqueue' => {at: 10, per: 1}
    }
  end
  
  test "Sidekiq::queue_rate_limited?" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)
    
    assert Sidekiq.queue_rate_limited?(:myqueue)
    assert Sidekiq.queue_rate_limited?("myqueue")
  end
  
  test "Sidekiq::queue_at_or_over_rate_limit?" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)

    redis_expects(:hlen).with("throttler:myqueue_jids").returns(5).twice
    assert !Sidekiq.queue_at_or_over_rate_limit?(:myqueue)
    assert !Sidekiq.queue_at_or_over_rate_limit?("myqueue")
        
    redis_expects(:hlen).with("throttler:myqueue_jids").returns(10).twice
    assert Sidekiq.queue_at_or_over_rate_limit?(:myqueue)
    assert Sidekiq.queue_at_or_over_rate_limit?("myqueue")
  end

  test "Sidekiq::pop pops on unthrottled queues" do
    redis_expects(:brpop).returns(nil)
    
    fetch_job('myqueue')
  end
  
  test "Sidekiq::pop skips over queues that are at or over their limit" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)
    Sidekiq.expects(:queue_at_or_over_rate_limit?).with("myqueue").returns(true)
    redis_expects(:brpop).never
    
    fetch_job('myqueue')
  end

  
  test "Sidekiq::pop gc's the limit data after skipping over a throttled queue" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 1)
    Sidekiq.expects(:queue_at_or_over_rate_limit?).with("myqueue").returns(true)
    Sidekiq.expects(:gc_rate_limit_data_for_queue).with("myqueue").once
    
    fetch_job('myqueue')
  end
  
  test "Sidekiq::gc_rate_limit_data_for_queue" do
    Sidekiq.rate_limit(:myqueue, :at => 10, :per => 5)
    
    travel_to Time.now do
      redis_expects(:hgetall).with("throttler:myqueue_jids").returns({
        "1" => "E#{(Time.now - 10).to_i}",
        "2" => "E#{(Time.now - 3).to_i}",
        "3" => "S#{(Time.now).to_i}"
      }).once
      redis_expects(:hdel).with("throttler:myqueue_jids", "1").once
    
      Sidekiq.gc_rate_limit_data_for_queue('myqueue')
    end
  end
  
  test "Sidekiq::gc_rate_limit_data_for_queue for unthrottled queue" do
    Sidekiq.gc_rate_limit_data_for_queue('myqueue')
  end
  
end