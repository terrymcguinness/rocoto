##########################################
#
# Module WFMStat
#
##########################################
module WFMStat

  ##########################################
  #
  # Class StatusEngine
  #
  ##########################################
  class StatusEngine

    require 'workflowmgr/workflowdoc'
    require 'workflowmgr/workflowdb'
    require 'workflowmgr/cycledef'
    require "workflowmgr/cycle"
    require 'workflowmgr/dependency'

    require 'workflowmgr/workflowconfig'
    require 'workflowmgr/launchserver'
    require 'workflowmgr/dbproxy'
    require 'workflowmgr/workflowioproxy'

    ##########################################
    #
    # initialize
    #
    ##########################################
    def initialize(options)

      # Get command line options
      @options=options

      # Get configuration file options
      @config=WorkflowMgr::WorkflowYAMLConfig.new

      # Get the base directory of the WFM installation
      @wfmdir=File.dirname(File.dirname(File.expand_path(File.dirname(__FILE__))))

      # Set up an object to serve the workflow database (but do not open the database)
      @dbServer=WorkflowMgr::DBProxy.new(@options.database,@config)

      # Set up an object to serve file stat info
      @workflowIOServer=WorkflowMgr::WorkflowIOProxy.new(@dbServer,@config)        

      # Open the workflow document
      @workflowdoc = WorkflowMgr::WorkflowXMLDoc.new(@options.workflowdoc,@workflowIOServer)

    end  # initialize


    ##########################################
    #
    # wfmstat
    #
    ##########################################
    def wfmstat

      begin

        # Open/Create the database
        @dbServer.dbopen

        # Print a cycle summary report if requested
        if @options.summary
          print_summary
        else
          print_status
        end
    
      ensure
  
        # Make sure we release the workflow lock in the database and shutdown the dbserver
        unless @dbServer.nil?
          @dbServer.unlock_workflow if @locked
          @dbServer.stop! if @config.DatabaseServer
        end
  
        # Make sure to shut down the workflow file stat server
        unless @workflowIOServer.nil?
          @workflowIOServer.stop! if @config.WorkflowIOServer
        end
  
      end  # ensure

    end  # wfmstat


    ##########################################
    #
    # checkTask
    #
    ##########################################
    def checkTask

      begin

        # Open/Create the database
        @dbServer.dbopen

        # Get cycle time and task name options
        cycletime=@options.cycles.first
        taskname=@options.tasks.first

        # Get the cycle
        cycle=@dbServer.get_cycles( {:start=>cycletime, :end=>cycletime } ).first || WorkflowMgr::Cycle.new(cycletime)

        # Get the task
        task=@workflowdoc.tasks[taskname]
        task=task.localize(cycletime) unless task.nil?

        # Get the job (if there is one)
        jobcycles=[cycletime]
        @workflowdoc.taskdep_cycle_offsets.each do |offset|
          jobcycles << cycletime + offset
        end
        jobs=@dbServer.get_jobs(jobcycles)
        if jobs[taskname].nil?
          job=nil
        else
          job=jobs[taskname][cycletime]
        end

        # Query task dependencies
        dependencies=task.dependency.query(cycle,jobs,@workflowIOServer) unless task.nil?

        # Print the task information
        print_taskinfo(task)
        print_deps(dependencies,0)

        # Print the cycle information
        print_cycleinfo(cycle)

        # Print the job information
        print_jobinfo(job)

        # Print throttling violations
        print_violations(task,cycle,dependencies) if job.nil?

      ensure
  
        # Make sure we release the workflow lock in the database and shutdown the dbserver
        unless @dbServer.nil?
          @dbServer.unlock_workflow if @locked
          @dbServer.stop! if @config.DatabaseServer
        end
  
        # Make sure to shut down the workflow file stat server
        unless @workflowIOServer.nil?
          @workflowIOServer.stop! if @config.WorkflowIOServer
        end
  
      end  # ensure

    end

    ##########################################
    #
    # getCycles
    #
    ##########################################
    def getCycles

      # Initialize empty lists of cycles
      dbcycles=[]
      xmlcycles=[]
      undefcycles=[]

      # Get the cycles of interest that are in the database
      if @options.cycles.nil?
        # Get the latest cycle
        dbcycles << @dbServer.get_last_cycle
      elsif @options.cycles.is_a?(Range)
        # Get all cycles within the range
        dbcycles += @dbServer.get_cycles( {:start=>@options.cycles.first, :end=>@options.cycles.last } )
      elsif @options.cycles.is_a?(Array)
        # Get the specific cycles asked for
        @options.cycles.each do |c|
          cycle = @dbServer.get_cycles( {:start=>c, :end=>c } )
          if cycle.empty?
            undefcycles << WorkflowMgr::Cycle.new(c)
          else
            dbcycles += cycle
          end
        end
      else
        puts "Invalid cycle specification"
      end
      
      # Add cycles defined in XML that aren't in the database
      # We only need to do this when a range of cycles is requested
      if @options.cycles.is_a?(Range)

        # Get the cycle definitions
        cycledefs = @workflowdoc.cycledefs

        # Find every cycle in the range
        xml_cycle_times = []
        reftime=cycledefs.collect { |cdef| cdef.next(@options.cycles.first) }.compact.min
        while true do
          break if reftime.nil?
          break if reftime > @options.cycles.last
          xml_cycle_times << reftime
          reftime=cycledefs.collect { |cdef| cdef.next(reftime+60) }.compact.min
        end

        # Add the cycles that are in the XML but not in the DB
        xmlcycles = (xml_cycle_times - dbcycles.collect { |c| c.cycle } ).collect { |c| WorkflowMgr::Cycle.new(c) }

      end

      [dbcycles,xmlcycles,undefcycles]

    end  


    ########################################## 
    #
    # print_summary
    #
    ##########################################
    def print_summary

      # Get cycles of interest
      dbcycles,xmlcycles,undefcycles=getCycles

      # Print the header
      printf "%12s    %8s    %20s    %20s\n","CYCLE".center(12),
                                             "STATE".center(8),
                                             "ACTIVATED".center(20),
                                             "DEACTIVATED".center(20)

      # Print the cycle date/times
      (dbcycles+xmlcycles).sort.each do |cycle|
        printf "%12s    %8s    %20s    %20s\n","#{cycle.cycle.strftime("%Y%m%d%H%M")}",
                                               "#{cycle.state.to_s.capitalize}",
                                               "#{cycle.activated_time_string.center(20)}",
                                               "#{cycle.deactivated_time_string.center(20)}"
      end

    end

    ##########################################
    #
    # print_status
    #
    ##########################################
    def print_status

      # Get cycles of interest
      dbcycles,xmlcycles,undefcycles=getCycles

      # Get the jobs from the database for the cycles of interest
      jobs=@dbServer.get_jobs(dbcycles.collect {|c| c.cycle})

      # Get the list of tasks from the workflow definition
      definedTasks=@workflowdoc.tasks

      # Print the job status info
      if @options.taskfirst

        format = "%20s    %12s    %24s    %16s    %16s    %6s\n"
        header = "TASK".rjust(20),"CYCLE".rjust(12),"JOBID".rjust(24),
                 "STATE".rjust(16),"EXIT STATUS".rjust(16),"TRIES".rjust(6)
        puts format % header

        # Sort the task list in sequence order
        tasklist=jobs.keys | definedTasks.values.collect { |t| t.attributes[:name] }
        unless @options.tasks.nil?
          tasklist = tasklist.find_all { |task| @options.tasks.any? { |pattern| task=~/#{pattern}/ } }
        end
        tasklist=tasklist.sort_by { |t| [definedTasks[t].nil? ? 999999999 : definedTasks[t].seq, t.split(/(\d+)/).map { |i| i=~/\d+/ ? i.to_i : i }].flatten }

        tasklist.each do |task|

          printf "==================================================================================================================\n"

          # Print status of all jobs for this task
          cyclelist=(dbcycles | xmlcycles).collect { |c| c.cycle }.sort
          cyclelist.each do |cycle|
            if jobs[task].nil?
              jobdata=["-","-","-","-"]
            elsif jobs[task][cycle].nil?
              jobdata=["-","-","-","-"]
            else
              jobdata=[jobs[task][cycle].id,jobs[task][cycle].state,jobs[task][cycle].exit_status,jobs[task][cycle].tries]
            end
            puts format % ([task,cycle.strftime("%Y%m%d%H%M")] + jobdata)
          end
        end
 
     else 

        format = "%12s    %20s    %24s    %16s    %16s    %6s\n"
        header = "CYCLE".rjust(12),"TASK".rjust(20),"JOBID".rjust(24),
                 "STATE".rjust(16),"EXIT STATUS".rjust(16),"TRIES".rjust(6)
        puts format % header

        # Print status of jobs for each cycle
        cyclelist=(dbcycles | xmlcycles).collect { |c| c.cycle }.sort
        cyclelist.each do |cycle|

          printf "==================================================================================================================\n"

          # Sort the task list in sequence order 
          tasklist=jobs.keys | definedTasks.values.collect { |t| t.attributes[:name] }
          unless @options.tasks.nil?
            tasklist = tasklist.find_all { |task| @options.tasks.any? { |pattern| task=~/#{pattern}/ } }
          end
          tasklist=tasklist.sort_by { |t| [definedTasks[t].nil? ? 999999999 : definedTasks[t].seq, t.split(/(\d+)/).map { |i| i=~/\d+/ ? i.to_i : i }].flatten }
          tasklist.each do |task|
            if jobs[task].nil?
              jobdata=["-","-","-","-"]
            elsif jobs[task][cycle].nil?
              jobdata=["-","-","-","-"]
            else
              jobdata=[jobs[task][cycle].id,jobs[task][cycle].state,jobs[task][cycle].exit_status,jobs[task][cycle].tries]
            end
            puts format % ([cycle.strftime("%Y%m%d%H%M"),task] + jobdata)
          end
        end

      end      

    end


    ########################################## 
    #
    # print_taskinfo
    #
    ##########################################
    def print_taskinfo(task)

      puts
      if task.nil?
        puts "Task: Not defined in current workflow definition"
      else
        puts "Task: #{task.attributes[:name]}"
        task.attributes.keys.sort { |a1,a2| a1.to_s <=> a2.to_s }.each { |attr|
          puts "  #{attr}: #{task.attributes[attr]}"
        }
        puts "  environment"
        task.envars.keys.sort.each { |envar|
          puts "    #{envar} ==> #{task.envars[envar]}"
        }
      end

    end


    ########################################## 
    #
    # print_cycleinfo
    #
    ##########################################
    def print_cycleinfo(cycle)

      puts
      puts "Cycle: #{cycle.cycle.strftime("%Y%m%d%H")}"
      puts "  State: #{cycle.state}"
      puts "  Activated: #{cycle.active? ? cycle.activated : "-"}"
      puts "  Completed: #{cycle.done? ? cycle.done : "-"}"
      puts "  Expired: #{cycle.expired? ? cycle.expired : "-"}"
      
    end


    ########################################## 
    #
    # print_jobinfo
    #
    ##########################################
    def print_jobinfo(job)

      puts
      if job.nil?
        puts "Job: This task has not been submitted for this cycle"
      else
        puts "Job: #{job.id}"
        puts "  State:  #{job.state} (#{job.native_state})"
        puts "  Exit Status:  #{job.done? ? job.exit_status : "-"}"
        puts "  Tries:  #{job.tries}"
        puts "  Unknown count:  #{job.nunknowns}"
      end

    end


    ##########################################
    #
    # print_violations
    #
    ##########################################
    def print_violations(task,cycle,dependencies)

      puts

      # Check for inactive cycle
      puts "Task can not be submitted because:"
      unless cycle.active?
        puts "  The cycle is not active"
        return
      end

      # Check for unsatisfied dependencies
      unless dependencies.first[:resolved]
        puts "  Dependencies are not satisfied"
        return
      end

      # Check for throttle violations
      active_cycles=@dbServer.get_active_cycles
      active_jobs=@dbServer.get_jobs(active_cycles.collect { |c| c.cycle })
      ncores=0
      ntasks=0
      active_jobs.keys.each do |jobtask|
        ntasks += 1
        active_jobs[jobtask].keys.each do |jobcycle|
          ncores += active_jobs[jobtask][jobcycle].cores
        end
      end
      if ntasks + 1 > @workflowdoc.taskthrottle
        puts "  Task throttle violation (#{ntasks} of #{@workflowdoc.taskthrottle} tasks are already active)"
      end
      if ncores + task.attributes[:cores] > @workflowdoc.corethrottle
        puts "  Core throttle violation (#{ncores} of #{@workflowdoc.corethrottle} cores are already in use)"
      end

    end


    ##########################################
    #
    # print_deps
    #
    ##########################################
    def print_deps(deps,n)

      return if deps.nil?
      printf "%2s%s\n", "","dependencies" if n==0
      deps.each do |d|
        if d.is_a?(Array)
          print_deps(d,n+1) if d.is_a?(Array)
        else
          printf "%#{2*n+4}s%s %s\n","",d[:dep],d[:msg] 
        end
      end
 
    end

  end  # Class StatusEngine

end  # Module WorkflowMgr
