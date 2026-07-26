//// Tokenize shell input.

import gleam/float
import gleam/int
import gleam/list
import gleam/string

pub type Token {
  Ident(String)
  StringLit(String)
  IntLit(Int)
  FloatLit(Float)
  BoolLit(Bool)
  Pipe
  LBracket
  RBracket
  LBrace
  RBrace
  LParen
  RParen
  Colon
  Comma
  Dollar
  Eq
  Ne
  Gt
  Lt
  Ge
  Le
  Assign
  Flag(String)
  External
  NothingLit
  Eof
}

pub type LexError {
  LexError(message: String, position: Int)
}

pub fn tokenize(source: String) -> Result(List(Token), LexError) {
  do_tokenize(string.to_graphemes(source), 0, [])
}

fn do_tokenize(
  chars: List(String),
  pos: Int,
  acc: List(Token),
) -> Result(List(Token), LexError) {
  case chars {
    [] -> Ok(list.reverse([Eof, ..acc]))
    [" ", ..rest] | ["\t", ..rest] | ["\r", ..rest] ->
      do_tokenize(rest, pos + 1, acc)
    ["\n", ..rest] -> do_tokenize(rest, pos + 1, acc)
    ["#", ..rest] -> skip_comment(rest, pos + 1, acc)
    ["|", ..rest] -> do_tokenize(rest, pos + 1, [Pipe, ..acc])
    ["[", ..rest] -> do_tokenize(rest, pos + 1, [LBracket, ..acc])
    ["]", ..rest] -> do_tokenize(rest, pos + 1, [RBracket, ..acc])
    ["{", ..rest] -> do_tokenize(rest, pos + 1, [LBrace, ..acc])
    ["}", ..rest] -> do_tokenize(rest, pos + 1, [RBrace, ..acc])
    ["(", ..rest] -> do_tokenize(rest, pos + 1, [LParen, ..acc])
    [")", ..rest] -> do_tokenize(rest, pos + 1, [RParen, ..acc])
    [":", ..rest] -> do_tokenize(rest, pos + 1, [Colon, ..acc])
    [",", ..rest] -> do_tokenize(rest, pos + 1, [Comma, ..acc])
    ["$", ..rest] -> do_tokenize(rest, pos + 1, [Dollar, ..acc])
    ["^", ..rest] -> do_tokenize(rest, pos + 1, [External, ..acc])
    ["!", "=", ..rest] -> do_tokenize(rest, pos + 2, [Ne, ..acc])
    [">", "=", ..rest] -> do_tokenize(rest, pos + 2, [Ge, ..acc])
    ["<", "=", ..rest] -> do_tokenize(rest, pos + 2, [Le, ..acc])
    ["=", "=", ..rest] -> do_tokenize(rest, pos + 2, [Eq, ..acc])
    ["=", ..rest] -> do_tokenize(rest, pos + 1, [Assign, ..acc])
    [">", ..rest] -> do_tokenize(rest, pos + 1, [Gt, ..acc])
    ["<", ..rest] -> do_tokenize(rest, pos + 1, [Lt, ..acc])
    ["\"", ..rest] -> {
      case read_string(rest, pos + 1, "") {
        Ok(#(s, after, new_pos)) ->
          do_tokenize(after, new_pos, [StringLit(s), ..acc])
        Error(e) -> Error(e)
      }
    }
    ["'", ..rest] -> {
      case read_single_string(rest, pos + 1, "") {
        Ok(#(s, after, new_pos)) ->
          do_tokenize(after, new_pos, [StringLit(s), ..acc])
        Error(e) -> Error(e)
      }
    }
    ["-", "-", ..rest] -> {
      let #(name, after, new_pos) = read_ident_body(rest, pos + 2, "")
      case name {
        // Bare `--` is the POSIX end-of-options marker (`nix run . -- args`).
        // Empty flag name is parsed as a literal `"--"` argument.
        "" -> do_tokenize(after, new_pos, [Flag(""), ..acc])
        n -> do_tokenize(after, new_pos, [Flag(n), ..acc])
      }
    }
    ["-", d, ..rest] -> {
      case is_digit(d) {
        True -> {
          let #(num_str, after, new_pos) =
            read_number(["-", d, ..rest], pos, "")
          case parse_number(num_str) {
            Ok(tok) -> do_tokenize(after, new_pos, [tok, ..acc])
            Error(msg) -> Error(LexError(msg, pos))
          }
        }
        False -> {
          // short flag -x
          let #(name, after, new_pos) =
            read_ident_body([d, ..rest], pos + 1, "")
          case name {
            "" -> Error(LexError("expected flag name after -", pos))
            n -> do_tokenize(after, new_pos, [Flag(n), ..acc])
          }
        }
      }
    }
    [c, ..] -> {
      case is_digit(c) {
        True -> {
          let #(num_str, after, new_pos) = read_number(chars, pos, "")
          case parse_number(num_str) {
            Ok(tok) -> do_tokenize(after, new_pos, [tok, ..acc])
            Error(msg) -> Error(LexError(msg, pos))
          }
        }
        False ->
          case is_ident_start(c) {
            True -> {
              let #(name, after, new_pos) = read_ident_body(chars, pos, "")
              let tok = keyword_or_ident(name)
              do_tokenize(after, new_pos, [tok, ..acc])
            }
            False -> Error(LexError("unexpected character '" <> c <> "'", pos))
          }
      }
    }
  }
}

fn skip_comment(
  chars: List(String),
  pos: Int,
  acc: List(Token),
) -> Result(List(Token), LexError) {
  case chars {
    [] -> do_tokenize([], pos, acc)
    ["\n", ..rest] -> do_tokenize(rest, pos + 1, acc)
    [_, ..rest] -> skip_comment(rest, pos + 1, acc)
  }
}

fn read_string(
  chars: List(String),
  pos: Int,
  acc: String,
) -> Result(#(String, List(String), Int), LexError) {
  case chars {
    [] -> Error(LexError("unterminated string", pos))
    ["\"", ..rest] -> Ok(#(acc, rest, pos + 1))
    ["\\", "n", ..rest] -> read_string(rest, pos + 2, acc <> "\n")
    ["\\", "t", ..rest] -> read_string(rest, pos + 2, acc <> "\t")
    ["\\", "\"", ..rest] -> read_string(rest, pos + 2, acc <> "\"")
    ["\\", "\\", ..rest] -> read_string(rest, pos + 2, acc <> "\\")
    ["\\", c, ..rest] -> read_string(rest, pos + 2, acc <> c)
    [c, ..rest] -> read_string(rest, pos + 1, acc <> c)
  }
}

fn read_single_string(
  chars: List(String),
  pos: Int,
  acc: String,
) -> Result(#(String, List(String), Int), LexError) {
  case chars {
    [] -> Error(LexError("unterminated string", pos))
    ["'", ..rest] -> Ok(#(acc, rest, pos + 1))
    ["\\", "'", ..rest] -> read_single_string(rest, pos + 2, acc <> "'")
    ["\\", "\\", ..rest] -> read_single_string(rest, pos + 2, acc <> "\\")
    [c, ..rest] -> read_single_string(rest, pos + 1, acc <> c)
  }
}

fn read_ident_body(
  chars: List(String),
  pos: Int,
  acc: String,
) -> #(String, List(String), Int) {
  case chars {
    [c, ..rest] ->
      case is_ident_continue(c) {
        True -> read_ident_body(rest, pos + 1, acc <> c)
        False -> #(acc, chars, pos)
      }
    [] -> #(acc, [], pos)
  }
}

fn read_number(
  chars: List(String),
  pos: Int,
  acc: String,
) -> #(String, List(String), Int) {
  case chars {
    ["-", ..rest] if acc == "" -> read_number(rest, pos + 1, "-")
    [c, ..rest] ->
      case is_digit(c) || c == "." {
        True -> read_number(rest, pos + 1, acc <> c)
        False -> #(acc, chars, pos)
      }
    [] -> #(acc, [], pos)
  }
}

fn parse_number(s: String) -> Result(Token, String) {
  case string.contains(s, ".") {
    True ->
      case float.parse(s) {
        Ok(f) -> Ok(FloatLit(f))
        Error(Nil) -> Error("invalid float '" <> s <> "'")
      }
    False ->
      case int.parse(s) {
        Ok(n) -> Ok(IntLit(n))
        Error(Nil) -> Error("invalid integer '" <> s <> "'")
      }
  }
}

fn keyword_or_ident(name: String) -> Token {
  case name {
    "true" | "True" -> BoolLit(True)
    "false" | "False" -> BoolLit(False)
    "null" | "nothing" | "Nothing" -> NothingLit
    _ -> Ident(name)
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
    // Paths: `.jj`, `..`, `./src`, `/tmp`, `~/code`
    "_" | "." | "/" | "~" -> True
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
  // Path-ish chars: letters/digits already covered; keep `.` `/` `-` `~` mid-token.
  // `#` mid-token for flake refs (`nixpkgs#hello`, `.#package`); bare `#` still
  // starts a comment at a word boundary (handled in do_tokenize).
  // `@` mid-token for SSH/git URLs (`git@host:path`, `user@host`).
  is_ident_start(c) || is_digit(c) || c == "-" || c == "#" || c == "@"
}
