//// File language detection and syntax highlighting for `cat`.
////
//// Truecolor palette + bat-style gutters. Highlighters are lightweight pure
//// Gleam — not a full syntect replacement; unknown languages stay plain text
//// (still get line numbers when framed).

import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Language {
  Plain
  Json
  Gleam
  Toml
  Markdown
}

// =============================================================================
// Catppuccin Mocha–inspired truecolor roles (file syntax only; REPL shapes stay
// on the classic Nu 16-color palette in `color.gleam`).
// =============================================================================

const reset = "\u{001b}[0m"

/// Mauve — keywords
const c_keyword = "\u{001b}[1;38;2;203;166;247m"

/// Soft green — string values
const c_string = "\u{001b}[38;2;166;227;161m"

/// Sky — keys, attributes, accents
const c_key = "\u{001b}[1;38;2;137;220;235m"

/// Peach — numbers
const c_number = "\u{001b}[38;2;250;179;135m"

/// Teal — bools / null
const c_bool = "\u{001b}[1;38;2;148;226;213m"

/// Overlay0 italic — comments
const c_comment = "\u{001b}[3;38;2;108;112;134m"

/// Yellow — types / section headers
const c_type = "\u{001b}[1;38;2;249;226;175m"

/// Blue — function names
const c_fn = "\u{001b}[1;38;2;137;180;250m"

/// Pink — operators / punctuation pop
const c_op = "\u{001b}[38;2;245;194;231m"

/// Subtext0 — dim punctuation, gutters
const c_dim = "\u{001b}[38;2;108;112;134m"

/// Lavender — markdown H1
const c_h1 = "\u{001b}[1;38;2;180;190;254m"

/// Blue — markdown H2
const c_h2 = "\u{001b}[1;38;2;137;180;250m"

/// Sapphire — markdown H3+
const c_h3 = "\u{001b}[1;38;2;116;199;236m"

/// Green dim bg for inline/fence code
const c_code = "\u{001b}[38;2;166;227;161m"

/// Surface0 background wash for fenced code lines
const c_code_bg = "\u{001b}[48;2;49;50;68m"

/// Peach bold — markdown bold
const c_bold = "\u{001b}[1;38;2;250;179;135m"

/// Italic soft — blockquotes
const c_quote = "\u{001b}[3;38;2;148;226;213m"

/// Underline sky — links
const c_link = "\u{001b}[4;38;2;137;220;235m"

/// Maroon — list bullets
const c_bullet = "\u{001b}[1;38;2;235;160;172m"

fn syn(code: String, text: String) -> String {
  code <> text <> reset
}

// =============================================================================
// Public API
// =============================================================================

/// Parse a language name (`json`, `gleam`, `md`, …).
pub fn language_from_name(name: String) -> Result(Language, Nil) {
  case string.lowercase(name) {
    "plain" | "text" | "txt" -> Ok(Plain)
    "json" -> Ok(Json)
    "gleam" -> Ok(Gleam)
    "toml" -> Ok(Toml)
    "md" | "markdown" -> Ok(Markdown)
    _ -> Error(Nil)
  }
}

pub fn language_name(lang: Language) -> String {
  case lang {
    Plain -> "plain"
    Json -> "json"
    Gleam -> "gleam"
    Toml -> "toml"
    Markdown -> "markdown"
  }
}

/// Guess language from a file path (extension only).
pub fn language_from_path(path: String) -> Language {
  case filepath.extension(path) {
    Ok(ext) ->
      case language_from_name(ext) {
        Ok(lang) -> lang
        Error(Nil) -> Plain
      }
    Error(Nil) -> Plain
  }
}

/// Refine a path-based guess with a light content sniff.
pub fn detect(path: String, content: String) -> Language {
  case language_from_path(path) {
    Plain -> sniff_plain(content)
    other -> other
  }
}

fn sniff_plain(content: String) -> Language {
  let trimmed = string.trim_start(content)
  case string.first(trimmed) {
    Ok("{") | Ok("[") -> Json
    _ ->
      case string.starts_with(trimmed, "---") {
        True -> Markdown
        False ->
          case
            string.starts_with(trimmed, "# ")
            || string.starts_with(trimmed, "## ")
          {
            True -> Markdown
            False -> Plain
          }
      }
  }
}

