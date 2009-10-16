require 'socket'
require 'net/ssh'

# Clusterfuck is an ugly, dirty hack to run a large number of jobs on multiple machines.
# If you have can break your task up into a series of small, independent jobs, clusterfuck
# can automate the process of distributing jobs across machines.
module Clusterfuck
  # A configuration holds the various pieces of information Clusterfuck needs
  # to represent a task. 
  #
  # You probably won't need to instantiate a Configuration directly; one is created
  # when you create a new Task, and passed to the block it takes as a parameter. See Task
  # for more information.
  class Configuration
    # Holds the user-specified options. Again, you probably don't want to access this directly -- use the
    # getter/setter syntax instead
    attr_reader :options
    
    # Create a new Configuration object with default options. Default options are described in TODO: default options documentation
    def initialize
      @options = {
          :timeout => 2,
          :max_fail => 3
        }
    end
    
    # You can get/set options as if they were attributes, i.e. +config.foo = "bar"+ will set the option +foo+ to "bar".
    def method_missing(key,args=nil)
      if args.nil?
        return @options[key.to_s]
      else
        key = key.to_s.gsub!("=","")
        @options[key] = args
      end
    end
    
    # Get a pretty-printed version of the currently set options
    def to_s
      @options.map { |pair| "#{pair[0]} = \"#{pair[1]}\""}.join(", ")
    end
  end
  
  # The primary means of interacting with Clusterfuck. Create a new 
  # Task, passing in a block that takes a Configuration object as a parameter (rake-style).
  # The constructor returns after all jobs have been completed.
  class Task
    # TODO: document legal configuration options
    def initialize(&custom)
      # Run configuration options specified in clusterfile
      config = Configuration.new
      custom.call(config)
      
      # Make output fragment directory
      `mkdir #{config.temp}` if not File.exists?(config.temp)
      
      # Run all jobs
      machines = config.hosts.map { |name| Machine.new(name,config) }
      machines.each { |machine| machine.run }
      
      # Wait for jobs to terminate
      machines.each { |machine| machine.thread.join }
    end
  end
  
  class Machine
    attr_accessor :host,:config
    attr_reader :thread

    def initialize(host,config)
      self.host = host
      self.config = config
      
      @thread = nil
    end
    
    def run
      @thread = Thread.new do
        while config.jobs.size > 0
          job = config.jobs.shift
          begin
            Net::SSH.start(self.host,config.username,:password => config.password,:timeout => config.timeout) do |ssh|
              puts "Starting job #{job.short_name} on #{self.host}" if config.debug
              ssh.exec(job.command + " > #{Dir.getwd}/#{config.temp}/#{job.short_name}.#{self.host}")
            end
          rescue
            puts "#{job.short_name} FAILED on #{self.host}, dropping it from the hostlist"
            if not job.failed < config.max_fail
              config.jobs.push job
              job.failed += 1
            else
              puts "CANCELLING #{job.short_name}, too many failures (#{job.failed})"
            end
            break
          end
        end
      end
    end
  end  
  
  class Job
    attr_accessor :short_name
    attr_accessor :command
    attr_accessor :failed
    
    def initialize(short_name,command)
      self.short_name = short_name
      self.command = command
      
      self.failed = 0
    end    
  end
end
