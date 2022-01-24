# frozen_string_literal: true

require "bwa/logger"
require "bwa/crc"

module BWA
  class InvalidMessage < RuntimeError
    attr_reader :raw_data

    def initialize(message, data)
      @raw_data = data
      super(message)
    end
  end

  class Message
    attr_accessor :src

    class Unrecognized < Message
    end

    class << self
      def inherited(klass)
        super

        @messages ||= []
        @messages << klass
      end

      # Ignore (parse and throw away) messages of these types.
      IGNORED_MESSAGES = [
        "\xbf\x00".b, # request for new clients
        "\xbf\xe1".b,
        "\xbf\x07".b # nothing to send
      ].freeze

      # Don't log messages of these types, even in DEBUG mode.
      # They are very frequent and would swamp the logs.
      def common_messages
        @common_messages ||= begin
          msgs = []
          unless BWA.verbosity >= 1
            msgs += [
              Messages::Status::MESSAGE_TYPE,
              "\xbf\xe1".b
            ]
          end
          unless BWA.verbosity >= 2
            msgs += [
              "\xbf\x00".b,
              "\xbf\xe1".b,
              Messages::Ready::MESSAGE_TYPE,
              "\xbf\x07".b
            ]
          end
          msgs
        end
      end

      def parse(data)
        offset = -1
        message_type = length = nil
        loop do
          offset += 1
          # Not enough data for a full message; return and hope for more
          return nil if data.length - offset < 5

          # Keep scanning until message start char
          next unless data[offset] == "~"

          # Read length (safe since we have at least 5 chars)
          length = data[offset + 1].ord

          # No message is this short or this long; keep scanning
          next if (length < 5) || (length >= "~".ord)

          # don't have enough data for what this message wants;
          # return and hope for more (yes this might cause a
          # delay, but the protocol is very chatty so it won't
          # be long)
          return nil if length + 2 > data.length - offset

          # Not properly terminated; keep scanning
          next unless data[offset + length + 1] == "~"

          # Not a valid checksum; keep scanning
          next unless CRC.checksum(data.slice(offset + 1, length - 1)) == data[offset + length].ord

          # Got a valid message!
          break
        end

        message_type = data.slice(offset + 3, 2)
        BWA.logger.debug "discarding invalid data prior to message #{BWA.raw2str(data[0...offset])}" unless offset.zero?
        unless common_messages.include?(message_type)
          BWA.logger.debug " read: #{BWA.raw2str(data.slice(offset,
                                                            length + 2))}"
        end

        src = data[offset + 2].ord
        klass = @messages.find { |k| k::MESSAGE_TYPE == message_type }

        # Ignore these message types
        return [nil, offset + length + 2] if IGNORED_MESSAGES.include?(message_type)

        if klass
          valid_length = if klass::MESSAGE_LENGTH.respond_to?(:include?)
                           klass::MESSAGE_LENGTH.include?(length - 5)
                         else
                           length - 5 == klass::MESSAGE_LENGTH
                         end
          unless valid_length
            raise InvalidMessage.new("Unrecognized data length (#{length}) for message #{klass}",
                                     data)
          end
        else
          BWA.logger.info(
            "Unrecognized message type #{BWA.raw2str(message_type)}: #{BWA.raw2str(data.slice(offset, length + 2))}"
          )
          klass = Unrecognized
        end

        message = klass.new
        message.parse(data.slice(offset + 5, length - 5))
        message.instance_variable_set(:@raw_data, data.slice(offset, length + 2))
        message.instance_variable_set(:@src, src)
        BWA.logger.debug "from spa: #{message.inspect}" unless common_messages.include?(message_type)
        [message, offset + length + 2]
      end

      def format_time(hour, minute, twenty_four_hour_time: true)
        if twenty_four_hour_time
          format("%02d:%02d", hour, minute)
        else
          print_hour = hour % 12
          print_hour = 12 if print_hour.zero?
          format("%d:%02d%s", print_hour, minute, hour >= 12 ? "PM" : "AM")
        end
      end

      def format_duration(minutes)
        format("%d:%02d", minutes / 60, minutes % 60)
      end
    end

    attr_reader :raw_data

    def initialize
      # most messages we're sending come from this address
      @src = 0x0a
    end

    def parse(_data); end

    def serialize(message = "")
      length = message.length + 5
      full_message = "#{length.chr}#{src.chr}#{self.class::MESSAGE_TYPE}#{message}"
      checksum = CRC.checksum(full_message)
      "\x7e#{full_message}#{checksum.chr}\x7e".b
    end

    def inspect
      "#<#{self.class.name} #{raw_data.unpack1("H*")}>"
    end
  end
end

require "bwa/messages/configuration"
require "bwa/messages/configuration_request"
require "bwa/messages/control_configuration"
require "bwa/messages/control_configuration_request"
require "bwa/messages/filter_cycles"
require "bwa/messages/ready"
require "bwa/messages/set_target_temperature"
require "bwa/messages/set_temperature_scale"
require "bwa/messages/set_time"
require "bwa/messages/status"
require "bwa/messages/toggle_item"