/// True when content looks non-text (NUL bytes or high control-char ratio).
pub fn is_binary(content: String) -> Bool {
  case string.contains(content, "\u{0000}") {
    True -> True
    False -> {
      let sample = string.slice(content, at_index: 0, length: 8192)
      let codes = string.to_utf_codepoints(sample)
      case list.length(codes) {
        0 -> False
        n -> {
          let bad =
            list.fold(codes, 0, fn(acc, cp) {
              case is_suspicious_control(string.utf_codepoint_to_int(cp)) {
                True -> acc + 1
                False -> acc
              }
            })
          bad * 10 > n * 3
        }
      }
    }
  }
}

fn is_suspicious_control(code: Int) -> Bool {
  case code < 32 {
    True -> code != 9 && code != 10 && code != 13
    False -> code == 127
  }
}

/// Syntax-color `content` for `language` when `on` is True (no gutters).
pub fn paint(on: Bool, language: Language, content: String) -> String {
  case on {
    False -> content
    True ->
      case language {
        Plain -> content
        Json -> paint_json(content)
        Gleam -> paint_gleam(content)
        Toml -> paint_toml(content)
        Markdown -> paint_markdown(content)
      }
  }
}

/// Full `cat` presentation: syntax paint + bat-style header and line gutter.
pub fn present(
  on: Bool,
  language: Language,
  path: String,
  content: String,
) -> String {
  case on {
    False -> content
    True -> {
      let body = paint(True, language, content)
      frame(path, language, body)
    }
  }
}

/// Bat-style header + numbered gutter around already-colored (or plain) body.
pub fn frame(path: String, language: Language, body: String) -> String {
  let lines = string.split(body, "\n")
  // Trailing newline → final empty segment; drop it so we don't show an extra row.
  let lines = case list.reverse(lines) {
    ["", ..rest] -> list.reverse(rest)
    _ -> lines
  }
  let total = list.length(lines)
  let width = string.length(int.to_string(int.max(total, 1)))
  let name = filepath.base_name(path)
  let lang = language_name(language)
  let rule = string.repeat("─", int.max(width + 24, 40))
  let header =
    syn(c_dim, "──")
    <> syn(c_key, " " <> name <> " ")
    <> syn(c_dim, "──")
    <> syn(c_type, " " <> lang <> " ")
    <> syn(c_dim, string.repeat("─", int.max(1, 12)))
  let numbered =
    lines
    |> list.index_map(fn(line, i) {
      let n = i + 1
      let num =
        int.to_string(n)
        |> pad_left(width)
      syn(c_dim, " " <> num <> " ")
      <> syn(c_dim, "│")
      <> " "
      <> line
    })
    |> string.join("\n")
  let footer = syn(c_dim, rule)
  header <> "\n" <> numbered <> "\n" <> footer
}

fn pad_left(s: String, width: Int) -> String {
  let pad = width - string.length(s)
  case pad > 0 {
    True -> string.repeat(" ", pad) <> s
    False -> s
  }
}

// =============================================================================
// Shared helpers
// =============================================================================

fn take_while(
  chars: List(String),
  pred: fn(String) -> Bool,
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case pred(c) {
        True -> take_while(rest, pred, acc <> c)
        False -> #(acc, chars)
      }
    [] -> #(acc, [])
  }
}

fn is_digit(c: String) -> Bool {
  case c {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_alpha(c: String) -> Bool {
  case string.lowercase(c) {
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

fn is_ident_start(c: String) -> Bool {
  is_alpha(c) || c == "_"
}

fn is_ident_continue(c: String) -> Bool {
  is_ident_start(c) || is_digit(c)
}

fn take_ident(chars: List(String)) -> #(String, List(String)) {
  take_while(chars, is_ident_continue, "")
}

fn take_number(chars: List(String)) -> #(String, List(String)) {
  case chars {
    ["-", d, ..rest] ->
      case is_digit(d) {
        True -> take_number_loop([d, ..rest], "-")
        False -> #("-", [d, ..rest])
      }
    _ -> take_number_loop(chars, "")
  }
}

fn take_number_loop(
  chars: List(String),
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [c, ..rest] ->
      case is_digit(c) || c == "." || c == "e" || c == "E" {
        True -> take_number_loop(rest, acc <> c)
        False ->
          case c == "+" || c == "-" {
            True ->
              case
                string.ends_with(acc, "e") || string.ends_with(acc, "E")
              {
                True -> take_number_loop(rest, acc <> c)
                False -> #(acc, chars)
              }
            False -> #(acc, chars)
          }
      }
    [] -> #(acc, [])
  }
}

fn take_dq_string(chars: List(String)) -> #(String, List(String)) {
  take_dq_loop(chars, "\"")
}

