//// Color-aware pager (builtin `less`).
////
//// Passes ANSI through unchanged, sizes pages with `color.visible_length`,
//// and uses the alternate screen while interactive so the REPL is restored
//// on quit. When stdout is not a TTY, or the text fits on one screen, the
//// caller should print the text itself (see `needs_paging`).

import gleam/int
import gleam/list
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
        page_loop(lines, total, 0, height, cols)
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

fn page_loop(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
) -> Nil {
  let max_off = int.max(0, total - height)
  let offset = int.clamp(offset, 0, max_off)
  redraw(lines, total, offset, height, cols)
  case sys.read_key_name() {
    Error(_) -> Nil
    Ok("eof") -> Nil
    Ok("q") | Ok("Q") | Ok("ctrl_c") | Ok("ctrl_d") -> Nil
    Ok("down") | Ok("j") | Ok("enter") ->
      page_loop(lines, total, offset + 1, height, cols)
    Ok("up") | Ok("k") -> page_loop(lines, total, offset - 1, height, cols)
    Ok("space") | Ok("f") | Ok("page_down") | Ok("ctrl_f") ->
      page_loop(lines, total, offset + height, height, cols)
    Ok("b") | Ok("page_up") | Ok("ctrl_b") ->
      page_loop(lines, total, offset - height, height, cols)
    Ok("g") | Ok("home") -> page_loop(lines, total, 0, height, cols)
    Ok("G") | Ok("end") -> page_loop(lines, total, max_off, height, cols)
    Ok("ctrl_l") -> page_loop(lines, total, offset, height, cols)
    Ok("h") | Ok("?") -> {
      show_help(height, cols)
      page_loop(lines, total, offset, height, cols)
    }
    Ok(_) -> page_loop(lines, total, offset, height, cols)
  }
}

fn redraw(
  lines: List(String),
  total: Int,
  offset: Int,
  height: Int,
  cols: Int,
) -> Nil {
  // Home + clear + SGR reset inside the alternate buffer.
  // Do not reset SGR after every row: soft-wrapped chunks only open CSI on the
  // first physical line, so color must continue until the content resets it.
  sys.write("\u{001b}[H\u{001b}[2J\u{001b}[0m")
  let view = list_slice(lines, offset, height)
  let padded = pad_to(view, height)
  list.each(padded, fn(line) {
    sys.write(line <> "\u{001b}[K\r\n")
  })
  // Ensure the status bar is not tinted by leftover content SGR.
  sys.write("\u{001b}[0m" <> status_line(offset, height, total, cols))
}

fn status_line(offset: Int, height: Int, total: Int, cols: Int) -> String {
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
  let help = " q:quit  j/k:line  space/b:page  g/G:top/end  h:help "
  let plain = label <> help
  let plain = case color.visible_length(plain) > cols {
    True -> label
    False -> plain
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
        "  Ctrl+L            redraw",
        "  h / ?             this help",
        "  q / Q / Ctrl+C    quit",
        "",
        "ANSI colors from tools and tables are kept (like less -R).",
        "",
        "Press any key to return…",
      ],
      "\n",
    )
  let lines = display_lines(help_text, cols)
  redraw(lines, list.length(lines), 0, height, cols)
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
