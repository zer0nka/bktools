class DiskSector
  attr_accessor :data, :read_checksum
  attr_reader :number
  attr_reader :size_code

  def initialize(number, size_code)
    @number = number
    @size_code = size_code
    @read_checksum = nil
    @data = []
  end

  def size
    case @size_code
    when 1 then 256
    when 2 then 512
    when 3 then 1024
    else nil
    end
  end

  BYTES_PER_LINE = 16

  def display
    if data.nil? then
      puts "----- No data to display -----"
      return
    end

    b0 = b1 = nil
    data_str = ''
    char_str = ''
    i = 0

    data.each_with_index { |byte, i|
      char_str << Tools::byte2char(byte)

      if b0.nil? then
        b0 = byte
      else
        b1 = byte
      end

      if b0 && b1 then
        data_str << Tools::octal(Tools::bytes2word(b0, b1)) << ' '
        b0 = b1 = nil
      end

      if (i % BYTES_PER_LINE) == (BYTES_PER_LINE - 1) then
        print_line(((i + 1) - BYTES_PER_LINE), data_str, char_str)
        data_str = ''
        char_str = ''
      end

    }

    if !data_str.empty? then
      print_line(i, data_str, char_str)
    end

  end

  def print_line(base_addr, data_str, char_str)
    strlen = ((BYTES_PER_LINE / 2) * 7)
    data_str = (data_str + ' ' * strlen)[0...(strlen)]
    print Tools::octal(base_addr), ': ', data_str, ' ', char_str, "\n"
    data_str = ''
    char_str = ''
  end

  def valid?
    (data.size == self.size) &&
      (self.read_checksum == Tools::crc_ccitt([0xA1, 0xA1, 0xA1, 0xFB] + self.data))
  end

end