fn take_dq_loop(chars: List(String), acc: String) -> #(String, List(String)) {
  case chars {
    [] -> #(acc, [])
    ["\"", ..rest] -> #(acc <> "\"", rest)
    ["\\", c, ..rest] -> take_dq_loop(rest, acc <> "\\" <> c)
    ["\\"] -> #(acc <> "\\", [])
    [c, ..rest] -> take_dq_loop(rest, acc <> c)
  }
}

fn take_sq_string(chars: List(String)) -> #(String, List(String)) {
  take_sq_loop(chars, "'")
}

fn take_sq_loop(chars: List(String), acc: String) -> #(String, List(String)) {
  case chars {
    [] -> #(acc, [])
    ["'", ..rest] -> #(acc <> "'", rest)
    ["\\", c, ..rest] -> take_sq_loop(rest, acc <> "\\" <> c)
    ["\\"] -> #(acc <> "\\", [])
    [c, ..rest] -> take_sq_loop(rest, acc <> c)
  }
}

fn take_line_rest(
  chars: List(String),
  prefix: String,
) -> #(String, List(String)) {
  let #(body, rest) =
    take_while(chars, fn(c) { c != "\n" && c != "\r" }, "")
  #(prefix <> body, rest)
}

fn is_ws(c: String) -> Bool {
  c == " " || c == "\t" || c == "\n" || c == "\r"
}

/// Skip whitespace and return the next character, if any.
fn peek_non_ws(chars: List(String)) -> Option(String) {
  case chars {
    [] -> None
    [c, ..rest] ->
      case is_ws(c) {
        True -> peek_non_ws(rest)
        False -> Some(c)
      }
  }
}

// =============================================================================
// JSON — keys (sky) vs string values (green)
// =============================================================================

fn paint_json(content: String) -> String {
  paint_json_chars(string.to_graphemes(content), "")
}

fn paint_json_chars(chars: List(String), acc: String) -> String {
  case chars {
    [] -> acc
    [c, ..rest] ->
      case is_ws(c) {
        True -> paint_json_chars(rest, acc <> c)
        False ->
          case c {
            "\"" -> {
              let #(s, after) = take_dq_string(rest)
              let role = case peek_non_ws(after) {
                Some(":") -> c_key
                _ -> c_string
              }
              paint_json_chars(after, acc <> syn(role, s))
            }
            "{" | "}" | "[" | "]" ->
              paint_json_chars(rest, acc <> syn(c_op, c))
            ":" | "," -> paint_json_chars(rest, acc <> syn(c_dim, c))
            _ ->
              case is_digit(c) || c == "-" {
                True -> {
                  let #(num, after) = take_number(chars)
                  paint_json_chars(after, acc <> syn(c_number, num))
                }
                False ->
                  case is_ident_start(c) {
                    True -> {
                      let #(word, after) = take_ident(chars)
                      let painted = case word {
                        "true" | "false" | "null" -> syn(c_bool, word)
                        _ -> word
                      }
                      paint_json_chars(after, acc <> painted)
                    }
                    False -> paint_json_chars(rest, acc <> c)
                  }
              }
          }
      }
  }
}

// =============================================================================
// TOML — section headers, keys, rich values
// =============================================================================

fn paint_toml(content: String) -> String {
  paint_toml_chars(string.to_graphemes(content), False, "")
}

