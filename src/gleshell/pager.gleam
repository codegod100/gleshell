//// Color-aware pager (builtin `less`).
////
//// Passes ANSI through unchanged, sizes pages with `color.visible_length`,
//// and uses the alternate screen while interactive so the REPL is restored
//// on quit. When stdout is not a TTY, or the text fits on one screen, the
//// caller should print the text itself (see `needs_paging`).
////
//// Search: `/` live-finds a fixed string (ANSI-stripped, case-insensitive) as
//// you type; Enter accepts. `n` / `N` jump to the next / previous match
//// (wraps at the ends).

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleshell/color
import gleshell/sys

/// True when stdout is a TTY and wrapping `text` to the terminal width yields
/// more lines than fit on one screen (minus the status row).
pub fn needs_paging(text: String) -> Bool {
  case sys.term_size() {
    Error(Nil) -> False
    Ok(#(rows, cols)) -> {
      let height = page_height(rows)
      let lines = display_lines(text, cols)
      list.length(lines) > height
    }
  }
}

/// Interactive page session. Call only when `needs_paging` is True.
/// Leaves the alternate screen on exit; does not print the text afterwards.
pub fn run(text: String) -> Nil {
  case sys.term_size() {
    Error(Nil) -> Nil
    Ok(#(rows, cols)) -> {
      let height = page_height(rows)
      let lines = display_lines(text, cols)
      let total = list.length(lines)
      sys.with_key_mode(fn() {
        enter_alt_screen()
        page_loop(lines, total, 0, height, cols, None, None)
        leave_alt_screen()
      })
    }
  }
}

fn page_height(rows: Int) -> Int {
  int.max(1, rows - 1)
}

/// Split on newlines, then soft-wrap each logical line to `cols` using
/// ANSI-aware visible width so color codes do not throw off wrapping.
pub fn display_lines(text: String, cols: Int) -> List(String) {
  let cols = int.max(1, cols)
  text
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
  |> list.flat_map(fn(line) { wrap_line(line, cols) })
}

/// True if the line matches `pattern` as a fixed substring of its ANSI-stripped
/// text (case-insensitive). Empty patterns never match.
pub fn line_matches(line: String, pattern: String) -> Bool {
  case pattern {
    "" -> False
    p ->
      string.contains(
        string.lowercase(color.strip_ansi(line)),
        string.lowercase(p),
      )
  }
}

/// Wrap each non-overlapping fixed-string match in black-on-bright-yellow
/// (`CSI 30;103m` / `CSI 39;49m`). Matches are located on ANSI-stripped text
/// so color codes do not break search; matching is case-insensitive. Existing
/// escapes are left in place. While inside a match, SGR sequences are followed
/// by a re-open of the accent so a content reset does not cancel the highlight.
/// Empty pattern or no hits returns `line` unchanged.
pub fn highlight_matches(line: String, pattern: String) -> String {
  case pattern {
    "" -> line
    p -> {
      let plain = color.strip_ansi(line)
      // Lowercase for matching only; ranges still map to visible codepoint
      // positions on the original line (ASCII case fold keeps lengths equal).
      let plain_ci = string.lowercase(plain)
      let p_ci = string.lowercase(p)
      case string.contains(plain_ci, p_ci) {
        False -> line
        True ->
          case match_ranges(plain_ci, p_ci) {
            [] -> line
            ranges -> apply_match_highlight(line, ranges)
          }
      }
    }
  }
}

/// Black on bright yellow — readable accent over any content colors.
/// Off restores default fg/bg (`39;49`).
const match_on = "\u{001b}[30;103m"

const match_off = "\u{001b}[39;49m"

/// Non-overlapping match ranges as visible-codepoint `#(start, end)` (end exclusive).
fn match_ranges(plain: String, pattern: String) -> List(#(Int, Int)) {
  let plain_cps = string.to_utf_codepoints(plain)
  let pat_cps = string.to_utf_codepoints(pattern)
  let plen = list.length(pat_cps)
  case plen {
    0 -> []
    _ -> match_ranges_loop(plain_cps, pat_cps, plen, 0, [])
  }
}

