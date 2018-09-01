#!/usr/bin/env ruby
#
# Decode data structure provided by CFPropertyList gem.
# CFPropertyList.native_types(CFPropertyList::List.new(data: d[datakey]).value)
#
# This data structure is a list of keys and objects and a set of "NS.keys" and "NS.values" hashes
# which need to be assigned to each other.
#
# Reads a file which contains the hash-encoded raw Plist (like above) and outputs a decoded structure.
#
require 'pp'

res = {}

data = eval(File.read(ARGV[0]))
data["$objects"].each_with_index do |dat,di|
  #puts "dat = #{dat} ..."
  if dat.is_a?(Hash)
    newdata = {}
    dat.each do |k,v|
      #puts "  k, v = #{k}; #{v}"
      if ["NS.keys", "NS.objects"].include?(k) and v.is_a?(Array)
        newdata[k] = {}
        v.each_with_index do |key,index|
          #puts "newdata['#{k}'][#{index}] = #{data['$objects'][key]}"
          newdata[k][index] = data["$objects"][key]
        end
      end
      #pp newdata
      pp Hash[*newdata["NS.keys"].values.zip(newdata["NS.objects"].values).flatten] if newdata["NS.keys"] and newdata["NS.objects"]
    end
  end
end


