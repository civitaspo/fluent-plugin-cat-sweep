require 'test/unit'
require 'fluent/version'
require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/test/driver/input'

def current_fluent_version
  fluent_version(Fluent::VERSION)
end

def fluent_version(v)
  Gem::Version.new(v)
end
