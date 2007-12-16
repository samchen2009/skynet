class Skynet
  
  class Worker

    include SkynetDebugger
    
    include Skynet::GuidGenerator

    RETRY_TIME = 2
    VERSION_CHECK_DELAY = 5
    MAX_MEMORY = 500
    MEMORY_CHECK_DELAY = 30
    MANAGER_PING_INTERVAL = 60

    attr_accessor :message,:task, :mq, :processed
    attr_reader :worker_id, :worker_info, :worker_type
    
    class Error < StandardError
    end

    class RespawnWorker < Skynet::Error
    end

    class ConnectionFailure < Skynet::Error
    end
    
    class NoManagerError < Skynet::Error
    end

    def self.debug_class_desc
      "WORKER-#{$$}"
    end
    
    def initialize(worker_type=:any)
      @worker_id = get_unique_id(1).to_i
			@mq = Skynet::MessageQueue.new
			@worker_type = worker_type.to_sym
      @processed = 0
      debug "THIS WORKER TAKES #{worker_type}"

	    @worker_info = { 
	      :hostname   => hostname,
	      :process_id => process_id,
        :worker_type => payload_type, 
        :worker_id  => worker_id,
        :version    => mq.get_worker_version
	    }
    end

    def process_id
      $$
    end
    
    def hostname
      @machine_name ||= Socket.gethostname
    end       
    
    def version
      @curver
    end
        
    def new_version_respawn?
       if !@verchecktime
        @verchecktime = Time.now
        begin 
          @curver = mq.get_worker_version
          debug "FINDING INITIAL VER #{@curver}"
        rescue  Skynet::RequestExpiredError => e
          warn "NO INITIAL VER IN MQ using 1"
          @curver = 1
        end
      else    
        if Time.now < (@verchecktime + VERSION_CHECK_DELAY)
          return false
        else                    
          @verchecktime = Time.now
          begin
            newver = mq.get_worker_version
            # debug "CURVER #{@curver} NEWVER: #{newver}"
            if newver != @curver
              info "RESTARTING WORKER ON PID #{$$}"
              return true
            end
          rescue Skynet::RequestExpiredError => e
            warn "NO CURRENT WORKER REV IN MQ still using 1"
            mq.set_worker_version(1)
            return false
          end
        end
      end
      return false
    end                     


    def take_worker_status
      begin               
        mq.take_worker_status(@worker_info,0.00001)
      rescue Skynet::RequestExpiredError, Skynet::QueueTimeout => e
        error "Couldnt take worker status for #{hostname} pid: #{process_id}"
      end
    end
    
    def notify_worker_started
      mq.write_worker_status(
        @worker_info.merge({
          :name       => "waiting for #{@worker_type}",
          :processed  => 0,
          :started_at    => Time.now.to_i
        })
      )
    end
    
    def notify_task_begun(task)
      task[:processed] = @processed
      task[:started_at] = Time.now.to_i
      mq.write_worker_status(@worker_info.merge(task))
    end
    
    def notify_task_complete
      @processed += 1

      mq.write_worker_status(
        @worker_info.merge({
          :task_id       => 0,
          :job_id        => 0,
          :name       => "waiting for #{@worker_type}",
          :processed     => @processed,
          :map_or_reduce => nil,
          :started_at    => Time.now.to_i
        })
      )
    end 
    
    def notify_worker_stop
      info "Worker #{process_id} stopping..."
      take_worker_status
    end   
    
    def payload_type
      return nil if worker_type == :any
      return worker_type      
    end
          
    def start
      exceptions = 0
      conerror = 0
      @curver = nil
      # setup signal handlers for manager
      Signal.trap("HUP")  { @respawn = true }
      Signal.trap("TERM") do
        if @die
          exit
        else
          @die = true
        end        
      end
      Signal.trap("INT")  { @die = true }
    
      raise Skynet::Worker::RespawnWorker.new if new_version_respawn?
        
      info "STARTING WORKER @ VER #{@curver} (#{@worker_type})"

      notify_worker_started

      message = nil
      task = nil

      loop do
        message = nil      
        begin               
          if @die             
            exit                                  
          elsif @respawn
            raise Skynet::Worker::RespawnWorker.new 
          end

          if local_mem = max_memory_reached?
            raise Skynet::Worker::RespawnWorker.new("WORKER OVER MAX MEM AT: #{local_mem} MAX: #{MAX_MEMORY}")
          end
          
          if conerror > 0
            @mq = Skynet::MessageQueue.new
            warn "WORKER RECONNECTED AFTER #{conerror} tries"
            conerror = 0
          end

          # debug "1 START LOOPSSS at VER #{@curver}"
          # 
          # debug "LOOK FOR WORK USING TEMPLATE", Skynet::Message.task_template(@curver)
          # message = Skynet::Message.new(mq.take(Skynet::Message.task_template(@curver),0.00001))
          message = mq.take_next_task(@curver,0.00001,payload_type)

          next unless message.respond_to?(:payload)

          task = message.payload                          
          error "BAD MESSAGE", task unless task.respond_to?(:map_or_reduce)

          info "STEP 2 GOT MESSAGE #{message.name} type:#{task.map_or_reduce}, jobid: #{message.job_id}, taskid:#{message.task_id} it: #{message.iteration}"
          debug "STEP 2.1 message=", message.to_a
          # info "STEP 3 GOT TASK taskid: #{task.task_id}"
          # debug "STEP 3.1 task=", task
          next unless task
          # maybe instead of putting a time in the future, it puts the start time and an offset in seconds

          # task.debug "taking task #{task.task_id} name:#{task.name}..."

          info "STEP 4 RUNNING TASK #{message.name} jobid: #{message.job_id} taskid: #{task.task_id}"
          notify_task_begun({ 
            :job_id        => message.job_id, 
            :task_id       => message.task_id, 
            :iteration     => message.iteration, 
            :name          => message.name, 
            :map_or_reduce => task.map_or_reduce
          })
          result = task.run

          info "STEP 5 GOT RESULT FROM RUN TASK #{message.name} jobid: #{message.job_id} taskid: #{task.task_id}"
          debug "STEP 5.1 RESULT DATA:", result

          ## XXX need better result timeout
          result_message = mq.write_result(message,result,task.result_timeout)
          info "STEP 6 WROTE RESULT MESSAGE #{message.name} jobid: #{message.job_id} taskid: #{task.task_id}"
          # debug "STEP 6.1 RESULT_MESSAGE:", result_message
          notify_task_complete          
        rescue Skynet::Worker::RespawnWorker => e  
          info "Respawning and taking worker status"
          notify_worker_stop
          raise e          
        rescue Skynet::RequestExpiredError => e
          debug "request expired"
          if new_version_respawn?
            notify_worker_stop
            raise Skynet::Worker::RespawnWorker.new
          end
          sleep 1
          # debug "WORKER [#{$$}] LOOPING AGAIN"
          next
        rescue Skynet::ConnectionError, DRb::DRbConnError => e
          conerror += 1
          retry_time = conerror > 6 ? RETRY_TIME * 3 : RETRY_TIME
          error "#{e.message}, RETRY #{conerror} in #{retry_time} seconds !!"
          @mq = nil
          sleep retry_time
          if conerror > 20
            fatal "TOO MANY RECONNECTION EXCEPTIONS #{e.message}"
            notify_worker_stop
            raise e 
          end
          next
        rescue NoManagerError => e
          fatal e.message
          break          
        rescue Interrupt, SystemExit => e
          error "Exiting..."
          notify_worker_stop
          break
        rescue Exception => e
          error "#{e.inspect} #{e.backtrace.join("\n")}"
          #mq.take(@next_worker_message.task_template,0.0005) if message
          if message
            mq.write_error(message,"#{e.inspect} #{e.backtrace.join("\n")}",(task.respond_to?(:result_timeout) ? task.result_timeout : 200))
          else
            # what do we do here
            # mq.write_error(message,"ERROR in WORKER [#{$$}] #{e.inspect} #{e.backtrace.join("\n")}")
          end
          # mq.write_error("ERROR in WORKER [#{$$}] #{e.inspect} #{e.backtrace.join("\n")}")
          next
        end
      end
    end

    @@ok_to_mem_check = false
    @@lastmem = nil
    @@memct = 0
    
    def max_memory_reached?
      return false unless ok_to_mem_check?
       if !@memchecktime
        @memchecktime = Time.now
        return false
      elsif Time.now > (@memchecktime + MEMORY_CHECK_DELAY)
        @memchecktime = Time.now
        local_mem = get_memory_size.to_i
        return local_mem if local_mem > MAX_MEMORY
      else
        false
      end
    end
    
    def find_pid_size(file, format=:notpretty)
      begin
        open(file).each { |line|
          if line.index('VmSize')
            temp = line[7..-5].strip.to_f/1000
            return BigDecimal(temp.to_s).truncate(5).to_s('F') if format == :pretty
            return temp
          end
        }
      rescue Exception => e
        warn "ERROR #{e.inspect}"
        '0'
      end
    end

    def get_memory_size
      find_pid_size("/proc/self/status")
    end

    def ok_to_mem_check?
      return true if @@ok_to_mem_check == true
      return false if @@ok_to_mem_check == :notok
      if File.exists?('/proc/self/status')
      @@lastmem ||= get_memory_size.to_i
      return @@ok_to_mem_check = true         
      else
        @@ok_to_mem_check = :notok
        return false        
      end      
    end    


      # kinda like system() but gives me back a pid
    def self.fork_and_exec(command)
      sleep 0.01  # remove contention on manager drb object
      log = Skynet::Logger.get
      info "executing /bin/sh -c \"#{command}\""
      pid = fork do
        exec("/bin/sh -c \"#{command}\"")
        exit
      end
      Process.detach(pid)
      pid
    end

    def self.start
      options = {:worker_type => :any }
      OptionParser.new do |opt|
        opt.banner = "Usage: worker [options]"
        opt.on('-ot', '--worker_type WORKERTYPE', "master, task or any") do |v|
          if ["any","master","task"].include?(v)
            options[:worker_type] = v
          else
            raise Skynet::Error.new("#{v} is not a valid worker_type")
          end
        end
        opt.parse!(ARGV)
      end

      # worker_script_path = (Skynet::CONFIG[:WORKER_SCRIPT_PATH] || File.dirname(__FILE__)) << "/skynet_worker"

      debug "WORKER STARTING WORKER_TYPE?:#{options[:worker_type]}"

      begin                               
        worker = Skynet::Worker.new(options[:worker_type])
        worker.start
      rescue Skynet::Worker::NoManagerError => e
        fatal e.message
        exit          
      rescue Skynet::Worker::RespawnWorker => e
        warn "WORKER #{$$} SCRIPT CAUGHT RESPAWN.  RESTARTING"
        cmd = "RAILS_ENV=#{RAILS_ENV} ruby #{Skynet::COFIG[:LAUNCHER_PATH]} --worker_type=#{options[:worker_type]}"
        pid = fork_and_exec(cmd)
        warn "parent_pid: #{$$}, child_pid: #{pid}"
        exit
      rescue SystemExit
        info "WORKER #{$$} EXITING GRACEFULLY"
      rescue Exception => e
        fatal "WORKER #{$$} DYING #{e.class} #{e.message} #{e.backtrace}"
        report = ExceptionReport.new(e)
        report.save
      end
    end
  end
end

class ExceptionReport  
  def initialize(*args)    
  end                 
  
  def save
  end
end
