require 'payeezy/version'
require 'rest_client'
require 'date'
require 'json'
require 'digest/sha2'
require 'base64'
require 'securerandom'
require 'benchmark'

module Payeezy
  class Transactions
    @@log_transaction_time = false
    @@logging_proc = nil

    # Class methods
    def self.transaction_time_logging_on!(&block)
      @@log_transaction_time = true
      @@logging_proc = block
    end

    def self.transaction_time_logging_off!
      @@log_transaction_time = false
      @@logging_proc = nil
    end

    # Object methods

    def initialize(options = {})
      @url = options[:url] || options["url"]
      @apikey = options[:apikey] || options["apikey"]
      @apisecret = options[:apisecret] || options["apisecret"]
      @token = options[:token] || options["token"]
    end

    def transact(action, payload)
      commit(action, payload)
    end

    def generate_hmac(nonce, current_timestamp, payload)
      message = @apikey + nonce.to_s + current_timestamp.to_s + @token + payload
      hash = Base64.strict_encode64(bin_to_hex(OpenSSL::HMAC.digest('sha256', @apisecret, message)))
      hash
    end

    def bin_to_hex(s)
      s.unpack('H*').first
    end

    def headers(payload)
      nonce = (SecureRandom.random_number *10000000000)
      current_timestamp = (Time.now.to_f*1000).to_i
      {
          'Content-Type' => 'application/json',
          'apikey' => @apikey,
          'token' => @token,
          'nonce' => nonce,
          'timestamp' => current_timestamp,
          'Authorization' => generate_hmac(nonce, current_timestamp, payload)
      }
    end

    def commit(action, params)
      url = @url
      if [Actions::CAPTURE, Actions::VOID, Actions::REFUND, Actions::SPLIT].include?(action)
        url = url + '/' + params[:transaction_id]
        params.delete(:transaction_id)
      end
      params[:transaction_type] = action
      call_rest(url, post_data(params), headers(post_data(params)))
    end

    def call_rest(url, data, headers)
      rest_resource = RestClient::Resource.new(url)
      raw_response = response = {}
      begin
        do_logged_transaction(url) do
          raw_response = rest_resource.post data, headers
          response = Payeezy::Response.new(raw_response)
        end
      rescue => e
        if e.respond_to?(:response)
          response = Payeezy::Response.new(e.response)
        else
          response = Payeezy::InternalErrorResponse.new(e)
        end
      rescue JSON::ParserError => e
        response = Payeezy::InternalErrorResponse.new(e)
      end

      response
    end

    def handle_message(response, success)
      if success
        response['transaction_status']
      elsif response.key?('Error')
        response['Error'].map { |_, messages| messages }.join('. ')
      else
        response.inspect
      end
    end

    def response_error(raw_response)
      begin
        parse(raw_response)
      rescue JSON::ParserError
        json_error(raw_response)
      end
    end

    def parse(body)
      JSON.parse(body)
    end

    def post_data(params)
      params.to_json
    end

    def json_error(raw_response)
      msg = "Payeezy has returned an invalid response: [#{raw_response.inspect}]"
      {
          'Error' => {
              'messages' => msg
          }
      }
    end

    private

    def do_logged_transaction(url)
      if @@log_transaction_time
        time = Benchmark.measure do
          yield
        end
        @@logging_proc.call(<<-LOG)

        ============= PAYEEZY TRANSACTION LOG ==============
        METHOD: POST
        URL:    #{url}
        TIME:   #{time}
        ====================================================
        LOG
      else
        yield
      end
    end
  end
end
