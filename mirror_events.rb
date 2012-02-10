#!/usr/bin/env ruby
#
# Copyright 2012 Georgios Gousios <gousiosg@gmail.com>
#
# Redistribution and use in source and binary forms, with or
# without modification, are permitted provided that the following
# conditions are met:
#
#   1. Redistributions of source code must retain the above
#      copyright notice, this list of conditions and the following
#      disclaimer.
#
#   2. Redistributions in binary form must reproduce the above
#      copyright notice, this list of conditions and the following
#      disclaimer in the documentation and/or other materials
#      provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
# AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.


require 'rubygems'
require 'yaml'
require 'amqp'
require 'eventmachine'
require 'github-analysis'
require 'json'

GH = GithubAnalysis.new

# Graceful exit
Signal.trap('INT') { AMQP.stop { EM.stop } }
Signal.trap('TERM') { AMQP.stop { EM.stop } }

# Method used to perform the Github request for retrieving events
def retrieve exchange
  begin
    new = dupl = 0
    events = GH.get_events

    events.each do |e|
      if GH.events_col.find({'id' => e['id']}).has_next? then
        GH.log.info "Already got #{e['id']}"
        dupl += 1
        next
      end

      new += 1
      GH.events_col.insert(e)
      GH.log.info "Added #{e['id']}"

      msg = JSON.dump(e)
      key = "evt.%s" % e['type']
      exchange.publish msg, :persistent => true, :routing_key => key
    end
    return new, dupl
  rescue Exception => e
    puts e.backtrace
    #GH.log.error e.backtrace
  end
end

# The event loop
AMQP.start(:host => GH.settings['amqp']['host'],
           :username => GH.settings['amqp']['username'],
           :password => GH.settings['amqp']['password']) do |connection|

  # Statistics used to recalibrate event delays
  dupl_msgs = new_msgs = 1

  GH.log.debug "connected to rabbit"

  channel = AMQP::Channel.new(connection)
  exchange = channel.topic("#{GH.settings['amqp']['exchange']}",
                           :durable => true, :auto_delete => false)

  # Initial delay for the retrieve event loop
  retrieval_delay = GH.settings['mirror']['events']['pollevery']

  # Retrieve commits.
  retriever = EventMachine.add_periodic_timer(retrieval_delay) do
    (new, dupl) = retrieve exchange
    dupl_msgs += dupl
    new_msgs += new
  end

  # Adjust event retrieval delay time to reduce load to Github
  EventMachine.add_periodic_timer(120) do
    ratio = (dupl_msgs.to_f / (dupl_msgs + new_msgs).to_f)

    GH.log.info("Stats: #{new_msgs} new, #{dupl_msgs} duplicate, ratio: #{ratio}")

    new_delay = if ratio >= 0 and ratio < 0.3 then
                  -1
                elsif ratio >= 0.3 and ratio <= 0.5 then
                  0
                elsif ratio > 0.5 and ratio < 1 then
                  +1
                end

    # Reset counters for new loop
    dupl_msgs = new_msgs = 0

    # Update the retrieval delay and restart the event retriever
    if new_delay != 0 then

      # Stop the retriever task and adjust retrieval delay
      retriever.cancel
      retrieval_delay = retrieval_delay + new_delay
      GH.log.info("Setting event retrieval delay to #{retrieval_delay} secs")

      # Restart the retriever
      retriever = EventMachine.add_periodic_timer(retrieval_delay) do
        (new, dupl) = retrieve exchange
        dupl_msgs += dupl
        new_msgs += new
      end
    end
  end
end