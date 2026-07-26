//// Pretty-print structured values (Nushell-style tables + colors).

import gleam/int
import gleam/list
import gleam/string
import gleshell/color
import gleshell/sys
import gleshell/value.{
  type Value, Bool, Fail, Float, Int, List, Nothing, Record, String, Table,
}

pub fn render(value: Value) -> String {
  render_with(color.enabled(), value)
}

/// Render with an explicit color switch (useful for tests / `NO_COLOR`).
pub fn render_with(on: Bool, value: Value) -> String {
  case value {
    Nothing -> ""
    Fail(msg) -> color.error(on, "Error: " <> msg)
    // Opaque text from external tools (jj, git, …): keep their ANSI as-is.
    // Multi-line output is almost always command text — do not paint it green.
    String(s) -> render_string(on, s)
    Table(cols, rows) -> render_table_with(on, cols, rows)
    List(items) -> {
      case list.all(items, is_record) {
        True ->
          case value.table_from_records(items) {
            Table(c, r) -> render_table_with(on, c, r)
            other -> render_value_block(on, other)
          }
        False -> render_list(on, items)
      }
    }
    Record(fields) -> render_record(on, fields)
    other -> color_cell(on, "", other, value.cell_string(other))
  }
}

/// External programs often embed their own colors. Pass those through.
/// Short plain strings still get Nu-style string coloring.
fn render_string(on: Bool, s: String) -> String {
  case color.contains_ansi(s) || string.contains(s, "\n") {
    True -> s
    False -> color.string_(on, s)
  }
}

fn is_record(v: Value) -> Bool {
  case v {
    Record(_) -> True
    _ -> False
  }
}

fn render_value_block(on: Bool, v: Value) -> String {
  color_cell(on, "", v, value.as_string(v))
}

fn render_list(on: Bool, items: List(Value)) -> String {
  case items {
    [] -> color.separator(on, "[]")
    _ -> {
      let body =
        items
        |> list.index_map(fn(item, i) {
          let idx = color.index(on, int.to_string(i))
          let bar = color.separator(on, "│")
          let cell = color_cell(on, "", item, value.cell_string(item))
          "  " <> idx <> " " <> bar <> " " <> cell
        })
        |> string.join("\n")
      let top = color.separator(on, "╭──── list ───")
      let bot = color.separator(on, "╰────────────")
      top <> "\n" <> body <> "\n" <> bot
    }
  }
}

