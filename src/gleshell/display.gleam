//// Pretty-print structured values (Nushell-style tables).

import gleam/int
import gleam/list
import gleam/string
import gleshell/value.{type Value, Fail, List, Nothing, Record, Table}

pub fn render(value: Value) -> String {
  case value {
    Nothing -> ""
    Fail(msg) -> "Error: " <> msg
    Table(cols, rows) -> render_table(cols, rows)
    List(items) -> {
      case list.all(items, is_record) {
        True ->
          case value.table_from_records(items) {
            Table(c, r) -> render_table(c, r)
            other -> render_value_block(other)
          }
        False -> render_list(items)
      }
    }
    Record(fields) -> render_record(fields)
    other -> value.cell_string(other)
  }
}

fn is_record(v: Value) -> Bool {
  case v {
    Record(_) -> True
    _ -> False
  }
}

fn render_value_block(v: Value) -> String {
  value.as_string(v)
}

fn render_list(items: List(Value)) -> String {
  case items {
    [] -> "[]"
    _ -> {
      let body =
        items
        |> list.index_map(fn(item, i) {
          "  " <> int.to_string(i) <> " │ " <> value.cell_string(item)
        })
        |> string.join("\n")
      "╭──── list ───\n" <> body <> "\n╰────────────"
    }
  }
}

fn render_record(fields: List(#(String, Value))) -> String {
  case fields {
    [] -> "{}"
    _ -> {
      let key_w =
        fields
        |> list.map(fn(p) {
          let #(k, _) = p
          string.length(k)
        })
        |> list.fold(0, int.max)

      let lines =
        list.map(fields, fn(pair) {
          let #(k, v) = pair
          "  " <> pad_right(k, key_w) <> " │ " <> value.cell_string(v)
        })
      "╭──── record ───\n" <> string.join(lines, "\n") <> "\n╰──────────────"
    }
  }
}

pub fn render_table(columns: List(String), rows: List(List(Value))) -> String {
  case columns {
    [] -> "(empty table)"
    _ -> {
      let cells: List(List(String)) =
        list.map(rows, fn(row) { list.map(row, value.cell_string) })

      let widths =
        list.index_map(columns, fn(col, i) {
          let header_w = string.length(col)
          let data_w =
            cells
            |> list.map(fn(row) {
              case list_at(row, i) {
                Ok(c) -> string.length(c)
                Error(Nil) -> 0
              }
            })
            |> list.fold(header_w, int.max)
          int.max(data_w, 1)
        })

      let top = box_line(widths, "╭", "┬", "╮", "─")
      let sep = box_line(widths, "├", "┼", "┤", "─")
      let bot = box_line(widths, "╰", "┴", "╯", "─")
      let header = data_line(columns, widths)
      let body =
        cells
        |> list.map(fn(row) { data_line(row, widths) })
        |> string.join("\n")

      case body {
        "" -> top <> "\n" <> header <> "\n" <> bot
        _ -> top <> "\n" <> header <> "\n" <> sep <> "\n" <> body <> "\n" <> bot
      }
    }
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

fn data_line(cells: List(String), widths: List(Int)) -> String {
  let padded =
    list.map2(cells, widths, fn(cell, w) { " " <> pad_right(cell, w) <> " " })
  // if fewer cells than widths, pad
  let padded = case list.length(padded) < list.length(widths) {
    True -> {
      let extra =
        list.drop(widths, list.length(padded))
        |> list.map(fn(w) { " " <> pad_right("", w) <> " " })
      list.append(padded, extra)
    }
    False -> padded
  }
  "│" <> string.join(padded, "│") <> "│"
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
  "✗ " <> msg
}
