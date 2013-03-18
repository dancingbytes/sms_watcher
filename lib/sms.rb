# encoding: utf-8
require "net/http"

# SMS.login('you@email.address', 'password')
# SMS.message('79630897252', 'Привет')

module SMS

  HOST      = 'api.sms24x7.ru'
  PHONE_RE  = /\A(\+7|7|8)(\d{10})\Z/

  class Error < ::StandardError; end

  class AuthError < ::SMS::Error; end
  class TimeoutError < ::SMS::Error; end

  class AccountBlockedError < ::SMS::Error; end
  class UndefinedError < ::SMS::Error; end
  class ApiVersionError < ::SMS::Error; end
  class ArgumentsError < ::SMS::Error; end
  class UnauthorizedPartnerError < ::SMS::Error; end
  class SaveError < ::SMS::Error; end
  class ActionRejectedError < ::SMS::Error; end
  class PasswordError < ::SMS::Error; end
  class SessionExpiredError < ::SMS::Error; end
  class AccountNotFoundError < ::SMS::Error; end
  class SenderNameError < ::SMS::Error; end
  class DeliveryError < ::SMS::Error; end

  class DomainBusyError < ::SMS::Error; end
  class TarifNotFoundError < ::SMS::Error; end
  class MessagesNotDeliveryError < ::SMS::Error; end

  class BaseError < ::SMS::Error; end
  class InterfaceError < ::SMS::Error; end
  class NoLoginError < ::SMS::Error; end
  class BalanceError < ::SMS::Error; end
  class SpamError < ::SMS::Error; end
  class EncodingError < ::SMS::Error; end
  class NoGateError < ::SMS::Error; end
  class OtherError < ::SMS::Error; end

  class << self

    def valid_phone?(phone)
      !((phone || "").to_s.gsub(/\D/, "") =~ ::SMS::PHONE_RE).nil?
    end # valid_phone?

    def convert_phone(phone, prefix = "7")

      r = (phone || "").to_s.gsub(/\D/, "").scan(::SMS::PHONE_RE)
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
      rescue ::SMS::TimeoutError, ::SMS::SessionExpiredError
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

      sid = responce[:data]["sid"]
      raise ::SMS::InterfaceError, "Login request OK, but no 'sid' set" if sid.nil?
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

      res = http.post('/', ::URI.encode_www_form(request), header)

      if res.code.to_i != 200
        raise ::SMS::InterfaceError, "#{res.message} (#{res.code})"
      end

      json = ::JSON.parse(res.body) rescue {}

      unless (response = json['response']) && (msg = response['msg']) && (error_code = msg['err_code'])
        raise ::SMS::InterfaceError, 'Empty some necessary data fields'
      end

      if (error_code = error_code.to_i) > 0

        case error_code

          when 2    then raise ::SMS::AuthError, 'AuthError. Неверный логин или пароль.'
          when 3    then raise ::SMS::TimeoutError, 'TimeoutError. Вы были неактивный более 24 минут. В целях безопасности авторизуйтесь заново.'

          when 4    then raise ::SMS::AccountBlockedError, 'AccountBlockedError. Ваш аккаутн заблокирован, обратитесь к администратору.'
          when 5    then raise ::SMS::UndefinedError, 'UndefinedError. Неизвестный метод.'
          when 6    then raise ::SMS::ApiVersionError, 'ApiVersionError. Указанной версии API не существует.'
          when 7    then raise ::SMS::ArgumentsError, 'ArgumentsError. Заданы не все необходимые параметры.'
          when 10   then raise ::SMS::UnauthorizedPartnerError, 'UnauthorizedPartnerError. Данный партнер не авторизован.'
          when 11   then raise ::SMS::SaveError, 'SaveError. При сохранении произошла ошибка.'
          when 15   then raise ::SMS::ActionRejectedError, 'ActionRejectedError. Действие запрещено.'
          when 16   then raise ::SMS::PasswordError, 'PasswordError. Пароль указан неверно.'
          when 18   then raise ::SMS::SessionExpiredError, 'SessionExpiredError. Сессия устарела.'
          when 19   then raise ::SMS::Error, 'Error. Произошла ошибка.'

          when 22   then raise ::SMS::AccountNotFoundError, 'AccountNotFoundError. Учетной записи не существует.'

          when 29 then raise ::SMS::NoGateError, 'NoGateError. Сотовый оператор не подключен.'
          when 35 then raise ::SMS::EncodingError, 'EncodingError. Кодировка текста сообщения не соотвествует заявленной.'
          when 36 then raise ::SMS::BalanceError, 'BalanceError. Недостаточно средств, пополните баланс.'
          when 37, 38, 59 then raise ::SMS::SpamError, 'Spam'

          when 39 then raise ::SMS::SenderNameError, 'SenderNameError. Недопустимое имя отправителя.'
          when 40 then raise ::SMS::DeliveryError, 'DeliveryError. Невозможно доставить.'
          when 42 then raise ::SMS::NoLoginError, 'NoLoginError. Авторизуйтесь, чтобы продолжить.'

          when 43 then raise ::SMS::DomainBusyError, 'DomainBusyError. Домен занят.'
          when 45 then raise ::SMS::BaseError, 'BaseError. Не найдены базоввые настройки кабинета.'
          when 44, 47 then raise ::SMS::TarifNotFoundError, 'TarifNotFoundError. Не найден преднастроенный тариф, доступный при регистрации.'

          when 58 then raise ::SMS::MessagesNotDeliveryError, 'MessagesNotDeliveryError. Ни одного сообщения отправлено не было.'

          else raise ::SMS::OtherError, "Communication to API failed. Error code: #{error_code}"
        end

      end # if

      { :error_code => error_code, :data => response['data'] }

    end # request

  end # class << self

end # SMS