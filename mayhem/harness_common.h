#pragma once

#include "smt/smt.h"
#include "tools/alive_lexer.h"
// Included as source, not linked: the parser keeps its state in file-static globals that only the
// one-shot `alive` CLI ever needed, so the harness has to be able to reset them between inputs.
#include "tools/alive_parser.cpp"
#include "util/config.h"
#include <cstddef>
#include <cstdint>
#include <vector>

// Alive's lexer reads up to LEXER_READ_AHEAD bytes past the end of the buffer
// and expects them to be NUL, exactly as util::file_reader pads a file.
static std::vector<char> padded_copy(const uint8_t *data, size_t size) {
  std::vector<char> buf(size + tools::PARSER_READ_AHEAD, 0);
  for (size_t i = 0; i < size; ++i)
    buf[i] = static_cast<char>(data[i]);
  return buf;
}

// One parse session. The parser leaves tokens, symbol tables and type caches in file-static
// globals; after a ParseException they would point into freed transforms, so everything is reset
// when the session ends. Declare it BEFORE the std::vector<Transform> that parse() returns.
struct ParserSession {
  tools::parser_initializer init;
  ~ParserSession() {
    tools::pointer_types.clear();
    tools::vector_types.clear();
    tools::array_types.clear();
    tools::struct_types.clear();
    tools::identifiers.clear();
    tools::identifiers_src.clear();
    tools::tokenizer.returned = false;
  }
};