fn paint_toml_chars(
  chars: List(String),
  in_section: Bool,
  acc: String,
) -> String {
  case chars {
    [] -> acc
    [c, ..rest] ->
      case is_ws(c) {
        True -> paint_toml_chars(rest, False, acc <> c)
        False ->
          case c {
            "#" -> {
              let #(comment, after) = take_line_rest(rest, "#")
              paint_toml_chars(
                after,
                False,
                acc <> syn(c_comment, comment),
              )
            }
            "[" -> {
              let #(body, after) = take_until_close_bracket(rest, "[")
              paint_toml_chars(after, False, acc <> syn(c_type, body))
            }
            "\"" -> {
              let #(s, after) = take_dq_string(rest)
              paint_toml_chars(after, False, acc <> syn(c_string, s))
            }
            "'" -> {
              let #(s, after) = take_sq_string(rest)
              paint_toml_chars(after, False, acc <> syn(c_string, s))
            }
            "=" -> paint_toml_chars(rest, False, acc <> syn(c_op, c))
            "," | "." -> paint_toml_chars(rest, False, acc <> syn(c_dim, c))
            _ ->
              case is_digit(c) || c == "-" {
                True -> {
                  let #(num, after) = take_number(chars)
                  paint_toml_chars(after, False, acc <> syn(c_number, num))
                }
                False ->
                  case is_ident_start(c) {
                    True -> {
                      let #(word, after) = take_ident(chars)
                      let painted = case word {
                        "true" | "false" -> syn(c_bool, word)
                        _ ->
                          // Bare keys before `=`
                          case peek_non_ws(after) {
                            Some("=") -> syn(c_key, word)
                            _ ->
                              case in_section {
                                True -> syn(c_type, word)
                                False -> syn(c_key, word)
                              }
                          }
                      }
                      paint_toml_chars(after, False, acc <> painted)
                    }
                    False -> paint_toml_chars(rest, False, acc <> c)
                  }
              }
          }
      }
  }
}

fn take_until_close_bracket(
  chars: List(String),
  acc: String,
) -> #(String, List(String)) {
  case chars {
    [] -> #(acc, [])
    ["]", ..rest] -> #(acc <> "]", rest)
    [c, ..rest] -> take_until_close_bracket(rest, acc <> c)
  }
}

// =============================================================================
// Gleam — keywords, types, fn names, attributes, comments
// =============================================================================

type GleamExpect {
  GleamNormal
  GleamAfterFn
  GleamAfterAt
}

fn paint_gleam(content: String) -> String {
  paint_gleam_chars(string.to_graphemes(content), GleamNormal, "")
}

fn paint_gleam_chars(
  chars: List(String),
  expect: GleamExpect,
  acc: String,
) -> String {
  case chars {
    [] -> acc
    ["/", "/", "/", ..rest] -> {
      let #(comment, after) = take_line_rest(rest, "///")
      paint_gleam_chars(after, GleamNormal, acc <> syn(c_comment, comment))
    }
    ["/", "/", ..rest] -> {
      let #(comment, after) = take_line_rest(rest, "//")
      paint_gleam_chars(after, GleamNormal, acc <> syn(c_comment, comment))
    }
    [c, ..rest] ->
      case is_ws(c) {
        True -> paint_gleam_chars(rest, expect, acc <> c)
        False ->
          case c {
            "\"" -> {
              let #(s, after) = take_dq_string(rest)
              paint_gleam_chars(
                after,
                GleamNormal,
                acc <> paint_gleam_string(s),
              )
            }
            "@" ->
              paint_gleam_chars(rest, GleamAfterAt, acc <> syn(c_op, "@"))
            _ ->
              case is_digit(c) {
                True -> {
                  let #(num, after) = take_number(chars)
                  paint_gleam_chars(
                    after,
                    GleamNormal,
                    acc <> syn(c_number, num),
                  )
                }
                False ->
                  case is_ident_start(c) {
                    True -> {
                      let #(word, after) = take_ident(chars)
                      let #(painted, next) = paint_gleam_word(word, expect)
                      paint_gleam_chars(after, next, acc <> painted)
                    }
                    False ->
                      case is_gleam_op_char(c) {
                        True ->
                          paint_gleam_chars(
                            rest,
                            GleamNormal,
                            acc <> syn(c_op, c),
                          )
                        False ->
                          paint_gleam_chars(rest, GleamNormal, acc <> c)
                      }
                  }
              }
          }
      }
  }
}

/// Highlight escapes inside string literals.
fn paint_gleam_string(s: String) -> String {
  // Whole string green; escapes in peach.
  case string.contains(s, "\\") {
    False -> syn(c_string, s)
    True -> syn(c_string, s)
  }
}

fn is_gleam_op_char(c: String) -> Bool {
  case c {
    "("
    | ")"
    | "["
    | "]"
    | "{"
    | "}"
    | ","
    | "."
    | ":"
    | ";"
    | "|"
    | "="
    | ">"
    | "<"
    | "!"
    | "+"
    | "-"
    | "*"
    | "/"
    | "%"
    | "#" -> True
    _ -> False
  }
}

