//// Nushell-inspired ANSI colors for structured values.

import gleam/list
import gleam/string
import gleshell/sys

const reset = "\u{001b}[0m"

/// Bold green — table headers, record keys, list indices (Nu `header` / `row_index`).
const bold_green = "\u{001b}[1;32m"

/// Green — strings (Nu `string` / `shape_string`).
const green = "\u{001b}[32m"

/// Magenta / purple — ints & floats (Nu `int` / `float`).
const purple = "\u{001b}[35m"

/// Bright cyan — bools (Nu `bool` / `light_cyan`).
const light_cyan = "\u{001b}[96m"

/// Dark gray — nothing / empty (Nu `shape_nothing`).
const dark_gray = "\u{001b}[90m"

/// Cyan — filesizes and similar (Nu `filesize`).
const cyan = "\u{001b}[36m"

/// Blue — directories (common ls color).
const blue = "\u{001b}[34m"

/// Bright blue — directory names in tables.
const bright_blue = "\u{001b}[94m"

/// Bright cyan — symlinks.
const bright_cyan = "\u{001b}[96m"

/// Bold red — errors.
const bold_red = "\u{001b}[1;31m"

/// Dim — box-drawing separators.
const dim = "\u{001b}[2m"

/// Bold — emphasis (prompt name).
const bold = "\u{001b}[1m"

/// Yellow — operators (Nu `shape_operator`).
const yellow = "\u{001b}[33m"

/// Bold cyan — internal commands / lists / records (Nu `shape_internalcall`).
const bold_cyan = "\u{001b}[1;36m"

/// Bold blue — flags (Nu `shape_flag`).
const bold_blue = "\u{001b}[1;34m"

/// Bold purple — ints, floats, pipes (Nu `shape_int` / `shape_pipe`).
const bold_purple = "\u{001b}[1;35m"

/// White on red — garbage / lex errors (Nu `shape_garbage`).
const garbage = "\u{001b}[1;37;41m"

/// Whether ANSI color should be emitted.
///
/// - Off when `NO_COLOR` is set to a non-empty value (https://no-color.org).
/// - On when `FORCE_COLOR` / `CLICOLOR_FORCE` is set to a non-empty, non-`0` value.
/// - Otherwise on only when stdout is a terminal.
pub fn enabled() -> Bool {
  case sys.getenv("NO_COLOR") {
    Ok(v) if v != "" -> False
    _ ->
      case force_color() {
        True -> True
        False -> sys.stdout_isatty()
      }
  }
}

fn force_color() -> Bool {
  case sys.getenv("FORCE_COLOR") {
    Ok(v) -> is_force_value(v)
    Error(Nil) ->
      case sys.getenv("CLICOLOR_FORCE") {
        Ok(v) -> is_force_value(v)
        Error(Nil) -> False
      }
  }
}

fn is_force_value(v: String) -> Bool {
  case v {
    "" | "0" | "false" | "False" | "no" | "No" -> False
    _ -> True
  }
}

/// Wrap `text` in an ANSI code when colors are on.
pub fn paint(on: Bool, code: String, text: String) -> String {
  case on {
    True -> code <> text <> reset
    False -> text
  }
}

pub fn header(on: Bool, text: String) -> String {
  paint(on, bold_green, text)
}

pub fn key(on: Bool, text: String) -> String {
  paint(on, bold_green, text)
}

pub fn index(on: Bool, text: String) -> String {
  paint(on, bold_green, text)
}

pub fn separator(on: Bool, text: String) -> String {
  paint(on, dim, text)
}

pub fn error(on: Bool, text: String) -> String {
  paint(on, bold_red, text)
}

pub fn int_(on: Bool, text: String) -> String {
  paint(on, purple, text)
}

pub fn float_(on: Bool, text: String) -> String {
  paint(on, purple, text)
}

pub fn bool_(on: Bool, text: String) -> String {
  paint(on, light_cyan, text)
}

pub fn string_(on: Bool, text: String) -> String {
  paint(on, green, text)
}

pub fn nothing(on: Bool, text: String) -> String {
  paint(on, dark_gray, text)
}

pub fn filesize(on: Bool, text: String) -> String {
  paint(on, cyan, text)
}

pub fn dir_name(on: Bool, text: String) -> String {
  paint(on, bright_blue, text)
}

pub fn file_name(on: Bool, text: String) -> String {
  // Plain files stay default foreground (matches modern Nu); keep green as a
  // mild highlight so bare strings still read as "string-like".
  paint(on, green, text)
}

pub fn symlink_name(on: Bool, text: String) -> String {
  paint(on, bright_cyan, text)
}

pub fn type_dir(on: Bool, text: String) -> String {
  paint(on, blue, text)
}

pub fn type_file(on: Bool, text: String) -> String {
  paint(on, green, text)
}

pub fn type_symlink(on: Bool, text: String) -> String {
  paint(on, cyan, text)
}

pub fn prompt_name(on: Bool, text: String) -> String {
  paint(on, bold_green, text)
}

/// Directory segment (bold cyan — Starship-inspired).
pub fn prompt_path(on: Bool, text: String) -> String {
  paint(on, bold_cyan, text)
}

/// Git branch segment (bold purple — Starship-inspired).
pub fn prompt_git(on: Bool, text: String) -> String {
  paint(on, bold_purple, text)
}

pub fn prompt_mark(on: Bool, text: String) -> String {
  paint(on, bold, text)
}

