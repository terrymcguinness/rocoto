#!/usr/bin/ruby

# Get the base directory of the WFM installation
if File.symlink?(__FILE__)
  __WFMDIR__=File.dirname(File.dirname(File.expand_path(File.readlink(__FILE__),File.dirname(__FILE__))))
else
  __WFMDIR__=File.dirname(File.expand_path(File.dirname(__FILE__)))
end

# Add include paths for WFM and libxml-ruby libraries
$:.unshift("#{__WFMDIR__}/lib")
$:.unshift("#{__WFMDIR__}/lib/libxml-ruby")
$:.unshift("#{__WFMDIR__}/lib/sqlite3-ruby")
$:.unshift("#{__WFMDIR__}/lib/SystemTimer")

# Load workflow engine library
require 'workflowmgr/workflowengine'
require 'workflowmgr/workflowoption'

WorkflowMgr::VERSION=IO.readlines("#{__WFMDIR__}/VERSION",nil)[0]

# Create workflow engine and run it
workflowmgrOptions=WorkflowMgr::WorkflowOption.new(ARGV)
workflowengine=WorkflowMgr::WorkflowEngine.new(workflowmgrOptions)
workflowengine.run
