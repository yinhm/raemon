$:.unshift ::File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'raemon'

class Test
  include Raemon::Worker
  
  def start
    logger.info "=> Starting worker #{Process.pid}"
  end

  def stop
    logger.info "=> Stopping worker #{Process.pid}"
    exit
  end

  def execute
    loop do
      stop if shutting_down?
    
      logger.warn "I'm executing .. #{Process.ppid}:#{Process.pid}"
      sleep 2
    end
  end

end

Raemon::Master.startup 3, Test
