//// Live syntax highlighting for the REPL input line (Nushell-style shapes).

import gleam/list
import gleam/string
import gleshell/builtins
import gleshell/color

/// Colorize a (possibly incomplete) input line for the line editor.
/// Safe to call on every keystroke; never fails.
pub fn line(source: String) -> String {
  highlight(color.enabled(), source)
}

/// Colorize with an explicit on/off switch (tests / `NO_COLOR`).
pub fn highlight(on: Bool, source: String) -> String {
  case on {
    False -> source
    True -> {
      let builtins = builtins.names()
      paint_chars(string.to_graphemes(source), ExpectCommand, builtins, "")
    }
  }
}

type Expect {
  ExpectCommand
  ExpectArg
}

fn paint_chars(
  chars: List(String),
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  case chars {
    [] -> acc
    [" ", ..rest] -> paint_chars(rest, expect, builtins, acc <> " ")
    ["\t", ..rest] -> paint_chars(rest, expect, builtins, acc <> "\t")
    ["\r", ..rest] | ["\n", ..rest] -> paint_chars(rest, expect, builtins, acc)
    ["#", ..rest] -> {
      let text = "#" <> string.concat(rest)
      acc <> color.shape_comment(True, text)
    }
    ["|", ..rest] ->
      paint_chars(
        rest,
        ExpectCommand,
        builtins,
        acc <> color.shape_pipe(True, "|"),
      )
    ["^", ..rest] ->
      // Force external: next command word is external
      paint_after_external_mark(rest, builtins, acc <> color.shape_operator(True, "^"))
    ["$", ..rest] -> paint_variable(rest, expect, builtins, acc)
    ["\"", ..rest] -> paint_dq_string(rest, expect, builtins, acc)
    ["'", ..rest] -> paint_sq_string(rest, expect, builtins, acc)
    ["[", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_list(True, "["),
      )
    ["]", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_list(True, "]"),
      )
    ["{", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_record(True, "{"),
      )
    ["}", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_record(True, "}"),
      )
    ["(", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, "("),
      )
    [")", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, ")"),
      )
    [":", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, ":"),
      )
    [",", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, ","),
      )
    ["!", "=", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, "!="),
      )
    [">", "=", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, ">="),
      )
    ["<", "=", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, "<="),
      )
    ["=", "=", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, "=="),
      )
    ["=", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, "="),
      )
    [">", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, ">"),
      )
    ["<", ..rest] ->
      paint_chars(
        rest,
        ExpectArg,
        builtins,
        acc <> color.shape_operator(True, "<"),
      )
    ["-", "-", ..rest] -> paint_flag(rest, "--", expect, builtins, acc)
    ["-", d, ..rest] ->
      case is_digit(d) {
        True -> paint_number(["-", d, ..rest], expect, builtins, acc)
        False -> paint_flag([d, ..rest], "-", expect, builtins, acc)
      }
    [c, ..] ->
      case is_digit(c) {
        True -> paint_number(chars, expect, builtins, acc)
        False ->
          case is_ident_start(c) {
            True -> paint_ident(chars, expect, builtins, acc)
            False ->
              // Unknown char — mark as garbage and continue
              paint_chars(
                list.drop(chars, 1),
                expect,
                builtins,
                acc <> color.shape_garbage(True, c),
              )
          }
      }
  }
}

fn paint_after_external_mark(
  chars: List(String),
  builtins: List(String),
  acc: String,
) -> String {
  case chars {
    [" ", ..rest] -> paint_after_external_mark(rest, builtins, acc <> " ")
    ["\t", ..rest] -> paint_after_external_mark(rest, builtins, acc <> "\t")
    [] -> acc
    _ -> {
      let #(word, after) = take_ident(chars)
      case word {
        "" -> paint_chars(chars, ExpectArg, builtins, acc)
        w ->
          paint_chars(
            after,
            ExpectArg,
            builtins,
            acc <> color.shape_external(True, w),
          )
      }
    }
  }
}

fn paint_variable(
  chars: List(String),
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  let #(name, after) = take_ident(chars)
  let painted = color.shape_variable(True, "$" <> name)
  paint_chars(after, next_expect(expect), builtins, acc <> painted)
}

fn paint_dq_string(
  chars: List(String),
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  let #(body, after, closed) = take_dq_body(chars, "")
  let painted = case closed {
    True -> color.shape_string(True, "\"" <> body <> "\"")
    False -> color.shape_string(True, "\"" <> body)
  }
  paint_chars(after, next_expect(expect), builtins, acc <> painted)
}

fn take_dq_body(
  chars: List(String),
  acc: String,
) -> #(String, List(String), Bool) {
  case chars {
    [] -> #(acc, [], False)
    ["\"", ..rest] -> #(acc, rest, True)
    ["\\", c, ..rest] -> take_dq_body(rest, acc <> "\\" <> c)
    ["\\"] -> #(acc <> "\\", [], False)
    [c, ..rest] -> take_dq_body(rest, acc <> c)
  }
}

fn paint_sq_string(
  chars: List(String),
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  let #(body, after, closed) = take_sq_body(chars, "")
  let painted = case closed {
    True -> color.shape_string(True, "'" <> body <> "'")
    False -> color.shape_string(True, "'" <> body)
  }
  paint_chars(after, next_expect(expect), builtins, acc <> painted)
}

