# encoding: binary

module WebSocket
  module Frame
    module Handler
      class Handler03 < Base
        # Hash of frame names and it's opcodes
        FRAME_TYPES = {
          continuation: 0,
          close: 1,
          ping: 2,
          pong: 3,
          text: 4,
          binary: 5
        }

        # Hash of frame opcodes and it's names
        FRAME_TYPES_INVERSE = FRAME_TYPES.invert

        # @see WebSocket::Frame::Base#supported_frames
        def supported_frames
          [:text, :binary, :close, :ping, :pong]
        end

        # @see WebSocket::Frame::Handler::Base#encode_frame
        def encode_frame
          frame = ''

          opcode = type_to_opcode(@frame.type)
          byte1 = opcode | (fin ? 0b10000000 : 0b00000000) # since more, rsv1-3 are 0 and 0x80 for Draft 4
          frame << byte1

          mask = @frame.outgoing_masking? ? 0b10000000 : 0b00000000

          length = @frame.data.size
          if length <= 125
            byte2 = length # since rsv4 is 0
            frame << (byte2 | mask)
          elsif length < 65_536 # write 2 byte length
            frame << (126 | mask)
            frame << [length].pack('n')
          else # write 8 byte length
            frame << (127 | mask)
            frame << [length >> 32, length & 0xFFFFFFFF].pack('NN')
          end

          if @frame.outgoing_masking?
            masking_key = [rand(256).chr, rand(256).chr, rand(256).chr, rand(256).chr].join
            tmp_data = Data.new([masking_key, @frame.data.to_s].join)
            tmp_data.set_mask
            frame << masking_key + tmp_data.getbytes(4, tmp_data.size)
          else
            frame << @frame.data
          end

          frame
        end

        # @see WebSocket::Frame::Handler::Base#decode_frame
        def decode_frame
          while @frame.data.size > 1
            valid_header, more, frame_type, mask, payload_length = decode_header
            return unless valid_header

            pointer = 0

            # Read application data (unmasked if required)
            @frame.data.set_mask if mask
            pointer += 4 if mask
            application_data = @frame.data.getbytes(pointer, payload_length)
            application_data.force_encoding('UTF-8')
            pointer += payload_length
            @frame.data.unset_mask if mask

            # Throw away data up to pointer
            @frame.data.slice!(0...pointer)

            fail(WebSocket::Error::Frame::UnexpectedContinuationFrame) if frame_type == :continuation && !@frame_type

            if more
              @application_data_buffer ||= ''
              @application_data_buffer << application_data
              @frame_type ||= frame_type
            elsif frame_type == :continuation
              @application_data_buffer << application_data
              # Test valid UTF-8 encoding
              fail(WebSocket::Error::Frame::InvalidPayloadEncoding) if @frame_type == :text && !@application_data_buffer.valid_encoding?
              message = @frame.class.new(version: @frame.version, type: @frame_type, data: @application_data_buffer, decoded: true)
              @application_data_buffer = nil
              @frame_type = nil
              return message
            else
              fail(WebSocket::Error::Frame::InvalidPayloadEncoding) if frame_type == :text && !application_data.valid_encoding?
              return @frame.class.new(version: @frame.version, type: frame_type, data: application_data, decoded: true)
            end
          end
          nil
        end

        # Allow turning on or off masking
        def masking?
          false
        end

        private

        # This allows flipping the more bit to fin for draft 04
        def fin
          false
        end

        # Convert frame type name to opcode
        # @param [Symbol] frame_type Frame type name
        # @return [Integer] opcode or nil
        # @raise [WebSocket::Error] if frame opcode is not known
        def type_to_opcode(frame_type)
          FRAME_TYPES[frame_type] || fail(WebSocket::Error::Frame::UnknownFrameType)
        end

        # Convert frame opcode to type name
        # @param [Integer] opcode Opcode
        # @return [Symbol] Frame type name or nil
        # @raise [WebSocket::Error] if frame type name is not known
        def opcode_to_type(opcode)
          FRAME_TYPES_INVERSE[opcode] || fail(WebSocket::Error::Frame::UnknownOpcode)
        end

        def decode_header
          first_byte = @frame.data.getbyte(0)
          second_byte = @frame.data.getbyte(1)

          more = ((first_byte & 0b10000000) == 0b10000000) ^ fin

          fail(WebSocket::Error::Frame::ReservedBitUsed) if first_byte & 0b01110000 != 0b00000000

          frame_type = opcode_to_type first_byte & 0b00001111

          fail(WebSocket::Error::Frame::FragmentedControlFrame) if more && control_frame?(frame_type)
          fail(WebSocket::Error::Frame::DataFrameInsteadContinuation) if data_frame?(frame_type) && !@application_data_buffer.nil?

          mask = @frame.incoming_masking? && (second_byte & 0b10000000) == 0b10000000
          length = second_byte & 0b01111111

          fail(WebSocket::Error::Frame::ControlFramePayloadTooLong) if length > 125 && control_frame?(frame_type)

          pointer = 2

          payload_length = case length
                           when 127 # Length defined by 8 bytes
                             # Check buffer size
                             return if @frame.data.getbyte(9).nil? # Buffer incomplete

                             pointer = 10

                             # Only using the last 4 bytes for now, till I work out how to
                             # unpack 8 bytes. I'm sure 4GB frames will do for now :)
                             @frame.data.getbytes(6, 4).unpack('N').first
                           when 126 # Length defined by 2 bytes
                             # Check buffer size
                             return if @frame.data.getbyte(3).nil? # Buffer incomplete

                             pointer = 4

                             @frame.data.getbytes(2, 2).unpack('n').first
                           else
                             length
                           end

          # Compute the expected frame length
          frame_length = pointer + payload_length
          frame_length += 4 if mask

          fail(WebSocket::Error::Frame::TooLong) if frame_length > WebSocket.max_frame_size

          # Check buffer size
          return if @frame.data.getbyte(frame_length - 1).nil? # Buffer incomplete

          # Remove frame header
          @frame.data.slice!(0...pointer)

          [true, more, frame_type, mask, payload_length]
        end
      end
    end
  end
end
