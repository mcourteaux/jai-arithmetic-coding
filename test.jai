#import "Basic";
#import "Random";

#load "module.jai";

main :: () {
  NUM_SYMBOLS :: 1000;

  table: FrequencyTable;
  freqs: [NUM_SYMBOLS] u32;
  for 0..NUM_SYMBOLS-1 {
    freqs[it] = cast(u32) it + 1;
  }
  init_frequency_table(*table, freqs);
  defer free_frequency_table(*table);


  SEQUENCE_LENGTH :: 1024 * 16;
  input_sequence: [SEQUENCE_LENGTH] u32 = ---;
  for * input_sequence {
    <<it = cast(u32) (random_get() % NUM_SYMBOLS);
  }

  encoder: ArithmeticEncoder;
  init_encoder(*encoder, 32);


  bos: BitOutputStream;
  buffer: [..]u8;
  bos.user_data = cast(*void) *buffer;
  bos.write_byte_proc = (user_data: *void, byte: u8) {
    buffer := cast(*[..]u8) user_data;
    array_add(buffer, byte);
  };

  for input_sequence {
    write(*encoder, *bos, *table, it);
  }
  finish(*encoder, *bos);
  finish(*bos);

  print("bytes produced: %\n", buffer.count);

  bis: BitInputStream;
  bis.user_data = cast(*void) *buffer;
  bis.read_byte_proc = (user_data: *void) -> s16 {
    buffer := cast(*[..]u8) user_data;
    if buffer.count == 0 return -1;
    result := (<<buffer)[0];
    buffer.data += 1;
    buffer.count -= 1;
    return result;
  };

  decoder: ArithmeticDecoder;
  init_decoder(*decoder, *bis);
  good := true;
  for input_sequence {
    reconstructed := read(*decoder, *table, *bis);
    if reconstructed != it {
      print("Decoded result wrong at index=%: decoded=%, expected=%\n",
            it_index, reconstructed, it);
      good = false;
    }
  }
  if good {
    print("Succesfully decoded all symbols correctly.\n");
  }
}
