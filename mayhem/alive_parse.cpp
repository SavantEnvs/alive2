// Fuzzes the Alive `.opt` DSL front end: lexer + parser + IR construction + printing.
#include "harness_common.h"
#include <sstream>

using namespace tools;

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
  static smt::smt_initializer smt_init;
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  auto buf = padded_copy(data, size);
  ParserSession session;
  try {
    auto transforms = parse(std::string_view(buf.data(), size));
    TransformPrintOpts opts;
    opts.print_fn_header = false;
    std::ostringstream os;
    for (auto &t : transforms) {
      t.print(os, opts);
      os << '\n';
    }
  } catch (const ParseException &) {
    return -1;
  } catch (const LexException &) {
    return -1;
  }
  return 0;
}