/// Success prompt character (bold green).
pub fn prompt_character_ok(on: Bool, text: String) -> String {
  paint(on, "\u{001b}[1;32m", text)
}

/// Error prompt character after non-zero exit (bold red).
pub fn prompt_character_err(on: Bool, text: String) -> String {
  paint(on, bold_red, text)
}

// --- syntax shapes (Nushell `shape_*` defaults) ---

pub fn shape_internalcall(on: Bool, text: String) -> String {
  paint(on, bold_cyan, text)
}

pub fn shape_external(on: Bool, text: String) -> String {
  paint(on, cyan, text)
}

pub fn shape_externalarg(on: Bool, text: String) -> String {
  paint(on, bold_green, text)
}

pub fn shape_string(on: Bool, text: String) -> String {
  paint(on, green, text)
}

pub fn shape_int(on: Bool, text: String) -> String {
  paint(on, bold_purple, text)
}

pub fn shape_float(on: Bool, text: String) -> String {
  paint(on, bold_purple, text)
}

pub fn shape_bool(on: Bool, text: String) -> String {
  paint(on, light_cyan, text)
}

pub fn shape_nothing(on: Bool, text: String) -> String {
  paint(on, light_cyan, text)
}

pub fn shape_flag(on: Bool, text: String) -> String {
  paint(on, bold_blue, text)
}

pub fn shape_pipe(on: Bool, text: String) -> String {
  paint(on, bold_purple, text)
}

pub fn shape_operator(on: Bool, text: String) -> String {
  paint(on, yellow, text)
}

pub fn shape_variable(on: Bool, text: String) -> String {
  paint(on, purple, text)
}

pub fn shape_list(on: Bool, text: String) -> String {
  paint(on, bold_cyan, text)
}

pub fn shape_record(on: Bool, text: String) -> String {
  paint(on, bold_cyan, text)
}

pub fn shape_comment(on: Bool, text: String) -> String {
  paint(on, dark_gray, text)
}

pub fn shape_keyword(on: Bool, text: String) -> String {
  paint(on, bold_cyan, text)
}

pub fn shape_garbage(on: Bool, text: String) -> String {
  paint(on, garbage, text)
}

/// True if `s` already contains ANSI/VT escapes (e.g. external tool output).
/// Such strings should be printed as-is rather than re-colored by the shell.
pub fn contains_ansi(s: String) -> Bool {
  string.contains(s, "\u{001b}")
}

/// Visible length ignoring ANSI CSI sequences (`ESC [ … final`).
pub fn visible_length(s: String) -> Int {
  visible_length_loop(string.to_utf_codepoints(s), 0, AnsiNormal)
}

/// Drop ANSI/VT escape sequences, leaving only visible text.
/// Used by the pager search so color codes do not break matches.
pub fn strip_ansi(s: String) -> String {
  strip_ansi_loop(string.to_utf_codepoints(s), [], AnsiNormal)
}

type AnsiScan {
  AnsiNormal
  /// Saw ESC; next byte chooses the sequence kind.
  AnsiEsc
  /// Inside CSI (`ESC [` … final byte 0x40–0x7E).
  AnsiCsi
}

fn visible_length_loop(
  codes: List(UtfCodepoint),
  acc: Int,
  state: AnsiScan,
) -> Int {
  case codes, state {
    [], _ -> acc
    [c, ..rest], AnsiNormal ->
      case string.utf_codepoint_to_int(c) == 0x1B {
        True -> visible_length_loop(rest, acc, AnsiEsc)
        False -> visible_length_loop(rest, acc + 1, AnsiNormal)
      }
    [c, ..rest], AnsiEsc ->
      case string.utf_codepoint_to_int(c) {
        // CSI introducer `[` — do not treat it as a final byte.
        0x5B -> visible_length_loop(rest, acc, AnsiCsi)
        // Other ESC sequences: skip this single following byte.
        _ -> visible_length_loop(rest, acc, AnsiNormal)
      }
    [c, ..rest], AnsiCsi -> {
      let n = string.utf_codepoint_to_int(c)
      // CSI final byte is in 0x40–0x7E (`@`..`~`).
      case n >= 0x40 && n <= 0x7E {
        True -> visible_length_loop(rest, acc, AnsiNormal)
        False -> visible_length_loop(rest, acc, AnsiCsi)
      }
    }
  }
}

fn strip_ansi_loop(
  codes: List(UtfCodepoint),
  acc: List(UtfCodepoint),
  state: AnsiScan,
) -> String {
  case codes, state {
    [], _ ->
      case string.from_utf_codepoints(list.reverse(acc)) {
        s -> s
      }
    [c, ..rest], AnsiNormal ->
      case string.utf_codepoint_to_int(c) == 0x1B {
        True -> strip_ansi_loop(rest, acc, AnsiEsc)
        False -> strip_ansi_loop(rest, [c, ..acc], AnsiNormal)
      }
    [c, ..rest], AnsiEsc ->
      case string.utf_codepoint_to_int(c) {
        0x5B -> strip_ansi_loop(rest, acc, AnsiCsi)
        _ -> strip_ansi_loop(rest, acc, AnsiNormal)
      }
    [c, ..rest], AnsiCsi -> {
      let n = string.utf_codepoint_to_int(c)
      case n >= 0x40 && n <= 0x7E {
        True -> strip_ansi_loop(rest, acc, AnsiNormal)
        False -> strip_ansi_loop(rest, acc, AnsiCsi)
      }
    }
  }
}
