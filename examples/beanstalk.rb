$:.unshift ::File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'raemon'
require 'beanstalk-client'

class JobWorker
  include Raemon::Worker
  
  def start
    logger.info "=> Starting worker #{Process.pid}"
    
    @beanstalk = Beanstalk::Pool.new(['localhost:11300'])
  end
  
  def stop
    logger.info "=> Stopping worker #{Process.pid}"
    
    @beanstalk.close
    exit
  end
  
  def execute
    loop do
      stop if shutting_down?
    
      begin
        job = @beanstalk.reserve(2)
      rescue Beanstalk::TimedOut
      end
      
      if job
        logger.info "(#{Process.ppid}:#{Process.pid}) got job: #{job.inspect}"
        
        # process job here ...
        job.delete
      end
    end
  end

end

ROOT_DIR = File.expand_path('~')

# Raemon::Master.startup 3, JobWorker, {
#   :detach   => true,
#   :logger   => Logger.new("#{ROOT_DIR}/beanstalk.log"),
#   :pid_file => "#{ROOT_DIR}/beanstalk.pid"
# }

Raemon::Master.startup 3, JobWorker