fn take_sq_body(
  chars: List(String),
  acc: String,
) -> #(String, List(String), Bool) {
  case chars {
    [] -> #(acc, [], False)
    ["'", ..rest] -> #(acc, rest, True)
    ["\\", c, ..rest] -> take_sq_body(rest, acc <> "\\" <> c)
    ["\\"] -> #(acc <> "\\", [], False)
    [c, ..rest] -> take_sq_body(rest, acc <> c)
  }
}

fn paint_flag(
  chars: List(String),
  prefix: String,
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  let #(name, after) = take_ident(chars)
  let painted = color.shape_flag(True, prefix <> name)
  paint_chars(after, next_expect(expect), builtins, acc <> painted)
}

fn paint_number(
  chars: List(String),
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  let #(num, after, is_float) = take_number(chars)
  let painted = case is_float {
    True -> color.shape_float(True, num)
    False -> color.shape_int(True, num)
  }
  paint_chars(after, next_expect(expect), builtins, acc <> painted)
}

fn paint_ident(
  chars: List(String),
  expect: Expect,
  builtins: List(String),
  acc: String,
) -> String {
  let #(word, after) = take_ident(chars)
  case word {
    "true" | "True" | "false" | "False" ->
      paint_chars(
        after,
        next_expect(expect),
        builtins,
        acc <> color.shape_bool(True, word),
      )
    "null" | "nothing" | "Nothing" ->
      paint_chars(
        after,
        next_expect(expect),
        builtins,
        acc <> color.shape_nothing(True, word),
      )
    "let" ->
      case expect {
        ExpectCommand ->
          paint_chars(
            after,
            ExpectArg,
            builtins,
            acc <> color.shape_keyword(True, word),
          )
        ExpectArg ->
          paint_chars(
            after,
            ExpectArg,
            builtins,
            acc <> color.shape_externalarg(True, word),
          )
      }
    _ ->
      case expect {
        ExpectCommand -> paint_command(word, after, builtins, acc)
        ExpectArg ->
          paint_chars(
            after,
            ExpectArg,
            builtins,
            acc <> color.shape_externalarg(True, word),
          )
      }
  }
}

fn paint_command(
  word: String,
  after: List(String),
  builtins: List(String),
  acc: String,
) -> String {
  // Multi-word builtins: `to json`, `from json`
  case word {
    "to" | "from" -> {
      let #(ws, rest1) = take_space(after)
      let #(next, rest2) = take_ident(rest1)
      case next {
        "json" -> {
          let full = word <> ws <> next
          paint_chars(
            rest2,
            ExpectArg,
            builtins,
            acc <> color.shape_internalcall(True, full),
          )
        }
        _ -> paint_single_command(word, after, builtins, acc)
      }
    }
    _ -> paint_single_command(word, after, builtins, acc)
  }
}

fn paint_single_command(
  word: String,
  after: List(String),
  builtins: List(String),
  acc: String,
) -> String {
  let painted = case list.contains(builtins, word) {
    True -> color.shape_internalcall(True, word)
    False -> color.shape_external(True, word)
  }
  paint_chars(after, ExpectArg, builtins, acc <> painted)
}

fn next_expect(expect: Expect) -> Expect {
  case expect {
    ExpectCommand -> ExpectArg
    ExpectArg -> ExpectArg
  }
}

fn take_space(chars: List(String)) -> #(String, List(String)) {
  take_space_loop(chars, "")
}

fn take_space_loop(chars: List(String), acc: String) -> #(String, List(String)) {
  case chars {
    [" ", ..rest] -> take_space_loop(rest, acc <> " ")
    ["\t", ..rest] -> take_space_loop(rest, acc <> "\t")
    _ -> #(acc, chars)
  }
}

fn take_ident(chars: List(String)) -> #(String, List(String)) {
  take_ident_loop(chars, "")
}

fn take_ident_loop(chars: List(String), acc: String) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case is_ident_continue(c) {
        True -> take_ident_loop(rest, acc <> c)
        False -> #(acc, chars)
      }
    [] -> #(acc, [])
  }
}

fn take_number(chars: List(String)) -> #(String, List(String), Bool) {
  case chars {
    ["-", ..rest] -> take_number_loop(rest, "-", False)
    _ -> take_number_loop(chars, "", False)
  }
}

fn take_number_loop(
  chars: List(String),
  acc: String,
  seen_dot: Bool,
) -> #(String, List(String), Bool) {
  case chars {
    [c, ..rest] ->
      case is_digit(c) {
        True -> take_number_loop(rest, acc <> c, seen_dot)
        False ->
          case c == "." && !seen_dot {
            True -> take_number_loop(rest, acc <> c, True)
            False -> #(acc, chars, seen_dot)
          }
      }
    [] -> #(acc, [], seen_dot)
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_ident_start(c: String) -> Bool {
  case c {
    "_" -> True
    _ -> {
      let lower = string.lowercase(c)
      case lower {
        "a"
        | "b"
        | "c"
        | "d"
        | "e"
        | "f"
        | "g"
        | "h"
        | "i"
        | "j"
        | "k"
        | "l"
        | "m"
        | "n"
        | "o"
        | "p"
        | "q"
        | "r"
        | "s"
        | "t"
        | "u"
        | "v"
        | "w"
        | "x"
        | "y"
        | "z" -> True
        _ -> False
      }
    }
  }
}

fn is_ident_continue(c: String) -> Bool {
  is_ident_start(c) || is_digit(c) || c == "-" || c == "." || c == "/"
}
