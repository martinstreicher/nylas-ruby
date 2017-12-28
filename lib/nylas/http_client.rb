module Nylas
  # Plain HTTP client that can be used to interact with the Nylas API sans any type casting.
  class HttpClient
    HTTP_CODE_TO_EXCEPTIONS = {
      400 => InvalidRequest,
      402 => MessageRejected,
      403 => AccessDenied,
      404 => ResourceNotFound,
      405 => MethodNotAllowed,
      422 => MailProviderError,
      429 => SendingQuotaExceeded,
      500 => InternalError,
      501 => EndpointNotYetImplemented,
      502 => BadGateway,
      503 => ServiceUnavailable
    }.freeze

    include Logging
    attr_accessor :api_server, :service_domain
    attr_writer :default_headers
    attr_reader :access_token
    attr_reader :app_id
    attr_reader :app_secret

    # @param app_id [String] Your application id from the Nylas Dashboard
    # @param app_secret [String] Your application secret from the Nylas Dashboard
    # @param access_token [String] (Optional) Your users access token.
    # @param api_server [String] (Optional) Which Nylas API Server to connect to. Only change this if
    #                            you're using a self-hosted Nylas instance.
    # @param service_domain [String] (Optional) Host you are authenticating OAuth against.
    # @return [Nylas::HttpClient]
    def initialize(app_id:, app_secret:, access_token: nil, api_server: "https://api.nylas.com",
                   service_domain: "api.nylas.com")
      unless api_server.include?("://")
        raise "When overriding the Nylas API server address, you must include https://"
      end
      @api_server = api_server
      @access_token = access_token
      @app_secret = app_secret
      @app_id = app_id
      @service_domain = service_domain
    end

    # @return [Nylas::HttpClient[]
    def as(access_token)
      HttpClient.new(app_id: app_id, access_token: access_token,
                     app_secret: app_secret, api_server: api_server, service_domain: service_domain)
    end

    # Sends a request to the Nylas API and rai
    # @param method [Symbol] HTTP method for the API call. Either :get, :post, :delete, or :patch
    # @param url [String] (Optional, defaults to nil) - Full URL to access. Deprecated and will be removed in
    #                     5.0.
    # @param path [String] (Optional, defaults to nil) - Relative path from the API Base. Preferred way to
    #                      execute arbitrary or-not-yet-SDK-ified API commands.
    # @param headers [Hash] (Optional, defaults to {}) - Additional HTTP headers to include in the payload.
    # @param query [Hash] (Optional, defaults to {}) - Hash of names and values to include in the query
    #                      section of the URI fragment
    # @param payload [String,Hash] (Optional, defaults to nil) - Body to send with the request.
    # @return [Array Hash Stringn]
    # rubocop:disable Metrics/ParameterLists
    def execute(method:, url: nil, path: nil, headers: {}, query: {}, payload: nil)
      headers[:params] = query
      url ||= url_for_path(path)
      resulting_headers = default_headers.merge(headers)
      rest_client_execute(method: method, url: url, payload: payload,
                          headers: resulting_headers) do |response, _request, result|

        response = parse_response(response)
        handle_failed_response(result: result, response: response)
        response
      end
    end
    # rubocop:enable Metrics/ParameterLists
    inform_on :execute, level: :debug,
                        also_log: { result: true, values: %i[method url path headers query payload] }

    # Syntactical sugar for making GET requests via the API.
    # @see #execute
    def get(path: nil, url: nil, headers: {}, query: {})
      execute(method: :get, path: path, query: query, url: url, headers: headers)
    end

    # Syntactical sugar for making POST requests via the API.
    # @see #execute
    def post(path: nil, url: nil, payload: nil, headers: {}, query: {})
      execute(method: :post, path: path, url: url, headers: headers, query: query, payload: payload)
    end

    # Syntactical sugar for making PUT requests via the API.
    # @see #execute
    def put(path: nil, url: nil, payload:, headers: {}, query: {})
      execute(method: :put, path: path, url: url, headers: headers, query: query, payload: payload)
    end

    # Syntactical sugar for making DELETE requests via the API.
    # @see #execute
    def delete(path: nil, url: nil, payload: nil, headers: {}, query: {})
      execute(method: :delete, path: path, url: url, headers: headers, query: query, payload: payload)
    end
    # rubocop:enable Metrics/ParameterList

    private def rest_client_execute(method:, url:, headers:, payload:, &block)
      ::RestClient::Request.execute(method: method, url: url, payload: payload,
                                    headers: headers, &block)
    end
    inform_on :rest_client_execute, level: :debug,
                                    also_log: { result: true, values: %i[method url headers payload] }

    def default_headers
      @default_headers ||= {
        "X-Nylas-API-Wrapper" => "ruby",
        "User-Agent" => "Nylas Ruby SDK #{Nylas::VERSION} - #{RUBY_VERSION}",
        "Content-types" => "application/json"
      }
    end

    private def parse_response(response)
      response.is_a?(Enumerable) ? response : JSON.parse(response, symbolize_names: true)
    rescue JSON::ParserError
      response
    end
    inform_on :parse_response, level: :debug, also_log: { result: true }

    private def url_for_path(path)
      protocol, domain = api_server.split("//")
      "#{protocol}//#{access_token}:@#{domain}#{path}"
    end

    private def handle_failed_response(result:, response:)
      http_code = result.code.to_i

      handle_anticipated_failure_mode(http_code: http_code, response: response)
      raise UnexpectedResponse, result.msg if result.is_a?(Net::HTTPClientError)
    end

    private def handle_anticipated_failure_mode(http_code:, response:)
      return if http_code == 200
      return unless response.is_a?(Hash)
      exception = HTTP_CODE_TO_EXCEPTIONS.fetch(http_code, APIError)
      raise exception.new(response[:type], response[:message], response.fetch(:server_error, nil))
    end
  end
end