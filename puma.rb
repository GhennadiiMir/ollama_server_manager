# Puma configuration file

# Port to listen on
port ENV.fetch('PORT', 9292)

# Number of worker processes
# Set to 0 for single mode (development)
# Set to number of CPU cores for production
workers ENV.fetch('WEB_CONCURRENCY', 0)

# Number of threads per worker
threads_count = ENV.fetch('PUMA_THREADS', 5).to_i
threads threads_count, threads_count

# Preload the application for better performance in production
preload_app!

# Allow Puma to be restarted by `bin/rails restart` command
plugin :tmp_restart

# Specify the environment
environment ENV.fetch('RACK_ENV', 'development')

# Logging
stdout_redirect ENV.fetch('PUMA_STDOUT', 'log/puma.stdout.log'), 
                ENV.fetch('PUMA_STDERR', 'log/puma.stderr.log'), 
                true unless ENV['RACK_ENV'] == 'development'

# Pidfile location
pidfile ENV.fetch('PIDFILE', 'tmp/pids/puma.pid') unless ENV['RACK_ENV'] == 'development'
