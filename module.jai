// This is a direct port of the reference implementation from:
// https://github.com/nayuki/Reference-arithmetic-coding/blob/master/cpp/ArithmeticCoder.cpp
// https://github.com/nayuki/Reference-arithmetic-coding/blob/master/cpp/FrequencyTable.cpp

// == BitStream

BitInputStream :: struct {
  current_byte: s16; // normally 0-0xFF, but can be -1 at EOF
  num_bits_remaining: u8; // always between 0 and 7

  user_data: *void;

  read_byte_proc: #type (user_data: *void) -> s16;
};

read_bit :: (using bis: *BitInputStream) -> s16 {
  if current_byte == -1 return -1;
  if num_bits_remaining == 0 {
    current_byte = bis.read_byte_proc(bis.user_data);
    if current_byte == -1 return -1;
    assert(0 <= current_byte && current_byte <= 255);
    num_bits_remaining = 8;
  }
  assert(num_bits_remaining > 0);
  num_bits_remaining -= 1;
  return (current_byte >> num_bits_remaining) & 1;
}

BitOutputStream :: struct {
  current_byte: u8;
  num_bits_filled: u8;

  user_data: *void;

  write_byte_proc: #type (user_data: *void, byte: u8);
};

write_bit :: (using bos: *BitOutputStream, bit: u8) {
  assert(bit <= 1);
  current_byte = (current_byte << 1) | bit;
  num_bits_filled += 1;
  if num_bits_filled == 8 {
    bos.write_byte_proc(bos.user_data, current_byte);
    current_byte = 0;
    num_bits_filled = 0;
  }
}

finish :: (using bos: *BitOutputStream) {
  while num_bits_filled != 0 {
    write_bit(bos, 0);
  }
}

// == FrequencyTable

FrequencyTable :: struct {
  buffer: []u32;
  frequencies: []u32;
  cumulative: []u32;
  total: u32;
};

init_frequency_table :: (table: *FrequencyTable, frequencies: []u32) {
  assert(frequencies.count < U32_MAX);
  assert(frequencies.count > 0);
  table.frequencies = frequencies;
  table.buffer = NewArray(2 * frequencies.count + 1, u32);

  table.frequencies.data = table.buffer.data;
  table.frequencies.count = frequencies.count;
  memcpy(table.frequencies.data, frequencies.data, frequencies.count * size_of(u32));

  table.cumulative.data = *(table.buffer.data[frequencies.count]);
  table.cumulative.count = frequencies.count + 1;
  init_cumulative(table, false, force_init = true);

  table.total = get_high(table, cast(u32) (frequencies.count - 1));
}

free_frequency_table :: (using table: *FrequencyTable) {
  free(table.buffer.data);
}

frequency_table_set :: (using table: *FrequencyTable, symbol: u32, freq: u32, update_cumulative := false) {
  old_freq := frequencies[symbol];
  assert(total >= old_freq);
  total = checked_add(total - old_freq, freq);
  frequencies[symbol] = freq;
  if update_cumulative {
    diff: s64 = (cast(s64)freq - cast(s64)old_freq);
    for s: symbol..table.frequencies.count {
      cumulative[s] = cast(u32) (cast(s64)cumulative[s] + diff);
    }
  } else {
    // mark as out-of-date:
    cumulative[0] = 1;
  }
}

frequency_table_increment :: (using table: *FrequencyTable, symbol: u32, update_cumulative := false) {
  assert(frequencies[symbol] < U32_MAX);
  total = checked_add(total, 1);
  frequencies[symbol] += 1;
  if update_cumulative {
    for s: symbol..table.frequencies.count {
      cumulative[s] += 1;
    }
  } else {
    // mark as out-of-date:
    cumulative[0] = 1;
  }
}

get_low :: (using table: *FrequencyTable, symbol: u32) -> u32 {
  init_cumulative(table, true);
  return cumulative[symbol];
}

get_high :: (using table: *FrequencyTable, symbol: u32) -> u32 {
  init_cumulative(table, true);
  return cumulative[symbol + 1];
}

get_low_and_high :: (using table: *FrequencyTable, symbol: u32) -> u32, u32 {
  init_cumulative(table, true);
  return cumulative[symbol], cumulative[symbol + 1];
}

#scope_file

init_cumulative :: (using table: *FrequencyTable, check_total: bool, force_init := false) {
  if !force_init && cumulative[0] == 0 {
    return; // anything non-zero in the first slot means it's not initialized
  }
  sum:u32 = 0;
  cumulative[0] = 0;
  for freq: frequencies {
    assert(freq > 0, "frequency can't be zero");
    sum = checked_add(sum, freq);
    cumulative[it_index + 1] = sum;
  }
  assert(!check_total || sum == total);
}

#scope_export

ArithmeticCoderBase :: struct {
  // Configuration
  num_state_bits: u64;
  full_range: u64;
  half_range: u64;
  quarter_range: u64;
  minimum_range: u64;
  maximum_total: u64;
  state_mask: u64;

  // State
  low: u64;
  high: u64;
}

// == Encoder

