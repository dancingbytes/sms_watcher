# encoding: utf-8
require "json"
require "cgi"
require "uri"
require "timeout"
require "open3"
require ::File.expand_path('../sms', __FILE__)

module Watcher

  extend self

  SITES_DIR = ::File.expand_path('../../sites', __FILE__)
  TMP_DIR   = ::File.expand_path('../../tmp',   __FILE__)
  LOCKLIFE  = 30*60 # 30 минут
  TIMEOUT   = 30    # 30 секунд

  def run

    begin

      # Файл блокировки
      flock = ::File.join(::Watcher::TMP_DIR, ".watcher.lock")

      # Если файл блокировки уже есть - завершаем работу.
      if locked?(flock)
        puts "[LOCK] Lock file found: `#{flock}`."
        return
      end

      # Иначе, создаем файл
      create_lock(flock, "watcher")

      # Выполняем блок
      begin
        check_all
      ensure
        # Все зависмости от того, как выполнился блок, удаляем файл блокировки,
        remove_lock(flock)
      end

    # Если поймана ошибка доступа -- игнорируем её.
    rescue ::Errno::EACCES
    end

  end # run

  private

  def check_all

    # Проверяем сайты по списку
    get_sites do |site, phones|

      # Проверяем сакйт/севрер на доступность/недоступность
      check(site) do |success, type|

        # Что бы не слать каждые 10 минут смс, создаем файл блокировки
        lock = generate_lock(site)

        name = (type == 0 ? "Сайт" : "Сервер")

        # Если результат проверки отрицательный (сайт не доступен)
        unless success

          # Если файл блокировки задан и дата создания валидна (файл не старее указанного периода)
          # то, переходим на следующую итерацию цикла
          next if locked?(lock)

          # Иначе, создаем файл блокировку
          create_lock(lock, site)

          # Шлем сообщения
          send_message(phones, "#{name} #{site} не доступен. #{::Time.now}")

        else

          # Сайт доступен. Если была блокировка, удаляем её и шлем сообщение о доступности сайта.
          send_message(phones, "#{name} #{site} доступен. #{::Time.now}") if remove_lock(lock)

        end # if

      end # check

    end # get_sites

  end # check_all

  def get_sites

    ::Dir.foreach(::Watcher::SITES_DIR) { |el|

      file = ::File.join(::Watcher::SITES_DIR, el)

      # Если не является файлом или имя начинается с точки -- пропускаем!
      next if !::File.file?(file) || !(el =~ /\A\./).nil?

      # Выбирааем из файла название (названием сайта или сервера, которое мы потом проверим :) )
      site    = el
      phones  = []

      # Читаем файл и построчно выбираем телефоны
      ::File.open(file, "r") { |fl|

        ::IO.readlines(fl).each { |line|
          phones << (line || [])
        }

      }

      phones.compact!
      phones.uniq!

      # Выполняем блок с полученными данными, если указаны теефоны (иначе нет смысла слать оповещения)
      yield(site, phones) unless phones.empty?

    } # foreach

  end # get_sites

  # Хитро генерим из адреса сайта название файла
  def generate_lock(site_name)
    ::File.join(::Watcher::TMP_DIR, "#{site_name}.lock")
  end # generate_lock

  # Создаем файл блокировки, записываем в него название сайта и время записи.
  def create_lock(file, site)

    ::File.open(file, "w") { |f|
      f.write("#{site} - #{::Time.now.strftime('%H:%M, %d/%m/%Y')}")
    }

  end # create_lock

  # Рассылаем сообщения str на телефоны phones
  def send_message(phones, str)

    phones.each do |phone|

      begin
        ::SMS.message(phone, str)
      rescue ::SocketError
      rescue => e
        puts "[SMS message error] #{e.message}"
      end

    end # each

  end # send_message

  def locked?(lock)

    # Если файла блокировки не существут -- false
    return false unless ::File.exists?(lock)

    # Если файла блокировки имеется и не устарел -- успех
    return true  if (::Time.now.to_i - ::File.atime(lock).to_i) < ::Watcher::LOCKLIFE

    # Иначе удаляекм файл блокировки -- false
    ::File.unlink(lock)
    false

  end # locked?

  # Если файл блокировки существует -- удаляем и сообщаем об успехе, иначе false
  def remove_lock(lock)

    if ::File.exists?(lock)
      ::File.unlink(lock)
      true
    else
      false
    end

  end # remove_lock

  def check(site, &block)

    if ip?(site)
      check_ip(site, &block)
    else
      check_domain(site, &block)
    end

  end # check

  def ip?(address)
    !(address =~ /\A((([01]?\d{1,2})|(2([0-4]\d|5[0-5])))\.){3}(([01]?\d{1,2})|(2([0-4]\d|5[0-5])))\Z/).nil?
  end # ip?

  def check_ip(address)

    stdin, stdout, stderr = nil, nil, nil

    begin

      cmd    = "ping -c 1 #{address}"
      regexp = /
        no\ answer|
        host\ unreachable|
        could\ not\ find\ host|
        request\ timed\ out|
        100%\ packet\ loss
      /ix

      # Проверям доступность сайта
      ::Timeout.timeout(::Watcher::TIMEOUT) {

        stdin, stdout, stderr = ::Open3.popen3(cmd)

        stdout.readlines.each { |line|
          if regexp.match(line)
            yield(false, 1)
            break
          end
        }

      }

    rescue ::SocketError
    rescue => e

      puts "#{e.message}\n"
      puts "#{e.backtrace.join('\n')}"
      # Возникла какая-то ошибка
      yield(false, 1)

    ensure
      # Закрываем все файловые дескрипторы
      stdin.close  if stdin && !stdin.closed?
      stdout.close if stdout && !stdout.closed?
      stderr.close if stderr && !stderr.closed?
    end

  end # check_ip

  def check_domain(name)

    # Строим url
    url = ::URI.extract("http://#{name}").first

    # Если ничего не получилось -- завершаем работу
    return unless url

    # Проверям доступность сайта
    begin

      ::Timeout::timeout(::Watcher::TIMEOUT) {

        req = ::Net::HTTP.get_response(URI(url))
        yield(req.is_a?(::Net::HTTPSuccess), 0)

      }

    rescue ::SocketError
    rescue => e

      puts "#{e.message}\n"
      puts "#{e.backtrace.join('\n')}"
      # Возникла какая-то ошибка
      yield(false, 0)

    end

  end # check_domain

end # Watcher