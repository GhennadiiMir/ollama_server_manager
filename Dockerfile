# Use official Ruby image
FROM ruby:3.4-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
  build-essential \
  curl \
  && rm -rf /var/lib/apt/lists/*

# The Debian base image ships with `mdns4_minimal [NOTFOUND=return]` in
# nsswitch.conf, which prevents short hostnames (Tailscale, VPN, mDNS, custom
# /etc/hosts entries) from ever reaching the system DNS resolver. With
# network_mode: host the container shares the host's resolver (127.0.0.53), so
# simply switching to `files dns` makes any name the host can resolve work here.
RUN sed -i 's/^hosts:.*/hosts: files dns/' /etc/nsswitch.conf

# Copy Gemfile and Gemfile.lock
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle config set --local deployment 'true' && \
  bundle config set --local without 'development test' && \
  bundle install

# Copy application code
COPY . .

# Create necessary directories for Puma
RUN mkdir -p tmp/pids log

# Create a non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser appuser
RUN chown -R appuser:appuser /app
USER appuser

# Expose port
EXPOSE 9292

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:9292/ || exit 1

# Start the application
CMD ["bundle", "exec", "puma", "-C", "puma.rb"]