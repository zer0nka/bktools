require 'wavefile'
require 'waveform_fixer'
require 'tape_splitter'

require 'term/ansicolor'
include Term::ANSIColor

class MagReader
  include WaveformFixer
  include TapeSplitter

  CUTOFF_COEFF = 1.6   # Impulses longer than (base impulse length * CUTOFF_COEFF) will be
                       # considered to encode "1"s; shorter - "0"s.
  BIT_TOO_LONG = 2.8   # No bit impulse should be this long. Must be file format issue.

  attr_accessor :bk_file
  attr_accessor :invert_waveform
attr_accessor :debug_bytes

  def initialize(filename, debuglevel = 0)
    @debuglevel = debuglevel
    @filename = filename
    @bk_file = BkFile.new
    @invert_waveform = false
  end

  def debug(msg_level, msg)
    puts msg if msg_level <= @debuglevel
  end

  def read
    @current_sample_pos = 0
    @state = :find_pilot
    @pilot_counter = 0
    @total_pilot_length = 0
    @length_of_0 = @cutoff = nil
    @byte = 0
    @bit_counter = 0
    @reading_length = nil
    @byte_counter = 0
    @is_data_bit = true
    @marker_counter = nil
    @header_array = []
    @checksum_array = []

    counter = 0

    reader = WaveFile::Reader.new(@filename, WaveFile::Format.new(:mono, :pcm_16, 44100))
    reader.each_buffer(1024*1024) do |buffer|
      debug 5, "Loaded #{buffer.samples.length.to_s.bold} samples"

      buffer.samples.each { |c|
        @current_sample_pos += 1
        if (c > 0) ^ @invert_waveform then
          counter += 1
        else
          if counter != 0 then
            break if process_impulse(counter)
            counter = 0
          end
        end
      }
    end

    debug 0, "Validating checksum: #{@bk_file.validate_checksum ? 'success'.green : 'failed'.red }"
    debug 0, "Read complete."
  end

  # Main read loop
  def process_impulse(len)
    case @state
    when :find_pilot then
      tpl = @total_pilot_length.to_f

      debug 20, "   -pilot- impulse length --> #{len}"

      # If we read at least 200 pilot impulses by now and we encounter an impulse of length > 3.5 x '0',
      #    then it must be the end of the pilot.
      if (@pilot_counter > 200) && (len > (tpl / @pilot_counter * 3.5)) then
        @length_of_0 = (tpl / @pilot_counter).round(2)
        @cutoff = Integer((@length_of_0 * CUTOFF_COEFF).round(0))
        @state = :pilot_found
        debug 5, 'Pilot seqence found'.green
        debug 7, ' * '.blue.bold + "Impulse count          : #{@pilot_counter.to_s.bold}"
        debug 7, ' * '.blue.bold + "Trailer impulse length : #{len.to_s.bold}"
        debug 7, ' * '.blue.bold + "Averaged '0' length    : #{@length_of_0.to_s.bold}"
        debug 7, ' * '.blue.bold + "'0'/'1' cutoff         : #{@cutoff.to_s.bold}"
      else
        @total_pilot_length += len
        @pilot_counter += 1
        debug 40, "Pilot impulse ##{@pilot_counter}, impulse length: #{len}, total sequence length = #{@total_pilot_length}"
      end
    when :pilot_found then
      debug 15, "Synchro '1' after pilot: (#{(len > @cutoff) ? 'success'.green : 'failed'.red })"
      @state = :pilot_found2
    when :pilot_found2 then
      debug 15, "Synchro '0' after pilot: (#{(len < @cutoff) ? 'success'.green : 'failed'.red })"
      @state = :header_marker
      start_marker
    when :header_marker
      if read_marker(len) then
        @is_data_bit = true
        @current_array = @header_array
        @reading_length = @byte_counter = 20
        debug 5, "Reading file header..."
        @state = :read_header
      end
    when :read_header then
      if read_bit(len) then
        start_marker
        @bk_file.start_address, @bk_file.length, @bk_file.name = @header_array.map{ |e| e.chr }.join.unpack("S<S<a16")
        debug 5, "Header data read successfully".green
        debug 7, ' * '.blue.bold + "Start address : #{Tools::octal(@bk_file.start_address).bold}"
        debug 7, ' * '.blue.bold + "File length   : #{Tools::octal(@bk_file.length).bold}"
        debug 7, ' * '.blue.bold + 'File name     :' + '['.yellow + @bk_file.name.bold + ']'.yellow
        @state = :body_marker
      end
    when :body_marker
      if read_marker(len) then
        @is_data_bit = true
        @current_array = @bk_file.body
        @reading_length = @byte_counter = @bk_file.length
        debug 5, "Reading file body..."
        @state = :read_data
      end
    when :read_data
      debug 20, "      -data- #{@is_data_bit ? 'data' : 'sync' } impulse length --> #{len}"
      if read_bit(len) then
        @is_data_bit = true
        @current_array = @checksum_array
        @reading_length = @byte_counter = 2
        debug 5, "Reading checksum..."
        @state = :cksum
      end
    when :cksum
      debug 20, "      -checksum- #{@is_data_bit ? 'data' : 'sync' } impulse length --> #{len}"
      if read_bit(len) then
        @bk_file.checksum = Tools::bytes2word(*@checksum_array)
        debug 5, "Checksum read successfully".green
        debug 7, ' * '.blue.bold + "File checksum     : #{Tools::octal(@bk_file.checksum).bold}"
        debug 7, ' * '.blue.bold + "Computed checksum : #{Tools::octal(@bk_file.compute_checksum).bold}"
        start_marker
        @state = :end_trailer
      end
    when :end_trailer then
      # Trailing marker's lead length is equal to the length of at least 9 "0" impulses.
      if read_marker(len, 256, 9, :ignore_errors) then
        debug 5, "Read completed successfully.".green
        return true
      end
    end

    false
  end

  def start_marker
    @marker_counter = 0
  end
  private :start_marker

  def read_bit(len)
    bit = (len > @cutoff) ? 1 : 0

