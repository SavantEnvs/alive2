// Fuzzes the whole Alive pipeline on a `.opt` input: parse, type inference, symbolic execution
// of source and target and the refinement-check setup. `util::config::skip_smt` is set once, exactly as
// `alive -skip-smt` does (tools/alive.cpp), so no refinement query is sent to Z3
// (check_each_var below only chooses which variables get checked).
#include "harness_common.h"

using namespace tools;

static smt::smt_initializer *smt_init;

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
  util::config::skip_smt = true;
  static smt::smt_initializer init;
  smt_init = &init;
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  auto buf = padded_copy(data, size);
  ParserSession session;
  try {
    auto transforms = parse(std::string_view(buf.data(), size));
    for (auto &t : transforms) {
      smt_init->reset();
      TransformVerify tv(t, /*check_each_var=*/true);
      auto types = tv.getTypings();
      if (!types)
        continue;
      for (; types; ++types) {
        tv.fixupTypes(types);
        auto errs = tv.verify();
        if (errs)
          break;
      }
    }
  } catch (const ParseException &) {
    return -1;
  } catch (const LexException &) {
    return -1;
  }
  return 0;
}
