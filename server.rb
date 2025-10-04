require 'roda'
require 'json'
require 'net/http'
require 'uri'

class OllamaManagerApp < Roda
  plugin :streaming
  plugin :json

  route do |r|
    # Serve the main HTML file at root
    r.root do
      response['Content-Type'] = 'text/html'
      File.read(File.join(__dir__, 'ollama-manager.html'))
    end

    # Proxy API requests to Ollama servers
    r.on 'api' do
      r.on 'proxy' do
        # POST /api/proxy/stream - proxy streaming requests (for pull operations)
        r.on 'stream' do
          r.post do
            data = JSON.parse(r.body.read)
            server_url = data['server_url']
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
          server_url = data['server_url']
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