puts @current_sample_pos if debug_bytes && debug_bytes.include?(@current_array.size)
    if len > (@length_of_0 * BIT_TOO_LONG) then
      puts "Bit WAY too long (#{len}) @ #{@current_sample_pos}, byte ##{@current_array.size}".red
      raise
    end

    if @is_data_bit then
      debug 15, "   bit ##{@bit_counter} read: #{bit}"

      @byte = (@byte >> 1) | ((bit == 1) ? 128 : 0)
      @bit_counter += 1
      if @bit_counter == 8 then
        @current_array << @byte
        @byte_counter -= 1

        @bit_counter = 0
        debug 10, "--- byte #{Tools::octal(@reading_length - @byte_counter).bold} of #{Tools::octal(@reading_length).bold} read: #{Tools::octal_byte(@byte).yellow.bold}" #(#{@byte.chr})"
        @byte = 0
      end
    else # sync bit
      if bit == 1
        puts "Sync bit too long (#{len}) @ #{@current_sample_pos}, byte ##{@current_array.size}".red
        raise
      end
      return true if @byte_counter == 0
    end

    @is_data_bit = !@is_data_bit

    return false
  end

  def read_marker(len, marker_len = 8, first_impulse = nil, ignore_errors = false)
    debug 15, "Processing block start marker: impulse ##{@marker_counter} @ #{@current_sample_pos}, imp_length=#{len}; lead_impulse_length=#{first_impulse}, expecting #{marker_len} impulses"

    case @marker_counter
    when 0 then
      raise "Lead impulse too short " if !ignore_errors && first_impulse && (len < ((first_impulse - 0.5) * @length_of_0))
    when marker_len then
      raise "Marker final impulse not found (@ #{@current_sample_pos}); impulse #{len} long, expecting at least #{(@length_of_0 * 3.5)}" if !ignore_errors && (len < (@length_of_0 * 3.5))
    when marker_len + 1 then
      raise "Sync '1' after marker not found (@ #{@current_sample_pos})" if !ignore_errors && len < @cutoff
    when marker_len + 2 then
      raise "Sync '0' after marker not found (@ #{@current_sample_pos})" if !ignore_errors && len > @cutoff
      return true
    end
    @marker_counter +=1
    return false
  end

end