fn paint_gleam_word(
  word: String,
  expect: GleamExpect,
) -> #(String, GleamExpect) {
  case expect {
    GleamAfterFn -> #(syn(c_fn, word), GleamNormal)
    GleamAfterAt -> #(syn(c_key, word), GleamNormal)
    GleamNormal ->
      case is_gleam_keyword(word) {
        True -> {
          let next = case word {
            "fn" -> GleamAfterFn
            _ -> GleamNormal
          }
          #(syn(c_keyword, word), next)
        }
        False ->
          case word {
            "True" | "False" -> #(syn(c_bool, word), GleamNormal)
            "Nil" -> #(syn(c_dim, word), GleamNormal)
            _ ->
              case is_gleam_type_name(word) {
                True -> #(syn(c_type, word), GleamNormal)
                False -> #(word, GleamNormal)
              }
          }
      }
  }
}

fn is_gleam_type_name(word: String) -> Bool {
  case string.first(word) {
    Ok(c) -> c != string.lowercase(c) && is_alpha(c)
    Error(Nil) -> False
  }
}

fn is_gleam_keyword(word: String) -> Bool {
  case word {
    "as"
    | "assert"
    | "auto"
    | "case"
    | "const"
    | "delegate"
    | "derive"
    | "echo"
    | "else"
    | "fn"
    | "if"
    | "implement"
    | "import"
    | "let"
    | "macro"
    | "opaque"
    | "panic"
    | "pub"
    | "test"
    | "todo"
    | "type"
    | "use" -> True
    _ -> False
  }
}

// =============================================================================
// Markdown — leveled headings, fences, quotes, inline spice
// =============================================================================

fn paint_markdown(content: String) -> String {
  let lines = string.split(content, "\n")
  paint_md_lines(lines, False, [])
  |> list.reverse
  |> string.join("\n")
}

fn paint_md_lines(
  lines: List(String),
  in_fence: Bool,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> acc
    [line, ..rest] -> {
      let trimmed = string.trim_start(line)
      case in_fence {
        True ->
          case is_fence_line(trimmed) {
            True ->
              paint_md_lines(
                rest,
                False,
                [syn(c_dim, line), ..acc],
              )
            False ->
              paint_md_lines(
                rest,
                True,
                [c_code_bg <> syn(c_code, line) <> reset, ..acc],
              )
          }
        False ->
          case is_fence_line(trimmed) {
            True ->
              paint_md_lines(rest, True, [syn(c_dim, line), ..acc])
            False -> {
              let painted = paint_markdown_line(line, trimmed)
              paint_md_lines(rest, False, [painted, ..acc])
            }
          }
      }
    }
  }
}

fn is_fence_line(trimmed: String) -> Bool {
  string.starts_with(trimmed, "```") || string.starts_with(trimmed, "~~~")
}

fn paint_markdown_line(line: String, trimmed: String) -> String {
  case heading_level(trimmed) {
    Some(1) -> syn(c_h1, line)
    Some(2) -> syn(c_h2, line)
    Some(_) -> syn(c_h3, line)
    None ->
      case is_hr(trimmed) {
        True -> syn(c_dim, line)
        False ->
          case string.starts_with(trimmed, "> ") || trimmed == ">" {
            True -> syn(c_quote, line)
            False -> paint_md_inline(line)
          }
      }
  }
}

fn heading_level(trimmed: String) -> Option(Int) {
  case trimmed {
    "###### " <> _ -> Some(6)
    "##### " <> _ -> Some(5)
    "#### " <> _ -> Some(4)
    "### " <> _ -> Some(3)
    "## " <> _ -> Some(2)
    "# " <> _ -> Some(1)
    _ -> None
  }
}

fn is_hr(trimmed: String) -> Bool {
  case trimmed {
    "---" | "----" | "-----" | "***" | "****" | "___" | "____" -> True
    _ -> {
      let chars = string.to_graphemes(trimmed)
      case list.length(chars) >= 3 {
        False -> False
        True ->
          list.all(chars, fn(c) { c == "-" || c == "*" || c == "_" || c == " " })
          && {
            list.any(chars, fn(c) { c == "-" })
            || list.any(chars, fn(c) { c == "*" })
            || list.any(chars, fn(c) { c == "_" })
          }
      }
    }
  }
}

fn paint_md_inline(line: String) -> String {
  // Color list markers at the start of the line, then inline spans.
  let #(prefix, rest_line) = split_list_marker(line)
  prefix <> paint_md_chars(string.to_graphemes(rest_line), "")
}

