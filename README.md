Sidekiq Throttler
================

Sidekiq Throttler allows you to throttle the rate at which jobs are performed
on a specific queue.

If the queue is above the rate limit then the workers will ignore the queue
until the queue is below the rate limit.

Installation
------------

```ruby
require 'sidekiq/throttler'
```

Or in a Gemfile:

```ruby
require 'sidekiq-throttler', :require => 'sidekiq/throttler'
```

Usage
-----

```ruby
require 'sidekiq'
require 'sidekiq/throttler'

# Rate limit at 10 jobs from `my_queue` per minute
Sidekiq.rate_limit(:my_queue, at: 10, per: 60)
```