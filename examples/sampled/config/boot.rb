# Don't change this file!
# Configure your daemon in config/environment.rb

RAEMON_ROOT = File.expand_path(File.dirname(__FILE__)+'/..') unless defined?(RAEMON_ROOT)

module Raemon
  class << self
    def boot!
      return if defined? Raemon::Server
      
      load_vendor_libs
      
      require 'rubygems'
      require 'raemon'
      
      Raemon::Server.run
    end
    
    def load_vendor_libs
      Dir.entries("#{RAEMON_ROOT}/vendor").each do |vendor|
        vendor_lib = "#{RAEMON_ROOT}/vendor/#{vendor}/lib"
        if File.directory?(vendor_lib) && vendor != '..'
          $LOAD_PATH.unshift vendor_lib
        end
      end
    end
  end
end

Raemon.boot!