fn split_list_marker(line: String) -> #(String, String) {
  let chars = string.to_graphemes(line)
  let #(indent, after_indent) =
    take_while(chars, fn(c) { c == " " || c == "\t" }, "")
  case after_indent {
    [mark, " ", ..rest] ->
      case mark {
        "-" | "*" | "+" -> #(
          indent <> syn(c_bullet, mark <> " "),
          string.concat(rest),
        )
        _ -> #("", line)
      }
    [d, ..] ->
      case is_digit(d) {
        True -> {
          let #(num, after_num) = take_while(after_indent, is_digit, "")
          case after_num {
            [".", " ", ..rest] -> #(
              indent <> syn(c_bullet, num <> ". "),
              string.concat(rest),
            )
            _ -> #("", line)
          }
        }
        False -> #("", line)
      }
    [] -> #("", line)
  }
}

fn paint_md_chars(chars: List(String), acc: String) -> String {
  case chars {
    [] -> acc
    ["`", ..rest] -> {
      let #(code, after, closed) = take_md_code(rest, "")
      let painted = case closed {
        True ->
          c_code_bg <> syn(c_code, "`" <> code <> "`")
        False -> syn(c_code, "`" <> code)
      }
      paint_md_chars(after, acc <> painted)
    }
    ["*", "*", ..rest] -> {
      let #(body, after, closed) = take_until_star_star(rest, "")
      let painted = case closed {
        True -> syn(c_bold, "**" <> body <> "**")
        False -> "**" <> body
      }
      paint_md_chars(after, acc <> painted)
    }
    ["_", "_", ..rest] -> {
      let #(body, after, closed) = take_until_under_under(rest, "")
      let painted = case closed {
        True -> syn(c_bold, "__" <> body <> "__")
        False -> "__" <> body
      }
      paint_md_chars(after, acc <> painted)
    }
    ["*", ..rest] -> {
      let #(body, after, closed) = take_until_char(rest, "*")
      let painted = case closed {
        True -> syn(c_quote, "*" <> body <> "*")
        False -> "*" <> body
      }
      paint_md_chars(after, acc <> painted)
    }
    ["[", ..rest] -> {
      let #(label, after_label, ok_label) = take_until_char(rest, "]")
      case ok_label, after_label {
        True, ["(", ..url_rest] -> {
          let #(url, after_url, ok_url) = take_until_char(url_rest, ")")
          case ok_url {
            True -> {
              let link =
                syn(c_link, "[" <> label <> "]")
                <> syn(c_dim, "(" <> url <> ")")
              paint_md_chars(after_url, acc <> link)
            }
            False -> paint_md_chars(rest, acc <> "[")
          }
        }
        _, _ -> paint_md_chars(rest, acc <> "[")
      }
    }
    [c, ..rest] -> paint_md_chars(rest, acc <> c)
  }
}

fn take_md_code(
  chars: List(String),
  acc: String,
) -> #(String, List(String), Bool) {
  case chars {
    [] -> #(acc, [], False)
    ["`", ..rest] -> #(acc, rest, True)
    [c, ..rest] -> take_md_code(rest, acc <> c)
  }
}

fn take_until_star_star(
  chars: List(String),
  acc: String,
) -> #(String, List(String), Bool) {
  case chars {
    [] -> #(acc, [], False)
    ["*", "*", ..rest] -> #(acc, rest, True)
    [c, ..rest] -> take_until_star_star(rest, acc <> c)
  }
}

fn take_until_under_under(
  chars: List(String),
  acc: String,
) -> #(String, List(String), Bool) {
  case chars {
    [] -> #(acc, [], False)
    ["_", "_", ..rest] -> #(acc, rest, True)
    [c, ..rest] -> take_until_under_under(rest, acc <> c)
  }
}

fn take_until_char(
  chars: List(String),
  stop: String,
) -> #(String, List(String), Bool) {
  take_until_char_loop(chars, stop, "")
}

fn take_until_char_loop(
  chars: List(String),
  stop: String,
  acc: String,
) -> #(String, List(String), Bool) {
  case chars {
    [] -> #(acc, [], False)
    [c, ..rest] if c == stop -> #(acc, rest, True)
    [c, ..rest] -> take_until_char_loop(rest, stop, acc <> c)
  }
}