fn render_record(on: Bool, fields: List(#(String, Value))) -> String {
  case fields {
    [] -> color.separator(on, "{}")
    _ -> {
      let key_w =
        fields
        |> list.map(fn(p) {
          let #(k, _) = p
          string.length(k)
        })
        |> list.fold(0, int.max)

      let type_hint = case list.key_find(fields, "type") {
        Ok(String(t)) -> t
        _ -> ""
      }
      let lines =
        list.map(fields, fn(pair) {
          let #(k, v) = pair
          let key = color.key(on, pad_right(k, key_w))
          let bar = color.separator(on, "│")
          let plain = cell_plain(k, v)
          let cell = color_cell_for_column(on, k, v, plain, type_hint)
          "  " <> key <> " " <> bar <> " " <> cell
        })
      let top = color.separator(on, "╭──── record ───")
      let bot = color.separator(on, "╰──────────────")
      top <> "\n" <> string.join(lines, "\n") <> "\n" <> bot
    }
  }
}

pub fn render_table(columns: List(String), rows: List(List(Value))) -> String {
  render_table_with(color.enabled(), columns, rows)
}

fn render_table_with(
  on: Bool,
  columns: List(String),
  rows: List(List(Value)),
) -> String {
  case columns {
    [] -> color.nothing(on, "(empty table)")
    _ -> {
      // Column-aware plain text (e.g. size → KB/MB) for widths and coloring.
      let plain_cells: List(List(String)) =
        list.map(rows, fn(row) {
          list.index_map(columns, fn(col, i) {
            case list_at(row, i) {
              Ok(v) -> cell_plain(col, v)
              Error(Nil) -> ""
            }
          })
        })

      // Widths use visible length so cells with ANSI (from external tools)
      // do not inflate the table.
      let widths =
        list.index_map(columns, fn(col, i) {
          let header_w = color.visible_length(col)
          let data_w =
            plain_cells
            |> list.map(fn(row) {
              case list_at(row, i) {
                Ok(c) -> color.visible_length(c)
                Error(Nil) -> 0
              }
            })
            |> list.fold(header_w, int.max)
          int.max(data_w, 1)
        })

      let top = color.separator(on, box_line(widths, "╭", "┬", "╮", "─"))
      let sep = color.separator(on, box_line(widths, "├", "┼", "┤", "─"))
      let bot = color.separator(on, box_line(widths, "╰", "┴", "╯", "─"))
      let header =
        colored_header_line(on, columns, widths)
      let body =
        list.map2(rows, plain_cells, fn(row, plains) {
          colored_data_line(on, columns, row, plains, widths)
        })
        |> string.join("\n")

      case body {
        "" -> top <> "\n" <> header <> "\n" <> bot
        _ -> top <> "\n" <> header <> "\n" <> sep <> "\n" <> body <> "\n" <> bot
      }
    }
  }
}

fn colored_header_line(
  on: Bool,
  columns: List(String),
  widths: List(Int),
) -> String {
  let padded =
    list.map2(columns, widths, fn(col, w) {
      " " <> color.header(on, pad_right(col, w)) <> " "
    })
  let bar = color.separator(on, "│")
  bar <> string.join(padded, bar) <> bar
}

fn colored_data_line(
  on: Bool,
  columns: List(String),
  row: List(Value),
  plains: List(String),
  widths: List(Int),
) -> String {
  let type_hint = row_type_hint(columns, plains)
  let cells =
    list.index_map(columns, fn(col, i) {
      let w = case list_at(widths, i) {
        Ok(n) -> n
        Error(Nil) -> 1
      }
      let plain = case list_at(plains, i) {
        Ok(p) -> p
        Error(Nil) -> ""
      }
      let val = case list_at(row, i) {
        Ok(v) -> v
        Error(Nil) -> Nothing
      }
      // Color the unpadded text, then add trailing spaces outside ANSI codes
      // so type/name matchers see exact values ("dir", not "dir ").
      let painted = color_cell_for_column(on, col, val, plain, type_hint)
      let pad =
        string.repeat(" ", int.max(0, w - color.visible_length(plain)))
      " " <> painted <> pad <> " "
    })
  // Extra empty columns if widths longer than columns (shouldn't happen).
  let cells = case list.length(cells) < list.length(widths) {
    True -> {
      let extra =
        list.drop(widths, list.length(cells))
        |> list.map(fn(w) { " " <> pad_right("", w) <> " " })
      list.append(cells, extra)
    }
    False -> cells
  }
  let bar = color.separator(on, "│")
  bar <> string.join(cells, bar) <> bar
}

/// Look up the `type` column value for ls-style name coloring.
fn row_type_hint(columns: List(String), plains: List(String)) -> String {
  case list_index_of(columns, "type") {
    Ok(i) ->
      case list_at(plains, i) {
        Ok(t) -> t
        Error(Nil) -> ""
      }
    Error(Nil) -> ""
  }
}

fn list_index_of(items: List(String), target: String) -> Result(Int, Nil) {
  list_index_of_loop(items, target, 0)
}

fn list_index_of_loop(
  items: List(String),
  target: String,
  i: Int,
) -> Result(Int, Nil) {
  case items {
    [] -> Error(Nil)
    [x, ..rest] ->
      case x == target {
        True -> Ok(i)
        False -> list_index_of_loop(rest, target, i + 1)
      }
  }
}

/// Plain cell text before coloring. Keeps pipeline data as raw ints; only
/// display converts `size` byte counts to KB/MB/… and `modified` epoch
/// seconds to a local datetime.
fn cell_plain(col: String, value: Value) -> String {
  case col, value {
    "size", Int(n) -> format_filesize(n)
    "modified", Int(n) -> format_datetime(n)
    _, _ -> value.cell_string(value)
  }
}

/// Format Unix epoch seconds as local `Jul 3 2026 9:39:40 PM` (12-hour).
pub fn format_datetime(unix_seconds: Int) -> String {
  sys.format_unix_local(unix_seconds)
}

/// Format a byte count for display: B below 1 KiB, then KB / MB / GB / TB
/// (1024-based). One decimal place when the fractional part is non-zero.
pub fn format_filesize(bytes: Int) -> String {
  let n = case bytes < 0 {
    True -> 0
    False -> bytes
  }
  case n < 1024 {
    True -> int.to_string(n) <> " B"
    False ->
      case n < 1_048_576 {
        True -> scale_unit(n, 1024, " KB")
        False ->
          case n < 1_073_741_824 {
            True -> scale_unit(n, 1_048_576, " MB")
            False ->
              case n < 1_099_511_627_776 {
                True -> scale_unit(n, 1_073_741_824, " GB")
                False -> scale_unit(n, 1_099_511_627_776, " TB")
              }
          }
      }
  }
}

fn scale_unit(n: Int, unit: Int, suffix: String) -> String {
  // tenths with half-up rounding: (n * 10 + unit/2) / unit
  let tenths = { n * 10 + unit / 2 } / unit
  let whole = tenths / 10
  let frac = tenths % 10
  case frac {
    0 -> int.to_string(whole) <> suffix
    _ -> int.to_string(whole) <> "." <> int.to_string(frac) <> suffix
  }
}

/// Color a table/list/record cell by value type and optional column name.
fn color_cell(on: Bool, col: String, value: Value, plain: String) -> String {
  color_cell_for_column(on, col, value, plain, "")
}

fn color_cell_for_column(
  on: Bool,
  col: String,
  value: Value,
  plain: String,
  type_hint: String,
) -> String {
  case col {
    "name" -> color_path_name(on, plain, type_hint)
    "type" -> color_entry_type(on, plain)
    "size" -> color.filesize(on, plain)
    "modified" -> color.datetime(on, plain)
    _ -> color_by_value(on, value, plain)
  }
}

fn color_path_name(on: Bool, plain: String, type_hint: String) -> String {
  case type_hint {
    "dir" | "directory" -> color.dir_name(on, plain)
    "symlink" | "link" -> color.symlink_name(on, plain)
    "file" -> color.file_name(on, plain)
    _ -> color.string_(on, plain)
  }
}

fn color_entry_type(on: Bool, plain: String) -> String {
  case plain {
    "dir" | "directory" -> color.type_dir(on, plain)
    "symlink" | "link" -> color.type_symlink(on, plain)
    "file" -> color.type_file(on, plain)
    _ -> color.string_(on, plain)
  }
}

fn color_by_value(on: Bool, value: Value, plain: String) -> String {
  case value {
    Nothing -> color.nothing(on, plain)
    Bool(_) -> color.bool_(on, plain)
    Int(_) -> color.int_(on, plain)
    Float(_) -> color.float_(on, plain)
    // Preserve pre-colored external text inside tables/lists/records.
    String(_) ->
      case color.contains_ansi(plain) {
        True -> plain
        False -> color.string_(on, plain)
      }
    Fail(_) -> color.error(on, plain)
    List(_) | Record(_) | Table(_, _) -> color.string_(on, plain)
  }
}

fn box_line(
  widths: List(Int),
  left: String,
  mid: String,
  right: String,
  fill: String,
) -> String {
  let segments = list.map(widths, fn(w) { string.repeat(fill, w + 2) })
  left <> string.join(segments, mid) <> right
}

fn pad_right(s: String, width: Int) -> String {
  let len = string.length(s)
  case len >= width {
    True -> string.slice(s, 0, width)
    False -> s <> string.repeat(" ", width - len)
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [x, ..], 0 -> Ok(x)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

/// Color-friendly error line for the REPL.
pub fn render_error(msg: String) -> String {
  color.error(color.enabled(), "✗ " <> msg)
}