ArithmeticEncoder :: struct {
  using #as coder : ArithmeticCoderBase;

  num_underflow: u64;
}

init_encoder :: (enc: *ArithmeticEncoder, num_bits: u8 = 32) {
  init_aritmetic_coder_base(enc, num_bits);
}

shift :: inline (using enc: *ArithmeticEncoder, bos: *BitOutputStream) {
  bit: u8 = cast(u8) (low >> (num_state_bits - 1));
  write_bit(bos, bit);

  while num_underflow > 0 {
    write_bit(bos, bit ^ 1);
    num_underflow -= 1;
  }
}

underflow :: inline (using enc: *ArithmeticEncoder, bos: *BitOutputStream) {
  assert(num_underflow < U64_MAX);
  num_underflow += 1;
}

write :: inline (using enc: *ArithmeticEncoder, bos: *BitOutputStream, table: *FrequencyTable, symbol: u32) {
  update(enc, table, symbol, bos);
}

finish :: (enc: *ArithmeticEncoder, bos: *BitOutputStream) {
  write_bit(bos, 1);
}

// == Decoder

ArithmeticDecoder :: struct {
  using #as coder : ArithmeticCoderBase;

  code: u64;
}

init_decoder :: (using dec: *ArithmeticDecoder, bis: *BitInputStream, num_bits: u8 = 32) {
  init_aritmetic_coder_base(dec, num_bits);
  code = 0;
  for 1..num_bits {
    code = (code << 1) | read_code_bit(bis);
  }
}

shift :: (using dec: *ArithmeticDecoder, bis: *BitInputStream) {
  code = ((code << 1) & state_mask) | read_code_bit(bis);
}

underflow :: (using dec: *ArithmeticDecoder, bis: *BitInputStream) {
  code = (code & half_range) | ((code << 1) & (state_mask >> 1)) | read_code_bit(bis);
}

read :: (using dec: *ArithmeticDecoder, table: *FrequencyTable, bis: *BitInputStream) -> u32 {
  total: u32 = get_total(table);
  assert(total <= maximum_total);
  range: u64 = high - low + 1;
  offset: u64 = code - low;
  value: u64 = ((offset + 1) * total - 1) / range;
  assert(value * range / total <= offset);
  assert(value < total);

  start: u32 = 0;
  end: u32 = cast(u32) table.frequencies.count;
  while end - start > 1 {
    middle: u32 = (start + end) >> 1; // @Robustness overflow?
    if table.cumulative[middle] > value then end = middle;
                                        else start = middle;
  }
  assert(start + 1 == end);

  symbol: u32 = start;
  assert(symbol < table.frequencies.count);
  assert(table.cumulative[symbol] * range / total <= offset);
  assert(offset < table.cumulative[symbol + 1] * range / total);

  update(dec, table, symbol, bis);
  assert(low <= code && code <= high);
  return symbol;
}

#scope_file

#import "Basic";
#import "Math";

init_aritmetic_coder_base :: (using base: *ArithmeticCoderBase, num_bits: u8) {
  assert(1 <= num_bits && num_bits <= 63);
  num_state_bits = num_bits;
  full_range = (cast(u64)1) << num_state_bits;
  half_range = full_range >> 1;
  quarter_range = half_range >> 1;
  minimum_range = quarter_range + 2;
  maximum_total = Min(U64_MAX / full_range, minimum_range);
  state_mask = full_range - 1;
  low = 0;
  high = state_mask;
}

update :: (using arithmetic_coder: *$T/ArithmeticCoderBase,
           freq_table: *FrequencyTable,
           symbol: u32,
           bit_stream: $BitStream) {
  // State check
  //assert(!(low >= high || (low & state_mask) != low || (high & state_mask) != high));
  assert(low < high);
  assert((low  & state_mask) == low);
  assert((high & state_mask) == high);

  range: u64 = high - low + 1;
  assert(minimum_range <= range && range <= full_range);

  // Frequency table values check
  total: u32 = get_total(freq_table);
  sym_low: u32;
  sym_high: u32;
  sym_low, sym_high = get_low_and_high(freq_table, symbol);
  assert(sym_low < sym_high);
  assert(total <= maximum_total);

  new_low : u64 = low + sym_low  * range / total;
  new_high: u64 = low + sym_high * range / total - 1;
  low  = new_low;
  high = new_high;

  while (((low ^ high) & half_range) == 0) {
    shift(arithmetic_coder, bit_stream);
    low  = ((low  << 1) & state_mask);
    high = ((high << 1) & state_mask) | 1;
  }

  while ((low & ~high & quarter_range) != 0) {
    underflow(arithmetic_coder, bit_stream);
    low  = ((low << 1) ^ half_range);
    high = ((high ^ half_range) << 1) | half_range | 1;
  }
}

read_code_bit :: inline (bis: *BitInputStream) -> u8 {
  bit: s16 = read_bit(bis);
  if bit == -1 then bit = 0;
  return cast(u8) bit;
}

checked_add :: inline (x: u32, y: u32) -> u32 #expand {
  assert(x <= U32_MAX - y);
  return x + y;
}

get_total :: (using table: FrequencyTable) -> u32 {
  return total;
}
