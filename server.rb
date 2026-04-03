require 'roda'
require 'json'
require 'net/http'
require 'uri'
require 'securerandom'

# In-memory store for background pull jobs.
# Jobs are removed after 1 hour to prevent unbounded growth.
PULL_JOBS = {}
ACTIVE_PULLS = {}  # (server_url, model_name) -> job_id for deduplication
PULL_JOBS_MUTEX = Mutex.new

def store_job(job_id, attrs)
  PULL_JOBS_MUTEX.synchronize { PULL_JOBS[job_id].merge!(attrs) }
end

def cleanup_old_jobs
  cutoff = Time.now - 3600
  PULL_JOBS_MUTEX.synchronize do
    PULL_JOBS.delete_if { |_, j| j[:finished_at] && j[:finished_at] < cutoff }
  end
end

class OllamaManagerApp < Roda
  plugin :streaming
  plugin :json

  # On Docker Desktop (macOS/Windows), localhost inside the container refers to
  # the container itself, not the host machine. Set LOCALHOST_ALIAS=host.docker.internal
  # to transparently rewrite localhost/127.0.0.1 in proxied server URLs.
  def self.resolve_server_url(url)
    alias_host = ENV['LOCALHOST_ALIAS']
    return url unless alias_host && !alias_host.empty?
    url.gsub(/\blocalhost\b|\b127\.0\.0\.1\b/, alias_host)
  end

  route do |r|
    # Serve the main HTML file at root
    r.root do
      response['Content-Type'] = 'text/html'
      File.read(File.join(__dir__, 'ollama-manager.html'))
    end

    # Proxy API requests to Ollama servers
    r.on 'api' do

      # Background pull job endpoints
      r.on 'pull' do
        # GET /api/pull/:id - poll job progress
        r.get String do |job_id|
          cleanup_old_jobs
          job = PULL_JOBS_MUTEX.synchronize { PULL_JOBS[job_id]&.dup }
          if job
            job
          else
            response.status = 404
            { error: 'Job not found' }
          end
        end

        # POST /api/pull - start a background pull, returns { job_id }
        r.post do
          data = JSON.parse(r.body.read)
          server_url = OllamaManagerApp.resolve_server_url(data['server_url'])
          model_name = data['model_name']
          pull_key = "#{server_url}|#{model_name}"

          # Return existing job if this model is already being pulled on that server
          existing_job_id = PULL_JOBS_MUTEX.synchronize { ACTIVE_PULLS[pull_key] }
          if existing_job_id
            next({ job_id: existing_job_id, resumed: true })
          end

          job_id = SecureRandom.uuid
          PULL_JOBS_MUTEX.synchronize do
            PULL_JOBS[job_id] = { status: 'pulling', progress: 'Starting…', error: nil }
            ACTIVE_PULLS[pull_key] = job_id
          end

          Thread.new do
            begin
              uri = URI.parse("#{server_url}/api/pull")
              Net::HTTP.start(uri.host, uri.port, read_timeout: 600) do |http|
                request = Net::HTTP::Post.new(uri.request_uri)
                request.body = { name: model_name }.to_json
                request['Content-Type'] = 'application/json'

                http.request(request) do |res|
                  res.read_body do |chunk|
                    chunk.split("\n").each do |line|
                      next if line.strip.empty?
                      begin
                        parsed = JSON.parse(line)
                        text = parsed['status'] || ''
                        if parsed['total'].to_i > 0
                          pct = (parsed['completed'].to_f / parsed['total'] * 100).round
                          text = "#{text} #{pct}%"
                        end
                        store_job(job_id, progress: text)
                      rescue JSON::ParserError
                        # ignore malformed chunks
                      end
                    end
                  end
                end
              end
              store_job(job_id, status: 'done', finished_at: Time.now)
            rescue => e
              store_job(job_id, status: 'error', error: e.message, finished_at: Time.now)
            ensure
              PULL_JOBS_MUTEX.synchronize { ACTIVE_PULLS.delete(pull_key) }
            end
          end

          { job_id: job_id }
        end
      end

      r.on 'proxy' do
        # POST /api/proxy/stream - proxy streaming requests (for pull operations)
        r.on 'stream' do
          r.post do
            data = JSON.parse(r.body.read)
            server_url = OllamaManagerApp.resolve_server_url(data['server_url'])
            endpoint = data['endpoint']
            body = data['body']

            stream do |out|
              begin
                uri = URI.parse("#{server_url}#{endpoint}")
                
                Net::HTTP.start(uri.host, uri.port, read_timeout: 600) do |http|
                  request = Net::HTTP::Post.new(uri.request_uri)
                  request.body = body.to_json if body
                  request['Content-Type'] = 'application/json'
                  
                  http.request(request) do |res|
                    res.read_body do |chunk|
                      out << chunk
                    end
                  end
                end
              rescue => e
                out << JSON.generate({ error: e.message, backtrace: e.backtrace.first(5) })
              end
            end
          end
        end

        # POST /api/proxy - proxy regular requests to Ollama servers
        r.post do
          data = JSON.parse(r.body.read)
          server_url = OllamaManagerApp.resolve_server_url(data['server_url'])
          endpoint = data['endpoint']
          method = data['method'] || 'GET'
          body = data['body']

          begin
            uri = URI.parse("#{server_url}#{endpoint}")
            http = Net::HTTP.new(uri.host, uri.port)
            http.read_timeout = 300 # 5 minutes for long operations
            
            case method.upcase
            when 'GET'
              request = Net::HTTP::Get.new(uri.request_uri)
            when 'POST'
              request = Net::HTTP::Post.new(uri.request_uri)
              request.body = body.to_json if body
              request['Content-Type'] = 'application/json'
            when 'DELETE'
              request = Net::HTTP::Delete.new(uri.request_uri)
              request.body = body.to_json if body
              request['Content-Type'] = 'application/json'
            else
              response.status = 400
              { error: 'Unsupported method' }
            end

            res = http.request(request)
            
            # Set response status and content type
            response.status = res.code.to_i
            response['Content-Type'] = res['content-type'] || 'application/json'
            
            res.body
          rescue => e
            response.status = 500
            { error: e.message, details: e.backtrace.first(5) }
          end
        end
      end
    end
  end
end