fn match_ranges_loop(
  plain: List(UtfCodepoint),
  pat: List(UtfCodepoint),
  plen: Int,
  index: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case plain {
    [] -> list.reverse(acc)
    _ ->
      case list_starts_with_cp(plain, pat) {
        True ->
          match_ranges_loop(
            list.drop(plain, plen),
            pat,
            plen,
            index + plen,
            [#(index, index + plen), ..acc],
          )
        False ->
          case plain {
            [_, ..rest] ->
              match_ranges_loop(rest, pat, plen, index + 1, acc)
            [] -> list.reverse(acc)
          }
      }
  }
}

fn list_starts_with_cp(
  hay: List(UtfCodepoint),
  needle: List(UtfCodepoint),
) -> Bool {
  case needle {
    [] -> True
    [n, ..ns] ->
      case hay {
        [h, ..hs] ->
          case string.utf_codepoint_to_int(h) == string.utf_codepoint_to_int(n) {
            True -> list_starts_with_cp(hs, ns)
            False -> False
          }
        [] -> False
      }
  }
}

fn apply_match_highlight(line: String, ranges: List(#(Int, Int))) -> String {
  apply_hl_loop(string.to_utf_codepoints(line), ranges, 0, False, "")
}

fn apply_hl_loop(
  codes: List(UtfCodepoint),
  ranges: List(#(Int, Int)),
  vis: Int,
  in_match: Bool,
  acc: String,
) -> String {
  case codes {
    [] ->
      case in_match {
        True -> acc <> match_off
        False -> acc
      }
    [c, ..rest] -> {
      let n = string.utf_codepoint_to_int(c)
      case n == 0x1B {
        True -> {
          let #(seq, after) = take_ansi([c, ..rest])
          let seq_s = codepoints_to_string(seq)
          let acc2 = case in_match && is_sgr_sequence(seq) {
            // Content reset/color change would drop the accent bg; put it back.
            True -> acc <> seq_s <> match_on
            False -> acc <> seq_s
          }
          apply_hl_loop(after, ranges, vis, in_match, acc2)
        }
        False -> {
          let next_in = visible_in_match(vis, ranges)
          let acc2 = case in_match, next_in {
            True, False -> acc <> match_off
            False, True -> acc <> match_on
            _, _ -> acc
          }
          apply_hl_loop(
            rest,
            ranges,
            vis + 1,
            next_in,
            acc2 <> codepoints_to_string([c]),
          )
        }
      }
    }
  }
}

fn visible_in_match(vis: Int, ranges: List(#(Int, Int))) -> Bool {
  list.any(ranges, fn(range) {
    let #(start, end) = range
    vis >= start && vis < end
  })
}

fn is_sgr_sequence(seq: List(UtfCodepoint)) -> Bool {
  case list.reverse(seq) {
    [last, ..] -> string.utf_codepoint_to_int(last) == 0x6D
    [] -> False
  }
}

/// First match strictly after `after` (use `-1` to search from the start).
/// Wraps once from the top when nothing is found past `after`.
/// Returns `#(index, wrapped)`.
pub fn find_after(
  lines: List(String),
  pattern: String,
  after: Int,
) -> Result(#(Int, Bool), Nil) {
  case pattern {
    "" -> Error(Nil)
    p -> {
      let total = list.length(lines)
      case total {
        0 -> Error(Nil)
        _ -> {
          let start = after + 1
          case first_match_in(lines, p, start, total) {
            Ok(i) -> Ok(#(i, False))
            Error(Nil) ->
              case first_match_in(lines, p, 0, int.min(total, after + 1)) {
                Ok(i) -> Ok(#(i, True))
                Error(Nil) -> Error(Nil)
              }
          }
        }
      }
    }
  }
}

/// First match strictly before `before` (use `total` to search from the end).
/// Wraps once from the bottom when nothing is found before `before`.
/// Returns `#(index, wrapped)`.
pub fn find_before(
  lines: List(String),
  pattern: String,
  before: Int,
) -> Result(#(Int, Bool), Nil) {
  case pattern {
    "" -> Error(Nil)
    p -> {
      let total = list.length(lines)
      case total {
        0 -> Error(Nil)
        _ -> {
          let until = int.clamp(before, 0, total)
          case last_match_in(lines, p, 0, until) {
            Ok(i) -> Ok(#(i, False))
            Error(Nil) ->
              case last_match_in(lines, p, int.max(0, before), total) {
                Ok(i) -> Ok(#(i, True))
                Error(Nil) -> Error(Nil)
              }
          }
        }
      }
    }
  }
}

fn first_match_in(
  lines: List(String),
  pattern: String,
  from: Int,
  until: Int,
) -> Result(Int, Nil) {
  case from >= until {
    True -> Error(Nil)
    False ->
      case list_at(lines, from) {
        Ok(line) ->
          case line_matches(line, pattern) {
            True -> Ok(from)
            False -> first_match_in(lines, pattern, from + 1, until)
          }
        Error(Nil) -> Error(Nil)
      }
  }
}

fn last_match_in(
  lines: List(String),
  pattern: String,
  from: Int,
  until: Int,
) -> Result(Int, Nil) {
  case until <= from {
    True -> Error(Nil)
    False -> {
      let i = until - 1
      case list_at(lines, i) {
        Ok(line) ->
          case line_matches(line, pattern) {
            True -> Ok(i)
            False -> last_match_in(lines, pattern, from, i)
          }
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn list_at(items: List(String), index: Int) -> Result(String, Nil) {
  case index < 0 {
    True -> Error(Nil)
    False ->
      case list.drop(items, index) {
        [x, ..] -> Ok(x)
        [] -> Error(Nil)
      }
  }
}

fn page_loop(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
  pattern: Option(String),
  message: Option(String),
) -> Nil {
  let max_off = int.max(0, total - height)
  let offset = int.clamp(offset, 0, max_off)
  redraw(lines, total, offset, height, cols, pattern, message)
  case sys.read_key_name() {
    Error(_) -> Nil
    Ok("eof") -> Nil
    Ok("q") | Ok("Q") | Ok("ctrl_c") | Ok("ctrl_d") -> Nil
    Ok("down") | Ok("j") | Ok("enter") ->
      page_loop(lines, total, offset + 1, height, cols, pattern, None)
    Ok("up") | Ok("k") ->
      page_loop(lines, total, offset - 1, height, cols, pattern, None)
    Ok("space") | Ok("f") | Ok("page_down") | Ok("ctrl_f") ->
      page_loop(lines, total, offset + height, height, cols, pattern, None)
    Ok("b") | Ok("page_up") | Ok("ctrl_b") ->
      page_loop(lines, total, offset - height, height, cols, pattern, None)
    Ok("g") | Ok("home") ->
      page_loop(lines, total, 0, height, cols, pattern, None)
    Ok("G") | Ok("end") ->
      page_loop(lines, total, max_off, height, cols, pattern, None)
    Ok("ctrl_l") ->
      page_loop(lines, total, offset, height, cols, pattern, None)
    Ok("/") ->
      handle_search(lines, total, offset, height, cols, pattern, Forward)
    Ok("n") ->
      handle_repeat(lines, total, offset, height, cols, pattern, Forward)
    Ok("N") ->
      handle_repeat(lines, total, offset, height, cols, pattern, Backward)
    Ok("h") | Ok("?") -> {
      show_help(height, cols)
      page_loop(lines, total, offset, height, cols, pattern, None)
    }
    Ok(_) -> page_loop(lines, total, offset, height, cols, pattern, None)
  }
}

type SearchDir {
  Forward
  Backward
}

fn handle_search(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
  pattern: Option(String),
  dir: SearchDir,
) -> Nil {
  // Live search: matches highlight and the view jumps as the query grows.
  // Cancel restores `offset` + prior pattern; Enter accepts the live position.
  case live_search_loop(lines, total, offset, height, cols, "") {
    Error(Nil) ->
      page_loop(lines, total, offset, height, cols, pattern, None)
    Ok(#(entered, live_offset)) ->
      case entered {
        "" ->
          // Empty Enter reuses the previous pattern and jumps from start.
          case pattern {
            None ->
              page_loop(
                lines,
                total,
                offset,
                height,
                cols,
                None,
                Some("No previous pattern"),
              )
            Some(p) ->
              apply_search(lines, total, offset, height, cols, p, dir)
          }
        p ->
          // Already on the live match; keep that offset (do not re-search).
          page_loop(lines, total, live_offset, height, cols, Some(p), None)
      }
  }
}

fn handle_repeat(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
  pattern: Option(String),
  dir: SearchDir,
) -> Nil {
  case pattern {
    None ->
      page_loop(
        lines,
        total,
        offset,
        height,
        cols,
        None,
        Some("No previous pattern"),
      )
    Some(p) -> apply_search(lines, total, offset, height, cols, p, dir)
  }
}

fn apply_search(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
  pattern: String,
  dir: SearchDir,
) -> Nil {
  let result = case dir {
    Forward -> find_after(lines, pattern, offset)
    Backward -> find_before(lines, pattern, offset)
  }
  case result {
    Error(Nil) ->
      page_loop(
        lines,
        total,
        offset,
        height,
        cols,
        Some(pattern),
        Some("Pattern not found"),
      )
    Ok(#(i, wrapped)) -> {
      let msg = case wrapped {
        True -> Some("Search wrapped")
        False -> None
      }
      page_loop(lines, total, i, height, cols, Some(pattern), msg)
    }
  }
}

/// Live incremental search. Returns `#(query, view_offset)` on Enter, or
/// `Error` on cancel. Empty query on Enter is left for the caller (reuse prior).
///
/// While typing, the page jumps to the first match at or after `start_offset`
/// and highlights hits; no match keeps the start view with the query on the
/// status line.
fn live_search_loop(
  lines: List(String),
  total: Int,
  start_offset: Int,
  height: Int,
  cols: Int,
  query: String,
) -> Result(#(String, Int), Nil) {
  let #(view_offset, paint, status_msg) =
    live_search_preview(lines, query, start_offset)
  redraw(lines, total, view_offset, height, cols, paint, None)
  draw_search_status(cols, query, status_msg)
  case sys.read_key_name() {
    Error(_) -> Error(Nil)
    Ok("eof") | Ok("ctrl_c") | Ok("ctrl_g") | Ok("ctrl_d") -> Error(Nil)
    Ok("enter") -> Ok(#(query, view_offset))
    Ok("backspace") ->
      live_search_loop(
        lines,
        total,
        start_offset,
        height,
        cols,
        drop_last_grapheme(query),
      )
    Ok("ctrl_u") ->
      live_search_loop(lines, total, start_offset, height, cols, "")
    Ok("space") ->
      live_search_loop(lines, total, start_offset, height, cols, query <> " ")
    Ok(key) ->
      case is_search_char(key) {
        True ->
          live_search_loop(
            lines,
            total,
            start_offset,
            height,
            cols,
            query <> key,
          )
        False ->
          live_search_loop(lines, total, start_offset, height, cols, query)
      }
  }
}

/// Pure preview for live `/` search: view offset, highlight pattern, and an
/// optional status suffix (e.g. "not found"). Empty query restores
/// `start_offset` with no highlight.
pub fn live_search_preview(
  lines: List(String),
  query: String,
  start_offset: Int,
) -> #(Int, Option(String), Option(String)) {
  case query {
    "" -> #(start_offset, None, None)
    p ->
      // Inclusive of the line at start_offset (find_after is strictly after).
      case find_after(lines, p, start_offset - 1) {
        Ok(#(i, _)) -> #(i, Some(p), None)
        Error(Nil) -> #(start_offset, Some(p), Some("not found"))
      }
  }
}

fn is_search_char(key: String) -> Bool {
  case string.starts_with(key, "ctrl_") {
    True -> False
    False ->
      // key_to_name returns one printable grapheme for {char, C}; named keys
      // ("up", "enter", …) are multi-grapheme or handled elsewhere.
      case string.to_graphemes(key) {
        [_] -> True
        _ -> False
      }
  }
}

fn drop_last_grapheme(s: String) -> String {
  case list.reverse(string.to_graphemes(s)) {
    [] -> ""
    [_, ..rest] -> string.concat(list.reverse(rest))
  }
}

fn draw_search_status(
  cols: Int,
  query: String,
  message: Option(String),
) -> Nil {
  // Move to last row (status line) without clearing the page content.
  case sys.term_size() {
    Error(Nil) -> Nil
    Ok(#(rows, _)) -> {
      let row = int.max(1, rows)
      let plain = case message {
        Some(msg) -> "/" <> query <> "  (" <> msg <> ") "
        None -> "/" <> query
      }
      let body = case color.enabled() {
        True -> "\u{001b}[7m" <> pad_status(plain, cols) <> "\u{001b}[0m"
        False -> pad_status(plain, cols)
      }
      sys.write(
        "\u{001b}["
        <> int.to_string(row)
        <> ";1H\u{001b}[0m"
        <> body
        <> "\u{001b}[K",
      )
    }
  }
}

fn redraw(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
  pattern: Option(String),
  message: Option(String),
) -> Nil {
  // Home + clear + SGR reset inside the alternate buffer.
  // Do not reset SGR after every row: soft-wrapped chunks only open CSI on the
  // first physical line, so color must continue until the content resets it.
  sys.write("\u{001b}[H\u{001b}[2J\u{001b}[0m")
  let view = list_slice(lines, offset, height)
  let padded = pad_to(view, height)
  list.each(padded, fn(line) {
    let painted = case pattern {
      Some(p) -> highlight_matches(line, p)
      None -> line
    }
    sys.write(painted <> "\u{001b}[K\r\n")
  })
  // Ensure the status bar is not tinted by leftover content SGR.
  sys.write("\u{001b}[0m" <> status_line(offset, height, total, cols, message))
}

fn status_line(
  offset: Int,
  height: Int,
  total: Int,
  cols: Int,
  message: Option(String),
) -> String {
  let plain = case message {
    Some(msg) -> " " <> msg <> " "
    None -> {
      let at_end = offset + height >= total
      let label = case total {
        0 -> " (empty) "
        _ if at_end -> " (END) "
        _ -> {
          let bottom = int.min(total, offset + height)
          let pct = case total {
            0 -> 100
            n -> bottom * 100 / n
          }
          " "
          <> int.to_string(offset + 1)
          <> "-"
          <> int.to_string(bottom)
          <> "/"
          <> int.to_string(total)
          <> " ("
          <> int.to_string(pct)
          <> "%) "
        }
      }
      let help =
        " q:quit  /:search  n/N  j/k:line  space/b:page  g/G  h:help "
      case color.visible_length(label <> help) > cols {
        True -> label
        False -> label <> help
      }
    }
  }
  let on = color.enabled()
  let body = case on {
    True -> "\u{001b}[7m" <> pad_status(plain, cols) <> "\u{001b}[0m"
    False -> pad_status(plain, cols)
  }
  // Stay on the status row (no trailing newline).
  body <> "\u{001b}[K"
}

fn pad_status(text: String, cols: Int) -> String {
  let vis = color.visible_length(text)
  case vis >= cols {
    True -> text
    False -> text <> string.repeat(" ", cols - vis)
  }
}

fn show_help(height: Int, cols: Int) -> Nil {
  let help_text =
    string.join(
      [
        "gleshell less — color-aware pager",
        "",
        "  j / ↓ / Enter     one line down",
        "  k / ↑             one line up",
        "  space / f / PgDn  one page down",
        "  b / PgUp          one page up",
        "  g / Home          top",
        "  G / End           bottom",
        "  /pattern          live search forward (fixed string, ignore case)",
        "  n / N             next / previous match",
        "  Ctrl+L            redraw",
        "  h / ?             this help",
        "  q / Q / Ctrl+C    quit",
        "",
        "ANSI colors from tools and tables are kept (like less -R).",
        "Search finds as you type (case-insensitive; ANSI ignored); hits are black on yellow.",
        "",
        "Press any key to return…",
      ],
      "\n",
    )
  let lines = display_lines(help_text, cols)
  redraw(lines, list.length(lines), 0, height, cols, None, None)
  let _ = sys.read_key_name()
  Nil
}

fn enter_alt_screen() -> Nil {
  // Save cursor + enter alternate screen buffer (xterm/most terminals).
  sys.write("\u{001b}[?1049h\u{001b}[H")
}

fn leave_alt_screen() -> Nil {
  sys.write("\u{001b}[?1049l")
}

fn list_slice(items: List(String), offset: Int, n: Int) -> List(String) {
  items
  |> list.drop(offset)
  |> list.take(n)
}

fn pad_to(lines: List(String), height: Int) -> List(String) {
  let missing = height - list.length(lines)
  case missing > 0 {
    True -> list.append(lines, list.repeat("", missing))
    False -> lines
  }
}

/// Soft-wrap one logical line to at most `cols` visible columns.
/// Escape sequences never count toward width and are never split mid-sequence.
pub fn wrap_line(line: String, cols: Int) -> List(String) {
  let cols = int.max(1, cols)
  case color.visible_length(line) <= cols {
    True -> [line]
    False -> wrap_loop(string.to_utf_codepoints(line), cols, 0, "", [])
  }
}

fn wrap_loop(
  codes: List(UtfCodepoint),
  cols: Int,
  vis: Int,
  acc_text: String,
  out: List(String),
) -> List(String) {
  case codes {
    [] ->
      case acc_text {
        "" if out != [] -> list.reverse(out)
        "" -> [""]
        t -> list.reverse([t, ..out])
      }
    [c, ..rest] -> {
      let n = string.utf_codepoint_to_int(c)
      case n == 0x1B {
        True -> {
          // Pull the whole CSI / ESC sequence into the current chunk.
          let #(seq, after) = take_ansi([c, ..rest])
          wrap_loop(
            after,
            cols,
            vis,
            acc_text <> codepoints_to_string(seq),
            out,
          )
        }
        False ->
          case vis >= cols {
            True ->
              // Start a new physical line with this visible character.
              wrap_loop(codes, cols, 0, "", [acc_text, ..out])
            False ->
              wrap_loop(
                rest,
                cols,
                vis + 1,
                acc_text <> codepoints_to_string([c]),
                out,
              )
          }
      }
    }
  }
}

fn take_ansi(
  codes: List(UtfCodepoint),
) -> #(List(UtfCodepoint), List(UtfCodepoint)) {
  case codes {
    [] -> #([], [])
    [esc, ..rest] ->
      case string.utf_codepoint_to_int(esc) == 0x1B {
        False -> #([], codes)
        True ->
          case rest {
            [bracket, ..params] ->
              case string.utf_codepoint_to_int(bracket) == 0x5B {
                // CSI: ESC [ … final(0x40–0x7E)
                True -> take_csi([esc, bracket], params)
                // Non-CSI ESC: include ESC + one following byte.
                False -> #([esc, bracket], params)
              }
            [] -> #([esc], [])
          }
      }
  }
}

fn take_csi(
  acc: List(UtfCodepoint),
  rest: List(UtfCodepoint),
) -> #(List(UtfCodepoint), List(UtfCodepoint)) {
  case rest {
    [] -> #(acc, [])
    [c, ..more] -> {
      let n = string.utf_codepoint_to_int(c)
      let acc2 = list.append(acc, [c])
      case n >= 0x40 && n <= 0x7E {
        True -> #(acc2, more)
        False -> take_csi(acc2, more)
      }
    }
  }
}

fn codepoints_to_string(codes: List(UtfCodepoint)) -> String {
  case string.from_utf_codepoints(codes) {
    s -> s
  }
}
