class DiskSector
  attr_accessor :data
  attr_reader :number

  def initialize(number)
    @number = number
    @data = []
  end

  def display
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

      if (i % 8) == 7 then
        print_line(i - 7, data_str, char_str)
        data_str = ''
        char_str = ''
      end

    }

    if !data_str.empty? then
      print_line(i, data_str, char_str)
    end

  end

  def print_line(base_addr, data_str, char_str)
    data_str = (data_str + ' ' * 28)[0...28]
    print Tools::octal(base_addr), ': ', data_str, ' ', char_str, "\n"
    data_str = ''
    char_str = ''
  end

end