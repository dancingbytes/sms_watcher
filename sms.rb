# encoding: utf-8

# SMS.login('you@email.address', 'password')
# SMS.message('78887779999', 'Привет')

module SMS

  HOST      = 'api.sms24x7.ru'
  PHONE_RE  = /\A(\+7|7|8)(\d{10})\Z/

  class TimeoutError < ::StandardError; end
  class SessionExpired < ::StandardError; end
  class BaseError < ::StandardError; end
  class InterfaceError < ::StandardError; end
  class AuthError < ::StandardError; end
  class NoLoginError < ::StandardError; end
  class BalanceError < ::StandardError; end
  class SpamError < ::StandardError; end
  class EncodingError < ::StandardError; end
  class NoGateError < ::StandardError; end
  class OtherError < ::StandardError; end

  class << self

    def valid_phone?(phone)
      !(phone.to_s.gsub(/\D/, "") =~ ::SMS::PHONE_RE).nil?
    end # valid_phone?

    def convert_phone(phone, prefix = "7")

      r = phone.to_s.gsub(/\D/, "").scan(::SMS::PHONE_RE)
      r.empty? ? nil : "#{prefix}#{r.last.last}"

    end # convert_phone

    def login(email, password, secure = true)

      @email      = email
      @password   = password
      @secure     = secure
      auth

      self

    end # login

    def message(phone, text, params = {})

      request = {
        :method   => 'push_msg',
        :unicode  => 1,
        :phone    => phone,
        :text     => text
      }.merge(params)

      begin
        data = request(request)[:data]
      rescue ::SMS::TimeoutError, ::SMS::SessionExpired
        logout
        auth
        retry
      end

      unless (n_raw_sms = data['n_raw_sms']) && (credits = data['credits'])
        raise ::SMS::InterfaceError, "Could not find 'n_raw_sms' or 'credits' in successful push_msg response"
      end

      data

    end # message

    def logout

      request({
        :method => 'logout'
      })
      @cookie = nil
      self

    end # logout

    private

    def auth

      return if @cookie

      responce = request({
        :method   => 'login',
        :email    => @email,
        :password => @password
      })

      raise ::SMS::InterfaceError, "Login request OK, but no 'sid' set" unless (sid = responce[:data]["sid"])
      @cookie = "sid=#{::CGI::escape(sid)}"

    end # auth

    def request(request = {})

      request[:format] = "json"

      if @secure
        http = ::Net::HTTP.new(::SMS::HOST, 443)
        http.use_ssl = true
        http.verify_mode = ::OpenSSL::SSL::VERIFY_NONE
      else
        http = ::Net::HTTP.new(::SMS::HOST, 80)
      end

      header = {}
      header["Cookie"] = @cookie if @cookie

      res   = http.post('/', ::URI.encode_www_form(request), header)
      json  = ::JSON.parse(res.body)

      unless (response = json['response']) && (msg = response['msg']) && (error_code = msg['err_code'])
        raise ::SMS::InterfaceError, 'Empty some necessary data fields'
      end

      if (error_code = error_code.to_i) > 0

        case error_code.to_i
          when 2  then raise ::SMS::AuthError, 'AuthError'
          when 3  then raise ::SMS::TimeoutError, 'TimeoutError'
          when 18 then raise ::SMS::SessionExpired, 'SessionExpired'
          when 29 then raise ::SMS::NoGateError, 'NoGateError'
          when 35 then raise ::SMS::EncodingError, 'EncodingError'
          when 36 then raise ::SMS::BalanceError, 'No money'
          when 37, 38, 59 then raise ::SMS::SpamError, 'Spam'
          when 42 then raise ::SMS::NoLoginError, 'NoLoginError'
          else raise ::SMS::OtherError, "Communication to API failed. Error code: #{error_code}"
        end

      end # if

      { :error_code => error_code, :data => response['data'] }

    end # request

  end # class << self

end # SMS